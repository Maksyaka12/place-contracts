// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title PlacePriceGuard
/// @notice Manipulation-resistant reference prices for Uniswap v4 pools that have no oracle of their own.
///
///         Every pool gets a reference price that follows the pool's spot price slowly:
///         - anyone can `observe` a pool; an observation is taken at most once per `minInterval`;
///         - each observation moves the reference towards the spot price by at most `maxStepBps`;
///         - a reference written in the current block is never used in that block (the previous one is), so a
///           flash loan or a pump inside one transaction or block cannot move the price a caller relies on;
///         - a pool is usable only `warmup` seconds after its first observation;
///         - a quote reverts while the spot price is more than `maxDeviationBps` away from the reference.
///
///         Callers get both the reference and the spot output of a route and pick the side that protects them:
///         a mint priced in a token charges the larger token amount; a buyback requires at least the reference
///         output minus a tolerance. Moving the reference by X% takes X / maxStepBps intervals in which the
///         attacker wins every observation with a manipulated price, paying the pool fees and taxes each time,
///         while honest observations (mints, buybacks, a keeper) pull it back at the same speed.
/// @dev    Prices are kept as v4 sqrt prices (token1 per token0, Q64.96).
contract PlacePriceGuard is Ownable2Step {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    /// @notice Hard bounds of the owner's settings.
    uint32 public constant MIN_INTERVAL_FLOOR = 12;
    uint32 public constant MIN_INTERVAL_CAP = 1 hours;
    uint32 public constant WARMUP_CAP = 1 days;
    uint16 public constant MAX_STEP_FLOOR_BPS = 10;
    uint16 public constant MAX_STEP_CAP_BPS = 1_000;
    uint16 public constant MAX_DEVIATION_FLOOR_BPS = 10;
    uint16 public constant MAX_DEVIATION_CAP_BPS = 2_000;

    struct Config {
        uint32 minInterval; // seconds between two observations of a pool
        uint32 warmup; // seconds from the first observation until the pool can be quoted
        uint16 maxStepBps; // largest move of the reference per observation
        uint16 maxDeviationBps; // largest spot vs reference gap a quote accepts
    }

    struct Observation {
        uint160 refPrice; // current reference sqrt price
        uint64 updatedAt;
        uint32 updatedBlock;
        uint160 previous; // reference before the last observation (used in the block of that observation)
        uint64 firstAt;
    }

    IPoolManager public immutable poolManager;
    Config internal _config;
    mapping(PoolId poolId => Observation observation) internal _observations;

    event ConfigSet(Config config);
    event Observed(PoolId indexed poolId, uint160 spot, uint160 refPrice);

    error InvalidConfig();
    error PoolNotInitialized(PoolId poolId);
    error PriceNotReady(PoolId poolId, uint64 readyAt);
    error PriceDeviation(PoolId poolId, uint256 deviationBps, uint256 maxBps);
    error InvalidRoute();

    constructor(IPoolManager manager, address initialOwner, Config memory initialConfig) Ownable(initialOwner) {
        if (address(manager) == address(0)) revert InvalidConfig();
        poolManager = manager;
        _setConfig(initialConfig);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Records the pool's spot price (at most once per `minInterval`). Permissionless.
    function observe(PoolKey calldata key) external {
        _observe(key);
    }

    /// @notice Observes every pool of a route.
    function observeRoute(PoolKey[] calldata route) external {
        for (uint256 i = 0; i < route.length; i++) {
            _observe(route[i]);
        }
    }

    // ───────────────────────────── Owner ─────────────────────────────

    /// @notice New settings, within the hard bounds. They apply to every pool from the next observation or quote.
    function setConfig(Config calldata newConfig) external onlyOwner {
        _setConfig(newConfig);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function config() external view returns (Config memory) {
        return _config;
    }

    function observation(PoolId poolId) external view returns (Observation memory) {
        return _observations[poolId];
    }

    /// @notice When the pool becomes usable (0: never observed).
    function readyAt(PoolId poolId) public view returns (uint64) {
        uint64 firstAt = _observations[poolId].firstAt;
        return firstAt == 0 ? 0 : firstAt + _config.warmup;
    }

    /// @notice Exact-in output of `amountIn` of `input` along `route`, priced twice: with the reference prices
    ///         and with the spot prices (no fees, taxes or price impact). Reverts if a pool is not ready or its
    ///         spot price is too far from its reference.
    function quote(PoolKey[] memory route, address input, uint256 amountIn)
        external
        view
        returns (uint256 referenceOut, uint256 spotOut)
    {
        if (route.length == 0) revert InvalidRoute();
        Config memory c = _config;
        address current = input;
        referenceOut = amountIn;
        spotOut = amountIn;
        for (uint256 i = 0; i < route.length; i++) {
            PoolKey memory key = route[i];
            bool zeroForOne = Currency.unwrap(key.currency0) == current;
            if (!zeroForOne && Currency.unwrap(key.currency1) != current) revert InvalidRoute();
            PoolId id = key.toId();
            (uint160 spot, uint160 ref) = _readyPrices(id, c);
            uint256 deviation = deviationBps(ref, spot);
            if (deviation > c.maxDeviationBps) revert PriceDeviation(id, deviation, c.maxDeviationBps);
            referenceOut = _convert(referenceOut, ref, zeroForOne);
            spotOut = _convert(spotOut, spot, zeroForOne);
            current = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        }
    }

    /// @notice |price_b / price_a - 1| in bps, from two sqrt prices.
    function deviationBps(uint160 sqrtA, uint160 sqrtB) public pure returns (uint256) {
        uint256 ratio = FullMath.mulDiv(sqrtB, 1e18, sqrtA);
        uint256 price = FullMath.mulDiv(ratio, ratio, 1e18);
        uint256 move = price > 1e18 ? price - 1e18 : 1e18 - price;
        return Math.mulDiv(move, BPS, 1e18, Math.Rounding.Ceil);
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _observe(PoolKey calldata key) internal {
        PoolId id = key.toId();
        (uint160 spot,,,) = StateLibrary.getSlot0(poolManager, id);
        if (spot == 0) revert PoolNotInitialized(id);
        Observation storage o = _observations[id];
        uint160 next;
        if (o.firstAt == 0) {
            next = spot;
            o.firstAt = uint64(block.timestamp);
            o.previous = spot;
        } else {
            // forge-lint: disable-next-line(block-timestamp) intervals of minutes
            if (block.timestamp < uint256(o.updatedAt) + _config.minInterval) return;
            next = _step(o.refPrice, spot, _config.maxStepBps);
            o.previous = o.refPrice;
        }
        o.refPrice = next;
        o.updatedAt = uint64(block.timestamp);
        o.updatedBlock = uint32(block.number);
        emit Observed(id, spot, next);
    }

    /// @dev The spot price and the reference usable in this block (the previous one if it was updated in it).
    function _readyPrices(PoolId id, Config memory c) internal view returns (uint160 spot, uint160 ref) {
        Observation memory o = _observations[id];
        // forge-lint: disable-next-line(block-timestamp) warmup of minutes
        if (o.firstAt == 0 || block.timestamp < uint256(o.firstAt) + c.warmup) {
            revert PriceNotReady(id, o.firstAt == 0 ? 0 : o.firstAt + c.warmup);
        }
        ref = o.updatedBlock == uint32(block.number) ? o.previous : o.refPrice;
        (spot,,,) = StateLibrary.getSlot0(poolManager, id);
    }

    /// @dev Moves `ref` towards `spot` by at most `stepBps` of the price.
    function _step(uint160 ref, uint160 spot, uint16 stepBps) internal pure returns (uint160) {
        if (deviationBps(ref, spot) <= stepBps) return spot;
        // sqrt(1 ± step) in 1e18 fixed point
        uint256 factor = spot > ref ? Math.sqrt((BPS + stepBps) * 1e36 / BPS) : Math.sqrt((BPS - stepBps) * 1e36 / BPS);
        return uint160(FullMath.mulDiv(ref, factor, 1e18));
    }

    /// @dev Output of `amount` at sqrt price `s` (token1 per token0), without fees.
    function _convert(uint256 amount, uint160 s, bool zeroForOne) internal pure returns (uint256) {
        if (zeroForOne) return FullMath.mulDiv(FullMath.mulDiv(amount, s, Q96), s, Q96);
        return FullMath.mulDiv(FullMath.mulDiv(amount, Q96, s), Q96, s);
    }

    function _setConfig(Config memory c) internal {
        if (
            c.minInterval < MIN_INTERVAL_FLOOR || c.minInterval > MIN_INTERVAL_CAP || c.warmup < c.minInterval
                || c.warmup > WARMUP_CAP || c.maxStepBps < MAX_STEP_FLOOR_BPS || c.maxStepBps > MAX_STEP_CAP_BPS
                || c.maxDeviationBps < MAX_DEVIATION_FLOOR_BPS || c.maxDeviationBps > MAX_DEVIATION_CAP_BPS
        ) revert InvalidConfig();
        _config = c;
        emit ConfigSet(c);
    }
}
