// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {MerkleHelper} from "../utils/Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceFeeMath} from "../../src/launch/PlaceFeeMath.sol";
import {PlaceCommunityVault} from "../../src/place/PlaceCommunityVault.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Random trading, epochs, roots, claims, burns and community pool spending against one Economy launch.
contract EconomyHandler is Test {
    EconomyInvariantsTest internal immutable suite;

    constructor(EconomyInvariantsTest suite_) {
        suite = suite_;
    }

    function buy(uint256 amount) external {
        suite.doSwap(true, bound(amount, 1e12, 3 ether));
    }

    function sell(uint256 fraction) external {
        suite.doSwap(false, bound(fraction, 1, 100));
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1 hours, 2 days));
    }

    function closeEpoch() external {
        suite.doClose();
    }

    function publish(uint256 bps, bool holders) external {
        suite.doPublish(bound(bps, 0, 10_000), holders);
    }

    function claim(bool holders) external {
        suite.doClaim(holders);
    }

    function burn() external {
        suite.doBurn();
    }

    function fundCampaign(uint256 amount, bool inUsd) external {
        suite.doFundCampaign(amount, inUsd);
    }

    function defaultCampaign() external {
        suite.doDefaultCampaign();
    }

    function creatorClaim() external {
        suite.doCreatorClaim();
    }
}

contract EconomyInvariantsTest is LaunchFixture {
    address internal constant ALICE = address(0xA11CE);

    EconomyHandler internal handler;
    address internal token;
    PoolKey internal key;
    PoolId internal poolId;
    PlaceCommunityVault internal community;
    PlaceCreatorVault internal creatorVault;

    /// @dev Set when ETH leaves the community pool anywhere but into reward programs.
    bool public communityLeak;
    uint256 public communitySpent;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        (token, poolId) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 5, [uint32(15), 25, 20, 10, 30], address(usd)
            )
        );
        key = _poolKey(token, address(0));
        community = _community(token);
        creatorVault = _vault(token);
        vm.warp(vm.getBlockTimestamp() + 21);
        handler = new EconomyHandler(this);
        targetContract(address(handler));
    }

    // ───────────── actions (called by the handler) ─────────────

    function doSwap(bool isBuy, uint256 amount) external {
        if (isBuy) {
            _swap(TRADER, key, token, true, amount);
        } else {
            uint256 balance = IERC20(token).balanceOf(TRADER);
            if (balance == 0) return;
            _swap(TRADER, key, token, false, balance * amount / 100);
        }
    }

    function doClose() external {
        try distributor.closeEpoch(token) {} catch {}
    }

    function doPublish(uint256 bps, bool holders) external {
        bytes32 id = holders ? _holdersId(token) : _tradersId(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        if (s.lastClosedEpoch < s.startEpoch) return;
        uint256 total = s.allocated + (s.funded - s.allocated) * bps / 10_000;
        // a one-leaf tree: the root is the leaf itself
        vm.prank(PUBLISHER);
        distributor.publishRoot(
            PlaceRewardsDistributor.RootUpdate(id, s.lastClosedEpoch, MerkleHelper.leaf(id, ALICE, total), total, "")
        );
    }

    function doClaim(bool holders) external {
        bytes32 id = holders ? _holdersId(token) : _tradersId(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        if (s.root == bytes32(0) || s.allocated <= distributor.claimedBy(id, ALICE)) return;
        distributor.claim(id, ALICE, s.allocated, new bytes32[](0));
    }

    function doBurn() external {
        if (escrow.pendingBurn(token) != 0) escrow.burn(token);
    }

    function doFundCampaign(uint256 amount, bool inUsd) external {
        community.collect();
        uint256 available = community.fundBalance(address(0));
        if (available < 1e9) return;
        PlaceCommunityVault.CampaignRequest memory r;
        r.kind = IPlaceRewardsDistributor.Kind.Holders;
        r.fundAsset = address(0);
        r.amountIn = bound(amount, 1e9, available);
        r.rewardToken = inUsd ? address(usd) : address(0);
        r.startEpoch = uint64(block.timestamp / 1 days) + 1;
        r.epochCount = 3;
        r.criterion = 10_000e18;
        _trackCommunity(abi.encodeCall(PlaceCommunityVault.fundCampaign, (r)), CREATOR);
    }

    function doDefaultCampaign() external {
        _trackCommunity(abi.encodeCall(PlaceCommunityVault.startDefaultCampaign, ()), address(this));
    }

    function doCreatorClaim() external {
        vm.prank(CREATOR);
        creatorVault.claim();
    }

    /// @dev Runs a community vault call and checks that every wei that left went to the distributor, staking or
    ///      (as the stream fee) the platform.
    function _trackCommunity(bytes memory data, address caller) internal {
        community.collect();
        uint256 vaultBefore = address(community).balance;
        uint256 programsBefore = address(distributor).balance + address(staking).balance + PLATFORM.balance;
        uint256 programsUsdBefore = usd.balanceOf(address(distributor)) + usd.balanceOf(PLATFORM);
        uint256 creatorBefore = CREATOR.balance;
        vm.prank(caller);
        (bool ok,) = address(community).call(data);
        if (!ok) return;
        uint256 out = vaultBefore - address(community).balance;
        uint256 intoPrograms =
            address(distributor).balance + address(staking).balance + PLATFORM.balance - programsBefore;
        uint256 usdIn = usd.balanceOf(address(distributor)) + usd.balanceOf(PLATFORM) - programsUsdBefore;
        communitySpent += out;
        // ETH reward: all of it reaches the programs; USD reward: it went through the swap into the distributor
        if (intoPrograms != out && usdIn == 0) communityLeak = true;
        if (CREATOR.balance != creatorBefore) communityLeak = true;
        if (usd.balanceOf(address(community)) > 1e6) communityLeak = true; // only rounding dust may stay
    }

    // ───────────── invariants ─────────────

    function invariant_basketsSumTo100() public view {
        (,,,,,,,,,,,, PlaceFeeMath.TaxConfiguration memory tax) = hook.poolConfig(poolId);
        assertEq(PlaceFeeMath.shareSum(tax), SCALE);
        assertEq(tax.buyTaxRate, 3_000_000);
        assertEq(tax.sellTaxRate, 5_000_000);
    }

    function invariant_communityPoolOnlyFundsPrograms() public view {
        assertFalse(communityLeak);
    }

    function invariant_distributorSolvent() public view {
        assertGe(address(distributor).balance, distributor.liabilities(address(0)), "ETH");
        assertGe(usd.balanceOf(address(distributor)), distributor.liabilities(address(usd)), "USD");
        bytes32[2] memory ids = [_holdersId(token), _tradersId(token)];
        for (uint256 i = 0; i < 2; i++) {
            PlaceRewardsDistributor.Stream memory s = distributor.stream(ids[i]);
            assertLe(s.claimed, s.allocated, "claimed <= allocated");
            assertLe(s.allocated, s.funded, "allocated <= funded");
        }
    }

    function invariant_escrowBacksEveryCredit() public view {
        uint256 ethOwed = escrow.owed(PLATFORM, address(0)) + escrow.owed(address(creatorVault), address(0))
            + escrow.owed(address(community), address(0))
            + escrow.accountOwed(address(distributor), _holdersId(token), address(0))
            + escrow.accountOwed(address(distributor), _tradersId(token), address(0));
        assertGe(pm.balanceOf(address(escrow), Currency.wrap(address(0)).toId()), ethOwed, "ETH claims");
        assertGe(pm.balanceOf(address(escrow), Currency.wrap(token).toId()), escrow.pendingBurn(token), "burn claims");
    }
}
