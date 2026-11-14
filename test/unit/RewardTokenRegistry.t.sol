// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceRewardTokenRegistry} from "../../src/place/PlaceRewardTokenRegistry.sol";

contract RewardTokenRegistryTest is Test {
    PlaceRewardTokenRegistry internal reg;
    address internal constant OWNER = address(0x5AFE);
    address internal constant USD = address(0x1000);
    address internal constant BTC = address(0x2000);

    function setUp() public {
        reg = new PlaceRewardTokenRegistry(OWNER, 300);
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
    }

    function test_setRoute_twoHops() public {
        PoolKey[] memory hops = new PoolKey[](2);
        hops[0] = _key(address(0), USD);
        hops[1] = _key(USD, BTC);
        vm.prank(OWNER);
        reg.setRoute(address(0), BTC, hops);
        assertTrue(reg.isAllowed(address(0), BTC));
        assertFalse(reg.isAllowed(BTC, address(0)), "direction matters");
        assertEq(reg.routeOf(address(0), BTC).length, 2);
        // replace with a direct route
        PoolKey[] memory direct = new PoolKey[](1);
        direct[0] = _key(address(0), BTC);
        vm.prank(OWNER);
        reg.setRoute(address(0), BTC, direct);
        assertEq(reg.routeOf(address(0), BTC).length, 1);
        vm.prank(OWNER);
        reg.removeRoute(address(0), BTC);
        assertFalse(reg.isAllowed(address(0), BTC));
    }

    function test_setRoute_rejectsBrokenPaths() public {
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = _key(USD, BTC); // does not start at ETH
        vm.startPrank(OWNER);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidRoute.selector);
        reg.setRoute(address(0), BTC, hops);
        hops[0] = _key(address(0), USD); // ends at USD, not BTC
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidRoute.selector);
        reg.setRoute(address(0), BTC, hops);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidRoute.selector);
        reg.setRoute(USD, USD, hops);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidRoute.selector);
        reg.setRoute(address(0), USD, new PoolKey[](0));
        PoolKey[] memory four = new PoolKey[](4);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidRoute.selector);
        reg.setRoute(address(0), USD, four);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = _key(address(0), USD);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reg.setRoute(address(0), USD, hops);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reg.setMaxPriceImpactBps(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reg.removeRoute(address(0), USD);
    }

    function test_impactBounds() public {
        vm.startPrank(OWNER);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidImpact.selector);
        reg.setMaxPriceImpactBps(0);
        vm.expectRevert(PlaceRewardTokenRegistry.InvalidImpact.selector);
        reg.setMaxPriceImpactBps(2_001);
        reg.setMaxPriceImpactBps(2_000);
        vm.stopPrank();
        assertEq(reg.maxPriceImpactBps(), 2_000);
    }
}
