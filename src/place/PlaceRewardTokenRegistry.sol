// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title PlaceRewardTokenRegistry
/// @notice White list of reward tokens a launch's community fund may be swapped into (LAUNCH.md §4.3), with the
///         exact Uniswap v4 pools of each swap. Owner: the platform admin (a Safe on mainnet).
///         A creator vault swaps its fund only along a route listed here (plus its own launch pool, for its own
///         token). Listing pools and not only tokens matters: otherwise a creator could route the fund through a
///         thin pool or a pool with a hostile hook they control and take the difference.
/// @dev    A route is 1–3 exact-in hops from `from` to `to`; each hop's price impact is capped by
///         `maxPriceImpactBps` in the vault. Removing a route stops future swaps only.
contract PlaceRewardTokenRegistry is Ownable2Step {
    uint256 public constant MAX_HOPS = 3;
    /// @notice The owner can never allow more than 20% price impact per hop.
    uint16 public constant MAX_PRICE_IMPACT_CAP_BPS = 2_000;

    /// @notice Maximum price move (bps of the pool price) a single hop of a fund swap may cause.
    uint16 public maxPriceImpactBps;

    mapping(bytes32 pair => PoolKey[] hops) internal _routes;

    event RouteSet(address indexed from, address indexed to, PoolKey[] hops);
    event RouteRemoved(address indexed from, address indexed to);
    event MaxPriceImpactSet(uint16 bps);

    error InvalidRoute();
    error InvalidImpact();

    constructor(address initialOwner, uint16 initialMaxPriceImpactBps) Ownable(initialOwner) {
        _setMaxPriceImpact(initialMaxPriceImpactBps);
    }

    /// @notice Lists (or replaces) the route `from` -> `to`. `to` becomes an allowed reward token for funds held
    ///         in `from`.
    function setRoute(address from, address to, PoolKey[] calldata hops) external onlyOwner {
        if (from == to || hops.length == 0 || hops.length > MAX_HOPS) revert InvalidRoute();
        address current = from;
        for (uint256 i = 0; i < hops.length; i++) {
            address c0 = Currency.unwrap(hops[i].currency0);
            address c1 = Currency.unwrap(hops[i].currency1);
            if (current == c0) current = c1;
            else if (current == c1) current = c0;
            else revert InvalidRoute();
        }
        if (current != to) revert InvalidRoute();
        PoolKey[] storage route = _routes[_pair(from, to)];
        delete _routes[_pair(from, to)];
        for (uint256 i = 0; i < hops.length; i++) {
            route.push(hops[i]);
        }
        emit RouteSet(from, to, hops);
    }

    function removeRoute(address from, address to) external onlyOwner {
        delete _routes[_pair(from, to)];
        emit RouteRemoved(from, to);
    }

    function setMaxPriceImpactBps(uint16 bps) external onlyOwner {
        _setMaxPriceImpact(bps);
    }

    /// @notice The listed route `from` -> `to` (empty when not allowed).
    function routeOf(address from, address to) external view returns (PoolKey[] memory) {
        return _routes[_pair(from, to)];
    }

    function isAllowed(address from, address to) external view returns (bool) {
        return _routes[_pair(from, to)].length != 0;
    }

    function _setMaxPriceImpact(uint16 bps) internal {
        if (bps == 0 || bps > MAX_PRICE_IMPACT_CAP_BPS) revert InvalidImpact();
        maxPriceImpactBps = bps;
        emit MaxPriceImpactSet(bps);
    }

    function _pair(address from, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(from, to));
    }
}
