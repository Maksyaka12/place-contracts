// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract CreatorVaultTest is LaunchFixture {
    address internal constant PAYOUT = address(0xFA11);
    address internal constant X_WALLET = address(0xA11CE);
    uint256 internal constant X_ID = 42;

    address internal token;
    PoolKey internal key;
    PlaceCreatorVault internal vault;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.xShares = new PlaceCreatorVault.XShare[](1);
        p.economics.xShares[0] = PlaceCreatorVault.XShare({xId: X_ID, bps: 2_000});
        (token,) = _launch(p);
        key = _poolKey(token, address(0));
        vault = _vault(token);
        vm.warp(vm.getBlockTimestamp() + 21);
    }

    function test_collect_splitsXAndCreator() public {
        _swap(TRADER, key, token, true, 1 ether); // 0.007 ETH to the vault
        uint256 amount = vault.collect();
        assertEq(amount, 0.007 ether);
        assertEq(vault.xOwed(X_ID), 0.0014 ether, "20% to the X account");
        assertEq(vault.creatorOwed(), 0.0056 ether);
        assertEq(vault.collect(), 0, "idempotent");
    }

    function test_claim_paysCreatorAndPayout() public {
        _swap(TRADER, key, token, true, 1 ether);
        vm.prank(CREATOR);
        vault.claim();
        assertEq(CREATOR.balance, 0.0056 ether);
        _swap(TRADER, key, token, true, 1 ether);
        vm.prank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        vm.prank(CREATOR);
        vault.claim();
        assertEq(PAYOUT.balance, 0.0056 ether, "payout address");
    }

    function test_claim_onlyCreator() public {
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.claim();
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.setPayoutAddress(PAYOUT);
    }

    function test_claimX_needsBinding() public {
        _swap(TRADER, key, token, true, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PlaceCreatorVault.XNotBound.selector, X_ID));
        vault.claimX(X_ID);
        xreg.bind(X_ID, X_WALLET);
        vault.claimX(X_ID);
        assertEq(X_WALLET.balance, 0.0014 ether);
        assertEq(vault.xOwedTotal(), 0);
    }

    function test_donation_isBookedToo() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        vault.collect();
        assertEq(vault.creatorOwed() + vault.xOwedTotal(), 1 ether);
    }

    function test_creatorRightsMove_payoutResets() public {
        vm.prank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        address next = address(0xBEEF);
        vm.prank(CREATOR);
        factory.proposeCreatorRightsTransfer(token, next);
        vm.prank(next);
        factory.acceptCreatorRightsTransfer(token);
        assertEq(vault.payoutAddress(), next);
        _swap(TRADER, key, token, true, 1 ether);
        vm.prank(next);
        vault.claim();
        assertEq(next.balance, 0.0056 ether);
    }

    function test_initialize_onlyOnce() public {
        PlaceCreatorVault.Initialization memory init;
        vm.expectRevert();
        vault.initialize(init);
    }

    function test_xShares_validated() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.xShares = new PlaceCreatorVault.XShare[](2);
        p.economics.xShares[0] = PlaceCreatorVault.XShare({xId: 1, bps: 6_000});
        p.economics.xShares[1] = PlaceCreatorVault.XShare({xId: 2, bps: 5_000});
        _mineSalt(p, CREATOR);
        uint256 fee = factory.nativeLaunchFee();
        vm.deal(CREATOR, fee);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        vm.prank(CREATOR);
        factory.createLaunch{value: fee}(p);
    }

    /// Whatever arrives, collect books exactly all of it and nothing is double counted.
    function testFuzz_collect_conserves(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1e9, 5 ether));
        b = uint96(bound(b, 0, 5 ether));
        _swap(TRADER, key, token, true, a);
        vault.collect();
        vm.deal(address(this), b);
        (bool ok,) = address(vault).call{value: b}("");
        assertTrue(ok);
        vault.collect();
        assertEq(address(vault).balance, vault.creatorOwed() + vault.xOwedTotal());
        assertApproxEqAbs(vault.xOwed(X_ID) * 4, vault.creatorOwed(), 10);
    }
}
