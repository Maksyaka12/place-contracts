// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PlaceRewardTokenRegistry} from "../src/place/PlaceRewardTokenRegistry.sol";

/// @notice Lists reward token routes in the PlaceRewardTokenRegistry: for each route `from` -> `to`, the exact
///         Uniswap v4 pools (1–3 hops) a creator vault and the rewards contract swap along.
///
///   REGISTRY=0x… POOL_MANAGER=0x… ROUTES_FILE=script/routes/base.json forge script script/SetRewardRoutes.s.sol \
///     --rpc-url base --account <owner keystore> --sender <owner> [--broadcast]
///
/// Without `--broadcast` it only simulates and prints what it would change. Each pool is checked onchain before
/// it is listed: it must be initialized and hold at least MIN_LIQUIDITY (default 1e12) in-range liquidity, or the
/// route is skipped. Routes already listed with the same pools are skipped too.
///
/// The routes file:
///   { "routes": [ { "from": "0x…", "to": "0x…", "hops": [
///       { "currency0": "0x…", "currency1": "0x…", "fee": 500, "tickSpacing": 10, "hooks": "0x…" } ] } ] }
/// ETH is the zero address. In a hop, currency0 < currency1 as in the pool key.
contract SetRewardRoutes is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Route {
        address from;
        address to;
        PoolKey[] hops;
    }

    function run() external {
        PlaceRewardTokenRegistry registry = PlaceRewardTokenRegistry(vm.envAddress("REGISTRY"));
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        uint128 minLiquidity = uint128(vm.envOr("MIN_LIQUIDITY", uint256(1e12)));
        string memory json = vm.readFile(vm.envOr("ROUTES_FILE", string("script/routes/base.json")));

        Route[] memory routes = _read(json);
        bool[] memory todo = new bool[](routes.length);
        uint256 count;
        for (uint256 i = 0; i < routes.length; i++) {
            Route memory r = routes[i];
            if (_sameRoute(registry.routeOf(r.from, r.to), r.hops)) {
                console.log("listed already:", r.from, r.to);
                continue;
            }
            if (!_poolsLive(pm, r.hops, minLiquidity)) {
                console.log("skipped, pool missing or thin:", r.from, r.to);
                continue;
            }
            todo[i] = true;
            count++;
            console.log("will list:", r.from, r.to);
        }
        console.log("routes to list", count);

        vm.startBroadcast(vm.envOr("SENDER", msg.sender));
        for (uint256 i = 0; i < routes.length; i++) {
            if (todo[i]) registry.setRoute(routes[i].from, routes[i].to, routes[i].hops);
        }
        vm.stopBroadcast();
    }

    function _read(string memory json) internal view returns (Route[] memory routes) {
        uint256 n;
        while (vm.keyExistsJson(json, _key(".routes", n))) n++;
        routes = new Route[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory base = _key(".routes", i);
            uint256 h;
            while (vm.keyExistsJson(json, _key(string.concat(base, ".hops"), h))) h++;
            require(h > 0 && h <= 3, "1-3 hops per route");
            PoolKey[] memory hops = new PoolKey[](h);
            for (uint256 j = 0; j < h; j++) {
                hops[j] = _hop(json, _key(string.concat(base, ".hops"), j));
            }
            routes[i].from = vm.parseJsonAddress(json, string.concat(base, ".from"));
            routes[i].to = vm.parseJsonAddress(json, string.concat(base, ".to"));
            routes[i].hops = hops;
        }
    }

    function _hop(string memory json, string memory k) internal pure returns (PoolKey memory key) {
        key.currency0 = Currency.wrap(vm.parseJsonAddress(json, string.concat(k, ".currency0")));
        key.currency1 = Currency.wrap(vm.parseJsonAddress(json, string.concat(k, ".currency1")));
        key.fee = uint24(vm.parseJsonUint(json, string.concat(k, ".fee")));
        key.tickSpacing = int24(vm.parseJsonInt(json, string.concat(k, ".tickSpacing")));
        key.hooks = IHooks(vm.parseJsonAddress(json, string.concat(k, ".hooks")));
    }

    function _key(string memory path, uint256 i) internal pure returns (string memory) {
        return string.concat(path, "[", vm.toString(i), "]");
    }

    function _poolsLive(IPoolManager pm, PoolKey[] memory hops, uint128 minLiquidity) internal view returns (bool) {
        for (uint256 i = 0; i < hops.length; i++) {
            PoolId id = hops[i].toId();
            (uint160 sqrtPriceX96,,,) = pm.getSlot0(id);
            if (sqrtPriceX96 == 0 || pm.getLiquidity(id) < minLiquidity) return false;
        }
        return true;
    }

    function _sameRoute(PoolKey[] memory current, PoolKey[] memory hops) internal pure returns (bool) {
        if (current.length != hops.length) return false;
        for (uint256 i = 0; i < hops.length; i++) {
            if (PoolId.unwrap(current[i].toId()) != PoolId.unwrap(hops[i].toId())) return false;
        }
        return true;
    }
}
