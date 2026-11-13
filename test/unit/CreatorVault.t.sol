// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {MockHub, MockXRegistry} from "../utils/Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {IPlaceHub} from "../../src/place/interfaces/IPlaceHub.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreatorVaultTest is LaunchFixture {
    MockHub internal hub;
    MockXRegistry internal xreg;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant PAYOUT = address(0xBA11);
    address internal constant X_WALLET = address(0x7777);
    uint256 internal constant X_ID = 42;

    address internal token;
    PoolId internal poolId;
    PoolKey internal key;
    PlaceCreatorVault internal vault;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        hub = new MockHub();
        xreg = new MockXRegistry();
        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: address(hub),
                xRegistry: address(xreg),
                campaignInterval: 7 days,
                rulesHash: keccak256("rules"),
                rulesURI: "ipfs://rules"
            })
        );
        factory.setRewardsMinimum(address(0), 0.001 ether);
        _launchWith(2_000, true, 3_000, 5_000);
    }

    function _launchWith(uint16 buyback, bool burn, uint16 rewards, uint16 xBps) internal {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.buybackBps = buyback;
        p.economics.buybackBurn = burn;
        p.economics.rewardsBps = rewards;
        if (xBps != 0) {
            p.economics.xShares = new PlaceCreatorVault.XShare[](1);
            p.economics.xShares[0] = PlaceCreatorVault.XShare({xId: X_ID, bps: xBps});
        }
        (token, poolId) = _launch(p);
        key = _poolKey(token, address(0));
        vault = _vault(token);
        vm.warp(block.timestamp + 21);
    }

    function _recipient() internal view returns (address recipient) {
        (,,,,, recipient,,,,,,) = hook.poolConfig(poolId);
    }

    function test_vaultIsTheImmutableRecipient() public view {
        assertEq(_recipient(), address(vault));
        assertEq(vault.token(), token);
        assertEq(vault.currentCreator(), CREATOR);
        assertEq(vault.payoutAddress(), CREATOR);
    }

    function test_noWayToChangeRecipient() public {
        (bool ok,) =
            address(factory).call(abi.encodeWithSignature("setCreatorFeeRecipient(address,address)", token, PAYOUT));
        assertFalse(ok);
        (ok,) = address(factory)
            .call(abi.encodeWithSignature("adminSetCreatorFeeRecipient(address,address)", token, PAYOUT));
        assertFalse(ok);
        vm.prank(address(factory));
        vm.expectRevert(PlaceLaunchHook.InvalidFeeConfig.selector);
        hook.updateCreatorRights(poolId, CREATOR, PAYOUT);
        // admin reassign moves the creator but keeps the vault
        factory.adminReassignCreatorRights(token, PAYOUT);
        assertEq(_recipient(), address(vault));
        assertEq(vault.currentCreator(), PAYOUT);
    }

    function test_collect_splits() public {
        _swap(TRADER, key, token, true, 1 ether); // 0.0075 ETH to the vault
        vault.collect();
        assertEq(vault.buybackReserve(), 0.0015 ether, "20% buyback");
        assertEq(vault.rewardsAvailable(), 0.00225 ether, "30% rewards");
        assertEq(vault.xOwed(X_ID), 0.001875 ether, "X: 50% of the rest");
        assertEq(vault.creatorOwed(), 0.001875 ether, "creator: the rest");
        assertEq(address(vault).balance, 0.0075 ether);
    }

    function test_claim_buybackBurn_andPay() public {
        _swap(TRADER, key, token, true, 1 ether);
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(CREATOR);
        (uint256 paid, uint256 bought) = vault.claim(1);
        assertEq(paid, 0.001875 ether);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, bought, "burned");
        assertEq(CREATOR.balance, 0.001875 ether);
        assertEq(vault.buybackReserve(), 0);
        // the buyback paid the normal 1% fee; 0.75% of it came back to the vault
        assertGt(escrow.owed(address(vault), address(0)), 0);
    }

    function test_claim_minOutProtects() public {
        _swap(TRADER, key, token, true, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert();
        vault.claim(type(uint256).max);
    }

    function test_claim_onlyCreator() public {
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.claim(0);
    }

    function test_holdMode_tokensToPayout() public {
        _launchWith(5_000, false, 0, 0);
        _swap(TRADER, key, token, true, 1 ether);
        vm.prank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        vm.prank(CREATOR);
        (, uint256 bought) = vault.claim(1);
        assertEq(IERC20(token).balanceOf(PAYOUT), bought);
        assertEq(PAYOUT.balance, 0.00375 ether);
    }

    function test_payoutResetsOnRightsTransfer() public {
        vm.prank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        assertEq(vault.payoutAddress(), PAYOUT);
        address next = address(0x2222);
        vm.prank(CREATOR);
        factory.proposeCreatorRightsTransfer(token, next);
        vm.prank(next);
        factory.acceptCreatorRightsTransfer(token);
        assertEq(vault.payoutAddress(), next, "the new creator until they set a payout");
        assertEq(_recipient(), address(vault));
    }

    function test_increaseEconomics_onlyUp() public {
        vm.startPrank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.OnlyIncrease.selector);
        vault.increaseEconomics(1_000, true, 3_000);
        vm.expectRevert(PlaceCreatorVault.OnlyIncrease.selector);
        vault.increaseEconomics(2_000, false, 3_000);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        vault.increaseEconomics(5_000, true, 6_000);
        vault.increaseEconomics(3_000, true, 4_000);
        vm.stopPrank();
        assertEq(vault.buybackBps(), 3_000);
        assertEq(vault.rewardsBps(), 4_000);
    }

    function test_rewardsCampaign_byAnyone_thenInterval() public {
        _swap(TRADER, key, token, true, 1 ether);
        uint256 id = vault.startRewardsCampaign();
        IPlaceHub.CreateParams memory p = hub.created(id);
        assertEq(uint8(p.kind), uint8(IPlaceHub.Kind.TokenHolders));
        assertEq(p.target, token);
        assertEq(p.rewardToken, address(0));
        assertEq(p.pool, 0.00225 ether);
        assertEq(p.snapshotAt, block.timestamp + 24 hours);
        assertEq(p.claimDuration, 30 days);
        assertTrue(p.burnLeftover);
        assertEq(p.rulesHash, keccak256("rules"));
        assertEq(hub.creators(id), address(vault));

        _swap(TRADER, key, token, true, 1 ether);
        vm.expectRevert();
        vault.startRewardsCampaign(); // anyone: interval not passed
        vm.prank(CREATOR);
        vault.startRewardsCampaign(); // creator: allowed
        vm.warp(block.timestamp + 7 days);
        _swap(TRADER, key, token, true, 1 ether);
        vault.startRewardsCampaign();
        assertEq(hub.count(), 3);
    }

    function test_rewardsCampaign_paysHubFee() public {
        hub.setFee(500);
        _swap(TRADER, key, token, true, 1 ether);
        uint256 id = vault.startRewardsCampaign();
        assertEq(hub.paid(id), address(hub).balance);
        assertLe(hub.paid(id), 0.00225 ether);
        assertApproxEqAbs(hub.created(id).pool, uint256(0.00225 ether) * 10_000 / 10_500, 1);
    }

    function test_rewardsCampaign_belowMinimum() public {
        _swap(TRADER, key, token, true, 0.1 ether); // rewards 0.000225 < 0.001
        vm.expectRevert();
        vault.startRewardsCampaign();
    }

    function test_refundUnpublished_returnsToRewards() public {
        _swap(TRADER, key, token, true, 1 ether);
        uint256 id = vault.startRewardsCampaign();
        assertEq(vault.rewardsAvailable(), 0);
        vault.refundUnpublishedCampaign(id);
        assertEq(vault.rewardsAvailable(), 0.00225 ether);
    }

    function test_claimX_afterBinding() public {
        _swap(TRADER, key, token, true, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PlaceCreatorVault.XNotBound.selector, X_ID));
        vault.claimX(X_ID);
        xreg.bind(X_ID, X_WALLET);
        vault.claimX(X_ID);
        assertEq(X_WALLET.balance, 0.001875 ether);
        assertEq(vault.xOwedTotal(), 0);
    }

    function test_invalidEconomics_reverts() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.buybackBps = 6_000;
        p.economics.rewardsBps = 5_000;
        _mineSalt(p, CREATOR);
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        factory.createLaunch{value: 0.0005 ether}(p);
    }

    function test_vaultCannotBeReinitialized() public {
        PlaceCreatorVault.Initialization memory init;
        vm.expectRevert();
        vault.initialize(init);
    }
}
