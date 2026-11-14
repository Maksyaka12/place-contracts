// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EconomyFixture} from "../utils/EconomyFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {IPlaceHub} from "../../src/place/interfaces/IPlaceHub.sol";
import {VaultId} from "../../src/staking/interfaces/IO1Staking.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice A payout address that tries to re-enter the vault when it receives ETH.
contract ReentrantPayout {
    PlaceCreatorVault internal vault;
    bytes public lastError;
    uint256 public attempts;

    function setVault(PlaceCreatorVault v) external {
        vault = v;
    }

    receive() external payable {
        attempts++;
        try vault.process() {}
        catch (bytes memory e) {
            lastError = e;
        }
    }
}

contract CreatorVaultTest is EconomyFixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant PAYOUT = address(0xBA11);
    address internal constant X_WALLET = address(0x7777);
    address internal constant ATTACKER = address(0xBAD);
    uint256 internal constant X_ID = 42;

    address internal token;
    PoolId internal poolId;
    PoolKey internal key;
    PlaceCreatorVault internal vault;

    function setUp() public {
        _deployEconomy();
        (token, poolId, key, vault) = _launchEco(2_000, 3_000, X_ID, 5_000);
    }

    function _recipient() internal view returns (address recipient) {
        (,,,,, recipient,,,,,,) = hook.poolConfig(poolId);
    }

    /// 1 ETH buy -> 0.007 ETH to the vault: burn 0.0014, community 0.0021, X 0.00175, creator 0.00175.
    function _trade() internal {
        _swap(TRADER, key, token, true, 1 ether);
    }

    // ───────────────────────────── Recipient and baskets ─────────────────────────────

    function test_vaultIsTheImmutableRecipient() public view {
        assertEq(_recipient(), address(vault));
        assertEq(vault.token(), token);
        assertEq(vault.currentCreator(), CREATOR);
        assertEq(vault.payoutAddress(), CREATOR);
        PlaceCreatorVault.Settings memory s = vault.settings();
        assertEq(s.hub, address(hub));
        assertEq(s.staking, address(staking));
        assertEq(s.rewardRegistry, address(rewards));
        assertEq(s.processInterval, PROCESS_INTERVAL);
        assertEq(s.defaultCampaignDelay, DEFAULT_DELAY);
        assertEq(s.maxBurnPerProcess, MAX_BURN);
        assertEq(s.defaultCampaignMinimum, DEFAULT_MIN);
    }

    function test_noWayToChangeRecipient() public {
        (bool ok,) =
            address(factory).call(abi.encodeWithSignature("setCreatorFeeRecipient(address,address)", token, PAYOUT));
        assertFalse(ok);
        vm.prank(address(factory));
        vm.expectRevert(PlaceLaunchHook.InvalidFeeConfig.selector);
        hook.updateCreatorRights(poolId, CREATOR, PAYOUT);
        factory.adminReassignCreatorRights(token, PAYOUT);
        assertEq(_recipient(), address(vault));
        assertEq(vault.currentCreator(), PAYOUT);
    }

    function test_collect_splitsThreeBaskets() public {
        _trade();
        vault.collect();
        assertEq(vault.burnReserve(), 0.0014 ether, "20% burn");
        assertEq(vault.fundBalance(address(0)), 0.0021 ether, "30% community");
        assertEq(vault.xOwed(X_ID), 0.00175 ether, "X: 50% of the rest");
        assertEq(vault.creatorOwed(), 0.00175 ether, "creator: the rest");
        assertEq(address(vault).balance, 0.007 ether);
    }

    function test_settingsFrozenAtLaunch() public {
        factory.setQuoteLimits(
            address(0), PlaceLaunchFactoryCore.QuoteLimits({maxBurnPerProcess: 1 ether, defaultCampaignMinimum: 0})
        );
        assertEq(vault.settings().maxBurnPerProcess, MAX_BURN, "old launch keeps its cap");
    }

    // ───────────────────────────── process() ─────────────────────────────

    function test_process_anyoneBurnsToDead_upToCap() public {
        _trade();
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(ATTACKER);
        (uint256 collected, uint256 quoteIn, uint256 burned) = vault.process();
        assertEq(collected, 0.007 ether);
        assertEq(quoteIn, MAX_BURN, "capped at 0.001 ETH");
        assertGt(burned, 0);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, burned);
        assertEq(vault.burnReserve(), 0.0014 ether - MAX_BURN, "the rest waits");
        assertEq(vault.lastProcessAt(), block.timestamp);
    }

    function test_process_repeatInSameBlockReverts() public {
        _trade();
        vault.process();
        vm.expectRevert(abi.encodeWithSelector(PlaceCreatorVault.ProcessTooSoon.selector, block.timestamp + 1 days));
        vault.process();
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert();
        vault.process();
        vm.warp(block.timestamp + 1);
        (,, uint256 burned) = vault.process();
        assertGt(burned, 0);
        assertEq(vault.burnReserve(), 0, "0.0004 left, under the cap");
    }

    function test_claim_paysCreator_burnsOnlyWhenDue() public {
        _trade();
        vm.prank(CREATOR);
        uint256 paid = vault.claim();
        assertEq(paid, 0.00175 ether);
        assertEq(CREATOR.balance, 0.00175 ether);
        assertEq(vault.burnReserve(), 0.0014 ether - MAX_BURN, "claim ran the burn");
        // a second claim in the same interval does not burn again
        _trade();
        uint256 reserveBefore = vault.burnReserve();
        vm.prank(CREATOR);
        vault.claim();
        assertGt(vault.burnReserve(), reserveBefore, "booked, not burned");
        vm.expectRevert();
        vault.process();
    }

    function test_claim_onlyCreator() public {
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.claim();
    }

    /// A sandwich around the daily burn loses money: 1% fee each way against a capped, small buyback.
    function test_sandwich_unprofitable() public {
        _trade();
        uint256[3] memory sizes = [uint256(0.01 ether), 0.1 ether, 2 ether];
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < sizes.length; i++) {
            t += 1 days; // explicit clock: via-IR may cache block.timestamp across warps
            vm.warp(t);
            _trade(); // refills the burn reserve above the cap
            vm.deal(ATTACKER, 0);
            _swap(ATTACKER, key, token, true, sizes[i]);
            vault.process();
            uint256 bag = IERC20(token).balanceOf(ATTACKER);
            _swap(ATTACKER, key, token, false, bag);
            assertLt(ATTACKER.balance, sizes[i], "front-run + back-run loses");
            assertGt(ATTACKER.balance, sizes[i] * 95 / 100, "about the 2% fees");
        }
    }

    function test_reentrancy_blocked() public {
        ReentrantPayout bad = new ReentrantPayout();
        bad.setVault(vault);
        vm.prank(CREATOR);
        vault.setPayoutAddress(address(bad));
        _trade();
        vm.prank(CREATOR);
        vault.claim();
        assertEq(bad.attempts(), 1);
        assertEq(bytes4(bad.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(bad).balance, 0.00175 ether);
    }

    function test_unlockCallback_onlyFromOwnUnlock() public {
        vm.expectRevert(PlaceCreatorVault.NotPoolManager.selector);
        vault.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(PlaceCreatorVault.NotPoolManager.selector);
        vault.unlockCallback("");
    }

    // ───────────────────────────── Community fund ─────────────────────────────

    function test_fundCampaign_inQuote_noSwap_hubFee5() public {
        _trade();
        vm.prank(CREATOR);
        uint256 id = vault.fundCampaign(_campaign(address(0), 0.0021 ether, address(0), 0));
        IPlaceHub.CreateParams memory p = hub.created(id);
        assertEq(uint8(p.kind), uint8(IPlaceHub.Kind.TokenHolders));
        assertEq(p.target, token, "always this token");
        assertEq(p.rewardToken, address(0));
        assertEq(p.rulesHash, keccak256("rules"), "frozen template");
        assertEq(p.snapshotAt, block.timestamp + 24 hours);
        assertEq(p.metadataURI, "ipfs://campaign");
        assertEq(uint256(p.pool), uint256(0.0021 ether) * 10_000 / 10_500, "5% hub fee on top");
        assertEq(hub.creators(id), address(vault));
        assertLe(vault.fundBalance(address(0)), 1);
        assertEq(vault.lastFundSpendAt(), block.timestamp);
    }

    function test_fundCampaign_swapsToWhitelistedToken() public {
        _trade();
        vm.prank(CREATOR);
        uint256 id = vault.fundCampaign(_campaign(address(0), 0.002 ether, address(usd), 3e18));
        IPlaceHub.CreateParams memory p = hub.created(id);
        assertEq(p.rewardToken, address(usd));
        assertGt(uint256(p.pool), uint256(3e18) * 10_000 / 10_500);
        assertEq(usd.balanceOf(address(hub)), hub.paid(id));
        assertLe(usd.balanceOf(address(vault)), 1, "dust only");
        assertEq(vault.fundBalance(address(0)), 0.0001 ether, "the rest of the fund stays");
    }

    function test_fundCampaign_minOutProtects() public {
        _trade();
        vm.prank(CREATOR);
        vm.expectRevert();
        vault.fundCampaign(_campaign(address(0), 0.002 ether, address(usd), 100e18));
    }

    function test_fundCampaign_priceImpactCap() public {
        _trade();
        // the owner lists a thin ETH/USD pool: a 0.002 ETH swap moves it far more than 5%
        PoolKey memory thin =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usd)), 500, 10, IHooks(address(0)));
        pm.initialize(thin, TickMath.getSqrtPriceAtTick(76_020));
        lp.modifyLiquidity{value: 0.01 ether}(thin, IPoolManager.ModifyLiquidityParams(-887_270, 887_270, 1e17, 0), "");
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = thin;
        rewards.setRoute(address(0), address(usd), route);
        vm.prank(CREATOR);
        vm.expectPartialRevert(PlaceCreatorVault.PriceImpactTooHigh.selector);
        vault.fundCampaign(_campaign(address(0), 0.002 ether, address(usd), 0));
    }

    function test_fundCampaign_ownTokenThroughOwnPool() public {
        _trade();
        vm.prank(CREATOR);
        uint256 id = vault.fundCampaign(_campaign(address(0), 0.002 ether, token, 1));
        assertEq(hub.created(id).rewardToken, token);
        assertGt(IERC20(token).balanceOf(address(hub)), 0);
    }

    function test_fundCampaign_notListedReverts() public {
        _trade();
        // a token the creator controls, with a thin pool the creator made: not on the list
        MockERC20 fake = new MockERC20("FAKE", "FAKE", 18);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(PlaceCreatorVault.RouteNotListed.selector, address(0), address(fake)));
        vault.fundCampaign(_campaign(address(0), 0.002 ether, address(fake), 0));
    }

    function test_fundCampaign_onlyCreator_noOverspend() public {
        _trade();
        vm.prank(ATTACKER);
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.fundCampaign(_campaign(address(0), 0.001 ether, address(0), 0));
        vm.prank(CREATOR);
        vm.expectPartialRevert(PlaceCreatorVault.FundTooSmall.selector);
        vault.fundCampaign(_campaign(address(0), 0.0022 ether, address(0), 0)); // fund is 0.0021
        PlaceCreatorVault.CampaignRequest memory r = _campaign(address(0), 0.001 ether, address(0), 0);
        r.snapshotDelay = 10 minutes;
        vm.prank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        vault.fundCampaign(r);
    }

    function test_fundStaking_programAndRewards() public {
        _trade();
        uint256 platformUsdBefore = usd.balanceOf(PLATFORM);
        PlaceCreatorVault.StakingRequest memory r = PlaceCreatorVault.StakingRequest({
            fundAsset: address(0),
            amountIn: 0.002 ether,
            rewardToken: address(usd),
            minOut: 1e18,
            startTime: uint64(block.timestamp + 1 hours),
            epochDuration: 1 days,
            epochCount: 2,
            earlyExitMode: 0,
            penaltyBps: 0
        });
        vm.prank(CREATOR);
        bytes32 id = vault.fundStaking(r);
        VaultId vid = VaultId.wrap(id);
        (PlaceStakingView.VaultState memory s,) = PlaceStakingView(address(staking)).getVault(vid);
        assertEq(s.creator, address(vault));
        assertEq(s.config.stakingToken, token, "stakers of this token");
        uint256 total = uint256(s.config.rewardPerEpoch) * 2;
        assertEq(usd.balanceOf(address(staking)), total);
        assertApproxEqAbs(usd.balanceOf(PLATFORM) - platformUsdBefore, total * 500 / 10_000, 1, "5% fee");
        assertLe(usd.balanceOf(address(vault)), 3, "dust");

        // a holder stakes and claims the first epoch
        uint256 bag = IERC20(token).balanceOf(TRADER);
        vm.startPrank(TRADER);
        IERC20(token).approve(address(staking), bag);
        staking.deposit(vid, bag);
        vm.stopPrank();
        vm.warp(r.startTime + 1 days + 1);
        uint64[] memory epochs = new uint64[](1);
        vm.prank(TRADER);
        uint256 reward = staking.claim(vid, epochs, TRADER);
        assertApproxEqAbs(reward, s.config.rewardPerEpoch, 1e6, "sole staker gets the epoch");
        assertEq(usd.balanceOf(TRADER), reward);
    }

    function test_fundStaking_ownToken_inEth() public {
        _trade();
        PlaceCreatorVault.StakingRequest memory r = PlaceCreatorVault.StakingRequest({
            fundAsset: address(0),
            amountIn: 0.001 ether,
            rewardToken: address(0),
            minOut: 0,
            startTime: uint64(block.timestamp),
            epochDuration: 7 days,
            epochCount: 4,
            earlyExitMode: 1,
            penaltyBps: 1_000
        });
        vm.prank(CREATOR);
        vault.fundStaking(r);
        assertApproxEqAbs(address(staking).balance, uint256(0.001 ether) * 10_000 / 10_500, 4);
        assertLe(_spent(), 0.001 ether);
        assertEq(vault.fundBalance(address(0)), 0.0021 ether - _spent(), "the rest and the dust stay");
    }

    function _spent() internal view returns (uint256) {
        return address(staking).balance + PLATFORM.balance - 0.0005 ether; // minus the launch fee
    }

    /// The creator has no path to the community fund: every creator action leaves it in place or sends it
    /// to the hub / staking for this token.
    function test_fundCannotBeWithdrawnByCreator() public {
        _trade();
        vault.collect();
        uint256 fund = vault.fundBalance(address(0));
        assertEq(fund, 0.0021 ether);
        vm.startPrank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        vault.claim();
        vault.increaseEconomics(2_000, 3_000);
        vm.stopPrank();
        assertEq(PAYOUT.balance, 0.00175 ether, "only the creator share");
        // the fund can only grow (the claim's burn paid the pool fee, 0.7% of it came back to the baskets)
        assertGe(vault.fundBalance(address(0)), fund, "fund untouched");
        fund = vault.fundBalance(address(0));
        // admin reassignment does not unlock it either
        factory.adminReassignCreatorRights(token, ATTACKER);
        vm.prank(ATTACKER);
        vault.claim();
        assertLe(ATTACKER.balance, 0.00001 ether, "only the newly booked creator share");
        assertGe(vault.fundBalance(address(0)), fund);
        // no function sends fund assets anywhere else
        bytes4[4] memory selectors = [
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("withdrawFund(address,uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("rescue(address,address,uint256)"))
        ];
        for (uint256 i = 0; i < selectors.length; i++) {
            vm.prank(ATTACKER);
            (bool ok,) = address(vault).call(abi.encodeWithSelector(selectors[i], ATTACKER, fund));
            assertFalse(ok);
        }
        assertGe(vault.fundBalance(address(0)), fund);
    }

    function test_defaultCampaign_after30DaysIdle() public {
        _trade();
        vm.expectRevert();
        vault.startDefaultCampaign();
        vm.warp(block.timestamp + 30 days);
        vm.prank(ATTACKER);
        uint256 id = vault.startDefaultCampaign();
        IPlaceHub.CreateParams memory p = hub.created(id);
        assertEq(p.target, token);
        assertEq(p.rewardToken, address(0));
        assertEq(p.snapshotAt, block.timestamp + 24 hours);
        assertEq(p.claimDuration, 30 days);
        assertTrue(p.burnLeftover);
        assertApproxEqAbs(p.pool, uint256(0.0021 ether) * 10_000 / 10_500, 1);
        // the next one waits another 30 days
        _trade();
        vm.expectRevert();
        vault.startDefaultCampaign();
    }

    function test_defaultCampaign_creatorSpendResetsTimer() public {
        _trade();
        uint256 t = vm.getBlockTimestamp() + 29 days; // cheatcode: via-IR may re-read block.timestamp
        vm.warp(t);
        vm.prank(CREATOR);
        vault.fundCampaign(_campaign(address(0), 0.001 ether, address(0), 0));
        vm.warp(t + 2 days); // 31 days after launch, 2 days after the creator's spend
        vm.expectPartialRevert(PlaceCreatorVault.DefaultCampaignTooSoon.selector);
        vault.startDefaultCampaign();
        vm.warp(t + 30 days);
        vault.startDefaultCampaign();
    }

    function test_defaultCampaign_belowMinimum() public {
        _swap(TRADER, key, token, true, 0.1 ether); // fund 0.00021 < 0.001
        vm.warp(block.timestamp + 30 days);
        vm.expectPartialRevert(PlaceCreatorVault.FundTooSmall.selector);
        vault.startDefaultCampaign();
    }

    function test_refundUnpublished_returnsToFund() public {
        _trade();
        vm.prank(CREATOR);
        uint256 id = vault.fundCampaign(_campaign(address(0), 0.002 ether, address(usd), 0));
        uint256 paid = hub.paid(id);
        uint256 dust = usd.balanceOf(address(vault));
        vm.prank(ATTACKER); // permissionless: the money can only come back to the vault
        vault.refundUnpublishedCampaign(id);
        assertEq(vault.fundBalance(address(usd)), paid + dust, "USD back in the fund");
        // and it can fund the next campaign in USD without a swap
        vm.prank(CREATOR);
        vault.fundCampaign(_campaign(address(usd), paid + dust, address(usd), 0));
    }

    // ───────────────────────────── Economics ─────────────────────────────

    function test_increaseEconomics_onlyUp() public {
        vm.startPrank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.OnlyIncrease.selector);
        vault.increaseEconomics(1_000, 3_000);
        vm.expectRevert(PlaceCreatorVault.OnlyIncrease.selector);
        vault.increaseEconomics(2_000, 2_999);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        vault.increaseEconomics(5_000, 6_000);
        vault.increaseEconomics(3_000, 4_000);
        vm.stopPrank();
        assertEq(vault.burnBps(), 3_000);
        assertEq(vault.communityBps(), 4_000);
        vm.expectRevert(PlaceCreatorVault.NotCreator.selector);
        vault.increaseEconomics(4_000, 4_000);
    }

    /// Decision #22: a "100% creator" launch can add burn and community later.
    function test_noEconomicsAtLaunch_addLater() public {
        (address t,, PoolKey memory k, PlaceCreatorVault v) = _launchEco(0, 0, 0, 0);
        _swap(TRADER, k, t, true, 1 ether);
        vm.prank(CREATOR);
        v.increaseEconomics(1_000, 2_000);
        assertEq(v.creatorOwed(), 0.007 ether, "pending fees booked at the old shares");
        _swap(TRADER, k, t, true, 1 ether);
        v.collect();
        assertGt(v.burnReserve(), 0);
        assertGt(v.fundBalance(address(0)), 0);
    }

    function test_payoutResetsOnRightsTransfer() public {
        vm.prank(CREATOR);
        vault.setPayoutAddress(PAYOUT);
        address next = address(0x2222);
        vm.prank(CREATOR);
        factory.proposeCreatorRightsTransfer(token, next);
        vm.prank(next);
        factory.acceptCreatorRightsTransfer(token);
        assertEq(vault.payoutAddress(), next);
    }

    function test_claimX_afterBinding() public {
        _trade();
        vm.expectRevert(abi.encodeWithSelector(PlaceCreatorVault.XNotBound.selector, X_ID));
        vault.claimX(X_ID);
        xreg.bind(X_ID, X_WALLET);
        vault.claimX(X_ID);
        assertEq(X_WALLET.balance, 0.00175 ether);
        assertEq(vault.xOwedTotal(), 0);
    }

    function test_invalidEconomics_reverts() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.burnBps = 6_000;
        p.economics.communityBps = 5_000;
        _mineSalt(p, CREATOR);
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.InvalidConfig.selector);
        factory.createLaunch{value: 0.0005 ether}(p);
    }

    function test_communityNeedsHub() public {
        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: address(0),
                xRegistry: address(0),
                staking: address(0),
                rewardRegistry: address(0),
                processInterval: 1 days,
                defaultCampaignDelay: 30 days,
                rulesHash: bytes32(0),
                rulesURI: ""
            })
        );
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.communityBps = 1;
        _mineSalt(p, CREATOR);
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(PlaceCreatorVault.CommunityDisabled.selector);
        factory.createLaunch{value: 0.0005 ether}(p);
    }

    function test_vaultCannotBeReinitialized() public {
        PlaceCreatorVault.Initialization memory init;
        vm.expectRevert();
        vault.initialize(init);
    }
}

/// @dev View of PlaceStaking's `getVault` with the o1 struct layout (VaultParams has the enum as uint8).
interface PlaceStakingView {
    struct VaultParams {
        address stakingToken;
        address rewardCurrency;
        uint64 startTime;
        uint64 epochDuration;
        uint64 epochCount;
        uint192 rewardPerEpoch;
        uint8 earlyExitMode;
        uint16 penaltyBps;
    }

    struct VaultState {
        VaultParams config;
        address creator;
        uint64 endTime;
        uint192 totalStaked;
        uint256 rewardRemaining;
    }

    function getVault(VaultId vaultId) external view returns (VaultState memory vault, uint64 depositOpenTime);
}
