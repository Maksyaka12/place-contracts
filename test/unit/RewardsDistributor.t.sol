// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {MerkleHelper} from "../utils/Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RewardsDistributorTest is LaunchFixture {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant FUNDER = address(0xF00D);

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
    }

    function _launchEco(address reward) internal returns (address token, PoolKey memory key) {
        (token,) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 3, [uint32(20), 20, 20, 20, 20], reward
            )
        );
        key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
    }

    function _publish(bytes32 id, uint64 epoch, bytes32 root, uint256 total) internal {
        vm.prank(PUBLISHER);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(id, epoch, root, total, "ipfs://table"));
    }

    /// @dev Two-account tree; returns proofs for ALICE and BOB.
    function _tree(bytes32 id, uint256 a, uint256 b)
        internal
        pure
        returns (bytes32 root, bytes32[] memory proofA, bytes32[] memory proofB)
    {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleHelper.leaf(id, ALICE, a);
        leaves[1] = MerkleHelper.leaf(id, BOB, b);
        bytes32[][] memory proofs;
        (root, proofs) = MerkleHelper.build(leaves);
        proofA = proofs[0];
        proofB = proofs[1];
    }

    // ───────────── epochs ─────────────

    function test_closeEpoch_onceADay_collectsInQuote() public {
        (address token, PoolKey memory key) = _launchEco(address(0));
        _swap(TRADER, key, token, true, 1 ether);
        bytes32 id = _holdersId(token);
        vm.expectRevert(PlaceRewardsDistributor.NothingToClose.selector);
        distributor.closeEpoch(token); // the launch day is not over
        _nextDay();
        distributor.closeEpoch(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        assertEq(s.funded, 0.0042 ether, "holders basket of the day");
        assertEq(s.lastClosedEpoch, distributor.currentEpoch() - 1);
        assertEq(distributor.stream(_tradersId(token)).funded, 0.0042 ether);
        assertEq(distributor.liabilities(address(0)), 0.0084 ether);
        vm.expectRevert(PlaceRewardsDistributor.NothingToClose.selector);
        distributor.closeEpoch(token);
    }

    function test_closeEpoch_swapsIntoRewardToken() public {
        (address token, PoolKey memory key) = _launchEco(address(usd));
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(_holdersId(token));
        assertEq(s.pendingInput, 0);
        assertGt(s.funded, 8e18, "~0.0042 ETH in USD");
        assertEq(distributor.liabilities(address(0)), 0, "nothing left in ETH");
        assertGe(usd.balanceOf(address(distributor)), distributor.liabilities(address(usd)));
    }

    function test_conversionDeferred_thenConvertedInSlices() public {
        (address token, PoolKey memory key) = _launchEco(address(usd));
        _swap(TRADER, key, token, true, 1 ether);
        rewards.setMaxPriceImpactBps(1); // 0.01%: the daily swap is too large
        _nextDay();
        distributor.closeEpoch(token);
        bytes32 id = _holdersId(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        assertEq(s.pendingInput, 0.0042 ether, "kept in ETH");
        assertEq(s.funded, 0);
        assertEq(s.lastClosedEpoch, distributor.currentEpoch() - 1, "the epoch still closed");
        rewards.setMaxPriceImpactBps(MAX_IMPACT);
        distributor.convert(id, 0.002 ether);
        assertEq(distributor.stream(id).pendingInput, 0.0022 ether);
        distributor.convert(id, 0);
        assertEq(distributor.stream(id).pendingInput, 0);
        assertGt(distributor.stream(id).funded, 0);
    }

    function test_rewardInOwnToken_buysThroughOwnPool() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _economyParams(
            PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 3, [uint32(20), 20, 20, 20, 20], address(0)
        );
        _mineSalt(p, CREATOR);
        p.economics.rewardToken = factory.predictLaunchToken(p, CREATOR);
        (address token,) = _launch(p);
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, _poolKey(token, address(0)), token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(_holdersId(token));
        assertGt(s.funded, 0, "funded in the launch token");
        assertGe(IERC20(token).balanceOf(address(distributor)), distributor.liabilities(token));
    }

    // ───────────── roots and claims ─────────────

    function test_publishAndClaim_cumulative_andClaimMany() public {
        (address token, PoolKey memory key) = _launchEco(address(0));
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        bytes32 h = _holdersId(token);
        bytes32 t = _tradersId(token);
        uint64 day1 = distributor.currentEpoch() - 1;

        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(h, 0.003 ether, 0.0012 ether);
        _publish(h, day1, root, 0.0042 ether);
        distributor.claim(h, ALICE, 0.003 ether, pa);
        assertEq(ALICE.balance, 0.003 ether);
        vm.expectRevert(PlaceRewardsDistributor.NothingToClaim.selector);
        distributor.claim(h, ALICE, 0.003 ether, pa);

        // day 2: more trading; cumulative amounts grow
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        uint64 day2 = distributor.currentEpoch() - 1;
        (root, pa, pb) = _tree(h, 0.005 ether, 0.0034 ether);
        _publish(h, day2, root, 0.0084 ether);
        (bytes32 rootT,, bytes32[] memory tb) = _tree(t, 0, 0.0084 ether);
        _publish(t, day2, rootT, 0.0084 ether);

        PlaceRewardsDistributor.ClaimRequest[] memory reqs = new PlaceRewardsDistributor.ClaimRequest[](3);
        reqs[0] = PlaceRewardsDistributor.ClaimRequest(h, ALICE, 0.005 ether, pa);
        reqs[1] = PlaceRewardsDistributor.ClaimRequest(h, BOB, 0.0034 ether, pb);
        reqs[2] = PlaceRewardsDistributor.ClaimRequest(t, BOB, 0.0084 ether, tb);
        uint256[] memory paid = distributor.claimMany(reqs);
        assertEq(paid[0], 0.002 ether, "only the difference");
        assertEq(ALICE.balance, 0.005 ether);
        assertEq(BOB.balance, 0.0034 ether + 0.0084 ether, "two tokens' streams in one call");
        assertEq(distributor.liabilities(address(0)), 0);
    }

    function test_noEligibleDay_budgetCarriesOver() public {
        (address token, PoolKey memory key) = _launchEco(address(0));
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token); // day 1: nobody eligible, no root
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        bytes32 h = _holdersId(token);
        (bytes32 root, bytes32[] memory pa,) = _tree(h, 0.0084 ether, 0);
        _publish(h, distributor.currentEpoch() - 1, root, 0.0084 ether); // both days' budget on day 2
        distributor.claim(h, ALICE, 0.0084 ether, pa);
        assertEq(ALICE.balance, 0.0084 ether);
    }

    function test_publish_rules() public {
        (address token, PoolKey memory key) = _launchEco(address(0));
        _swap(TRADER, key, token, true, 1 ether);
        bytes32 h = _holdersId(token);
        uint64 today = distributor.currentEpoch();
        vm.expectRevert(PlaceRewardsDistributor.InvalidEpoch.selector);
        vm.prank(PUBLISHER);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(h, today, bytes32("r"), 0, ""));
        _nextDay();
        distributor.closeEpoch(token);
        vm.expectRevert(PlaceRewardsDistributor.NotPublisher.selector);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(h, today, bytes32("r"), 1, ""));
        vm.expectRevert(PlaceRewardsDistributor.InvalidAllocation.selector);
        vm.prank(PUBLISHER);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(h, today, bytes32("r"), 0.0042 ether + 1, ""));
        _publish(h, today, bytes32("r"), 0.004 ether);
        vm.expectRevert(PlaceRewardsDistributor.InvalidAllocation.selector);
        vm.prank(PUBLISHER);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(h, today, bytes32("r"), 0.003 ether, ""));
    }

    function test_badTree_cannotPayMoreThanAllocated() public {
        (address token, PoolKey memory key) = _launchEco(address(0));
        _swap(TRADER, key, token, true, 1 ether);
        _nextDay();
        distributor.closeEpoch(token);
        bytes32 h = _holdersId(token);
        // a faulty table gives both accounts the whole budget
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(h, 0.0042 ether, 0.0042 ether);
        _publish(h, distributor.currentEpoch() - 1, root, 0.0042 ether);
        distributor.claim(h, ALICE, 0.0042 ether, pa);
        vm.expectRevert(PlaceRewardsDistributor.ExceedsAllocation.selector);
        distributor.claim(h, BOB, 0.0042 ether, pb);
        vm.expectRevert(PlaceRewardsDistributor.InvalidProof.selector);
        distributor.claim(h, BOB, 0.001 ether, pb);
        assertEq(distributor.liabilities(address(0)), 0.0042 ether, "traders stream intact");
    }

    // ───────────── funded streams ─────────────

    function _fundUsdStream(uint64 startEpoch, uint64 epochs, uint256 perEpoch) internal returns (bytes32 id) {
        uint256 total = perEpoch * epochs;
        uint256 due = total + (total * STREAM_FEE + 9_999) / 10_000;
        usd.mint(FUNDER, due);
        vm.startPrank(FUNDER);
        usd.approve(address(distributor), due);
        id = distributor.createStream(
            IPlaceRewardsDistributor.CreateParams({
                token: address(usd),
                kind: IPlaceRewardsDistributor.Kind.Holders,
                rewardToken: address(usd),
                startEpoch: startEpoch,
                epochCount: epochs,
                rewardPerEpoch: perEpoch,
                criterion: 1e18,
                metadataURI: "ipfs://campaign"
            })
        );
        vm.stopPrank();
    }

    function test_fundedStream_releasesPerEpoch_feeToPlatform() public {
        uint64 start = distributor.currentEpoch() + 1;
        bytes32 id = _fundUsdStream(start, 3, 100e18);
        assertEq(usd.balanceOf(PLATFORM), 15e18, "5% stream fee");
        assertEq(distributor.stream(id).reserved, 300e18);
        _nextDay();
        vm.expectRevert(PlaceRewardsDistributor.NothingToClose.selector);
        distributor.closeStream(id); // the first epoch is today
        _nextDay();
        distributor.closeStream(id);
        assertEq(distributor.stream(id).funded, 100e18);
        _nextDay();
        _nextDay();
        _nextDay();
        distributor.closeStream(id); // skipped days: releases the rest, never beyond the last epoch
        assertEq(distributor.stream(id).funded, 300e18);
        assertEq(distributor.stream(id).reserved, 0);
        assertFalse(distributor.closable(id));
    }

    function test_fundedStream_reclaimUnallocated() public {
        uint64 start = distributor.currentEpoch();
        bytes32 id = _fundUsdStream(start, 2, 100e18);
        _nextDay();
        _nextDay();
        distributor.closeStream(id);
        (bytes32 root, bytes32[] memory pa,) = _tree(id, 50e18, 0);
        _publish(id, start + 1, root, 50e18);
        vm.expectRevert(PlaceRewardsDistributor.NotReclaimable.selector);
        distributor.reclaimUnallocated(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        distributor.reclaimUnallocated(id);
        assertEq(usd.balanceOf(FUNDER), 150e18, "unallocated back to the funder");
        distributor.claim(id, ALICE, 50e18, pa);
        assertEq(usd.balanceOf(ALICE), 50e18, "allocations stay claimable");
        assertEq(distributor.liabilities(address(usd)), 0);
    }

    function test_createStream_validation() public {
        uint64 today = distributor.currentEpoch();
        IPlaceRewardsDistributor.CreateParams memory p = IPlaceRewardsDistributor.CreateParams({
            token: address(usd),
            kind: IPlaceRewardsDistributor.Kind.Traders,
            rewardToken: address(0),
            startEpoch: today - 1,
            epochCount: 1,
            rewardPerEpoch: 1 ether,
            criterion: 0,
            metadataURI: ""
        });
        vm.expectRevert(PlaceRewardsDistributor.InvalidConfig.selector);
        distributor.createStream{value: 1.05 ether}(p);
        p.startEpoch = today;
        vm.expectRevert(PlaceRewardsDistributor.InvalidPayment.selector);
        distributor.createStream{value: 1 ether}(p);
        p.token = address(0xDEAD0);
        vm.expectRevert(PlaceRewardsDistributor.InvalidConfig.selector);
        distributor.createStream{value: 1.05 ether}(p);
        p.token = address(usd);
        bytes32 id = distributor.createStream{value: 1.05 ether}(p);
        assertEq(distributor.stream(id).funder, address(this));
        assertEq(PLATFORM.balance, 0.05 ether);
    }

    function test_owner_settings() public {
        vm.expectRevert(PlaceRewardsDistributor.InvalidConfig.selector);
        distributor.setStreamFee(1_001, PLATFORM);
        distributor.setStreamFee(0, address(0));
        distributor.setPublisher(ALICE);
        assertEq(distributor.publisher(), ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        distributor.setPublisher(BOB);
    }

    // ───────────── fuzz ─────────────

    /// Random trading days, random allocations within what is funded, random claims: the distributor always holds
    /// what it owes and never pays more than a root allocates.
    function testFuzz_solvent(uint96[4] memory buys, uint16[4] memory aliceBps, bool usdReward) public {
        (address token, PoolKey memory key) = _launchEco(usdReward ? address(usd) : address(0));
        bytes32 h = _holdersId(token);
        address reward = usdReward ? address(usd) : address(0);
        uint256 a;
        for (uint256 d = 0; d < 4; d++) {
            _swap(TRADER, key, token, true, bound(buys[d], 1e12, 3 ether));
            _nextDay();
            distributor.closeEpoch(token);
            uint256 funded = distributor.stream(h).funded;
            uint256 allocated = distributor.stream(h).allocated;
            // allocate part of the new budget, split between Alice and Bob
            uint256 total = allocated + (funded - allocated) * bound(aliceBps[d], 0, 10_000) / 10_000;
            a = a + (total - allocated) / 3;
            uint256 b = total - a;
            (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _tree(h, a, b);
            _publish(h, distributor.currentEpoch() - 1, root, total);
            if (d % 2 == 0) {
                if (a > distributor.claimedBy(h, ALICE)) distributor.claim(h, ALICE, a, pa);
            } else if (b > distributor.claimedBy(h, BOB)) {
                distributor.claim(h, BOB, b, pb);
            }
            uint256 balance = reward == address(0) ? address(distributor).balance : usd.balanceOf(address(distributor));
            assertGe(balance, distributor.liabilities(reward), "solvent");
            assertLe(distributor.stream(h).claimed, distributor.stream(h).allocated);
            assertLe(distributor.stream(h).allocated, distributor.stream(h).funded);
        }
    }
}
