// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchOperations} from "../../src/launch/PlaceLaunchOperations.sol";
import {IB20, IB20Factory} from "../../src/launch/interfaces/IB20.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice B20 launches through the real Base Sepolia PoolManager and B20 precompile (fork).
contract LaunchB20ForkTest is LaunchFixture {
    IPoolManager internal constant SEPOLIA_PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IB20Factory internal constant B20F = IB20Factory(0xB20f000000000000000000000000000000000000);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://base-sepolia-rpc.publicnode.com")));
        _deploySuite(SEPOLIA_PM);
    }

    function test_b20_launch_isImmutableAndAdminless() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.B20, address(0));
        address predicted = factory.predictLaunchToken(_mined(p), CREATOR);
        (address token,) = _launch(p);
        assertEq(token, predicted, "predicted address");
        assertTrue(B20F.isB20(token));
        assertEq(uint160(token) >> 152, 0xB2, "B20 prefix");
        assertEq(uint160(token) & 0xff, 0x01, "vanity suffix");
        IB20 t = IB20(token);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.supplyCap(), SUPPLY);
        assertTrue(t.hasRole(t.METADATA_ROLE(), address(factory)));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), CREATOR));
        assertEq(t.pausedFeatures().length, 0);
        assertEq(uint8(factory.launchTokenKind(token)), uint8(PlaceLaunchFactoryCore.TokenKind.B20));
        // nobody can mint or grant roles
        vm.expectRevert();
        t.mint(address(this), 1);
        bytes32 mintRole = t.MINT_ROLE();
        vm.prank(address(factory));
        vm.expectRevert();
        t.grantRole(mintRole, address(factory));
    }

    function test_b20_metadata_nameAndExtra_noSymbol() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.B20, address(0)));
        vm.prank(CREATOR);
        factory.updateTokenName(token, "Renamed");
        assertEq(IERC20Name(token).name(), "Renamed");
        assertEq(IERC20Name(token).symbol(), "PLT");
        vm.expectEmit(true, false, false, true, address(factory));
        emit PlaceLaunchFactoryCore.B20ExtraMetadataUpdated(token, "x", "https://x.com/place");
        vm.prank(CREATOR);
        factory.updateTokenExtraMetadata(token, "x", "https://x.com/place");
    }

    function test_b20_notEditable_noMetadataRole() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.B20, address(0));
        p.metadataEditable = false;
        (address token,) = _launch(p);
        IB20 t = IB20(token);
        assertFalse(t.hasRole(t.METADATA_ROLE(), address(factory)));
    }

    function test_b20_swaps_feesSplit() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.B20, address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(block.timestamp + 21);
        _swap(TRADER, key, token, true, 0.1 ether);
        assertEq(escrow.owed(PLATFORM, address(0)), 0.0003 ether);
        assertEq(escrow.owed(address(_vault(token)), address(0)), 0.0007 ether);
        uint256 bought = IERC20(token).balanceOf(TRADER);
        assertGt(bought, 0);
        _swap(TRADER, key, token, false, bought / 2);
        assertGt(escrow.owed(address(_vault(token)), address(0)), 0.0007 ether);
        PlaceCreatorVault vault = _vault(token);
        vm.prank(CREATOR);
        vault.claim();
        assertGt(CREATOR.balance, 0, "creator paid through the vault");
    }

    function _mined(PlaceLaunchFactoryCore.LaunchParams memory p)
        internal
        view
        returns (PlaceLaunchFactoryCore.LaunchParams memory)
    {
        _mineSalt(p, CREATOR);
        return p;
    }
}

interface IERC20Name {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}
