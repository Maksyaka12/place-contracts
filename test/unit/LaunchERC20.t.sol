// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchToken} from "../../src/launch/PlaceLaunchToken.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchERC20Test is LaunchFixture {
    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
    }

    function test_launch_erc20_fixedSupplyInHook() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        assertEq(uint160(token) & 0xff, 0x01, "vanity suffix");
        assertEq(IERC20(token).totalSupply(), SUPPLY);
        assertApproxEqAbs(IERC20(token).balanceOf(address(pm)), SUPPLY, 1e9, "all supply in the pool");
        assertTrue(factory.isFactoryToken(token));
        assertEq(uint8(factory.launchTokenKind(token)), uint8(PlaceLaunchFactoryCore.TokenKind.ERC20));
        assertEq(PLATFORM.balance, 0.0005 ether, "launch fee to the platform");
    }

    function test_fees_afterAntiSnipe_split75_25() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(block.timestamp + 21);
        _swap(TRADER, key, token, true, 1 ether);
        assertEq(escrow.owed(PLATFORM, address(0)), 0.0025 ether, "platform 0.25%");
        assertEq(escrow.owed(CREATOR, address(0)), 0.0075 ether, "creator 0.75%");
        uint256 bought = IERC20(token).balanceOf(TRADER);
        assertGt(bought, 0);
        _swap(TRADER, key, token, false, bought);
        assertGt(escrow.owed(CREATOR, address(0)), 0.0075 ether, "sell fee in ETH too");
    }

    function test_antiSnipe_surchargeToPlatform() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        _swap(TRADER, key, token, true, 1 ether); // same block as launch: 99%
        assertEq(escrow.owed(CREATOR, address(0)), 0.0075 ether, "creator still gets 0.75% only");
        assertEq(escrow.owed(PLATFORM, address(0)), 0.99 ether - 0.0075 ether, "the rest of 99% to the platform");
    }

    function test_noSymbolUpdate_nameUpdateWorks() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        vm.prank(CREATOR);
        factory.updateTokenName(token, "Renamed");
        assertEq(PlaceLaunchToken(token).name(), "Renamed");
        assertEq(PlaceLaunchToken(token).symbol(), "PLT");
        (bool ok,) = address(factory).call(abi.encodeWithSignature("updateTokenSymbol(address,string)", token, "X"));
        assertFalse(ok, "no symbol setter");
    }
}
