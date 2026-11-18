// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceRouteSwapper} from "../place/PlaceRouteSwapper.sol";
import {IPlaceRewardTokenRegistry} from "../place/interfaces/IPlaceRewardTokenRegistry.sol";
import {IPlaceNftFactory, IPlacePriceGuard} from "./interfaces/IPlaceNft.sol";

/// @notice The views of a PlaceNftCollection that define its routes.
interface INftRoutes {
    function token() external view returns (address);
    function rewardToken() external view returns (address);
    function launchPool() external view returns (PoolKey memory);
}

/// @title PlaceNftSwapper
/// @notice Routes and guarded swaps of the Place NFT launchpad, shared by every collection of one PlaceNftFactory
///         (deployed by the factory). It holds nothing between calls.
///
///         - **Routes** (all from the factory's PlaceRewardTokenRegistry, 1–3 v4 hops each, or a Place launch pool):
///           ETH -> pair token (the token's Place launch pool, behind a registry route ETH -> its quote asset when
///           that is not ETH; or else the registry route ETH -> token), and from a payment asset (ETH or the pair
///           token) to a collection's reward token.
///         - **Guarded swap**: the output must reach the PlacePriceGuard reference output minus (the guard's max
///           deviation + the registry's max price impact per hop), every hop may move its pool by at most that
///           impact, and the swap reverts while a pool's spot price is more than the max deviation away from its
///           reference. A sandwich therefore reverts the swap instead of filling it at a bad price.
contract PlaceNftSwapper is PlaceRouteSwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    address internal constant ETH = address(0);

    IPoolManager public immutable poolManager;
    IPlaceNftFactory public immutable factory;

    event GuardedSwap(
        address indexed caller, address indexed input, address indexed output, uint256 amountIn, uint256 amountOut
    );

    error NoRoute();
    error WrongValue();
    error Slippage(uint256 out, uint256 minOut);
    error TransferFailed();

    constructor(IPoolManager manager, IPlaceNftFactory nftFactory) {
        poolManager = manager;
        factory = nftFactory;
    }

    /// @dev ETH outputs of the PoolManager and refunds.
    receive() external payable {}

    // ───────────────────────────── Swaps ─────────────────────────────

    /// @notice Guarded swap for a collection (the caller): `amountIn` of `input` (ETH as value; an ERC-20 approved
    ///         first) into the pair token when `toPair`, else into the caller's reward token. The route comes from
    ///         the caller's `token()`, `launchPool()` and `rewardToken()`; the output goes to the caller.
    function swapFor(address input, uint256 amountIn, bool toPair) external payable nonReentrant returns (uint256 out) {
        INftRoutes c = INftRoutes(msg.sender);
        address pair = c.token();
        PoolKey memory pool = c.launchPool();
        PoolKey[] memory route = toPair ? ethRoute(pair, pool) : rewardRoute(pair, pool, input, c.rewardToken());
        if (input == ETH) {
            if (msg.value != amountIn) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
            uint256 before = IERC20(input).balanceOf(address(this));
            IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
            amountIn = IERC20(input).balanceOf(address(this)) - before;
        }
        IPlacePriceGuard guard = _guard();
        (uint256 referenceOut,) = guard.quote(route, input, amountIn);
        guard.observeRoute(route); // after the quote: an observation never counts in its own block
        uint16 impact = _registry().maxPriceImpactBps();
        uint256 tolerance = uint256(guard.config().maxDeviationBps) + uint256(impact) * route.length;
        uint256 minOut = tolerance >= BPS ? 0 : referenceOut * (BPS - tolerance) / BPS;
        (, out) = _swapRoute(input, route, amountIn, impact);
        if (out < minOut) revert Slippage(out, minOut);
        address output = outputOf(route, input);
        if (output == ETH) {
            (bool ok,) = msg.sender.call{value: out}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(output).safeTransfer(msg.sender, out);
        }
        emit GuardedSwap(msg.sender, input, output, amountIn, out);
    }

    /// @notice Observes `collection`'s ETH -> pair token route (a token-priced mint does it after its quote).
    function observeMint(address collection) external {
        INftRoutes c = INftRoutes(collection);
        _guard().observeRoute(ethRoute(c.token(), c.launchPool()));
    }

    // ───────────────────────────── Views ─────────────────────────────

    /// @notice Reference and spot pair-token outputs of `ethAmount` along `collection`'s ETH -> pair token route
    ///         (reverts like the guard: price not ready, or spot too far from the reference).
    function quoteMint(address collection, uint256 ethAmount)
        external
        view
        returns (uint256 referenceOut, uint256 spotOut)
    {
        INftRoutes c = INftRoutes(collection);
        return _guard().quote(ethRoute(c.token(), c.launchPool()), ETH, ethAmount);
    }

    /// @notice The ETH -> `token` route: `launchPool` (tickSpacing 0 = none) behind a registry route ETH -> its
    ///         quote asset when that is not ETH, or else the registry route ETH -> token. Reverts if there is none.
    function ethRoute(address token, PoolKey memory launchPool) public view returns (PoolKey[] memory route) {
        if (token == ETH) revert NoRoute();
        IPlaceRewardTokenRegistry registry = _registry();
        if (launchPool.tickSpacing == 0) {
            route = registry.routeOf(ETH, token);
        } else {
            address c0 = Currency.unwrap(launchPool.currency0);
            address quoteAsset = c0 == token ? Currency.unwrap(launchPool.currency1) : c0;
            PoolKey[] memory head;
            if (quoteAsset != ETH) {
                head = registry.routeOf(ETH, quoteAsset);
                if (head.length == 0) revert NoRoute();
            }
            route = new PoolKey[](head.length + 1);
            for (uint256 i = 0; i < head.length; i++) {
                route[i] = head[i];
            }
            route[head.length] = launchPool;
        }
        if (route.length == 0) revert NoRoute();
    }

    /// @notice The route from `input` (ETH or `token`) to `rewardToken` (ETH, `token` or a token with a registry
    ///         route from ETH): ETH -> reward, or token -> ETH -> reward along the reversed ETH -> token route.
    function rewardRoute(address token, PoolKey memory launchPool, address input, address rewardToken)
        public
        view
        returns (PoolKey[] memory route)
    {
        if (input == rewardToken) revert NoRoute();
        PoolKey[] memory tail;
        if (rewardToken != ETH) {
            tail = rewardToken == token ? ethRoute(token, launchPool) : _registry().routeOf(ETH, rewardToken);
            if (tail.length == 0) revert NoRoute();
        }
        if (input == ETH) return tail;
        if (input != token) revert NoRoute();
        PoolKey[] memory toEth = ethRoute(token, launchPool);
        uint256 n = toEth.length;
        route = new PoolKey[](n + tail.length);
        for (uint256 i = 0; i < n; i++) {
            route[i] = toEth[n - 1 - i];
        }
        for (uint256 i = 0; i < tail.length; i++) {
            route[n + i] = tail[i];
        }
    }

    /// @notice Whether a collection may pay its holders in `rewardToken`: ETH, the pair token, or a token with a
    ///         registry route from ETH.
    function isRewardToken(address token, address rewardToken) external view returns (bool) {
        if (rewardToken == ETH || rewardToken == token) return true;
        return _registry().routeOf(ETH, rewardToken).length != 0;
    }

    /// @notice The last currency of `route` starting from `input`.
    function outputOf(PoolKey[] memory route, address input) public pure returns (address current) {
        current = input;
        for (uint256 i = 0; i < route.length; i++) {
            PoolKey memory key = route[i];
            address c0 = Currency.unwrap(key.currency0);
            current = c0 == current ? Currency.unwrap(key.currency1) : c0;
        }
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function _guard() internal view returns (IPlacePriceGuard guard) {
        guard = IPlacePriceGuard(factory.priceGuard());
        if (address(guard) == address(0)) revert NoRoute();
    }

    function _registry() internal view returns (IPlaceRewardTokenRegistry registry) {
        registry = IPlaceRewardTokenRegistry(factory.rewardRegistry());
        if (address(registry) == address(0)) revert NoRoute();
    }
}
