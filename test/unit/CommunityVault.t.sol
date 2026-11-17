// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCommunityVault} from "../../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract CommunityVaultTest is LaunchFixture {
    address internal token;
    PoolKey internal key;
    PlaceCommunityVault internal vault;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        (token,) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 5, 5, [uint32(20), 20, 0, 0, 60], address(0)
            )
        );
        key = _poolKey(token, address(0));
        vault = _community(token);
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether); // 5%: 1.5% platform, 3.5% x 60% = 0.021 ETH to the pool
    }

    function _campaign(address rewardToken, uint256 amountIn, uint256 minOut)
        internal
        view
        returns (PlaceCommunityVault.CampaignRequest memory r)
    {
        r.kind = IPlaceRewardsDistributor.Kind.Holders;
        r.fundAsset = address(0);
        r.amountIn = amountIn;
        r.rewardToken = rewardToken;
        r.minOut = minOut;
        r.startEpoch = uint64(block.timestamp / 1 days) + 1; // no external call: keeps vm.prank for the vault
        r.epochCount = 10;
        r.criterion = 50_000e18;
        r.metadataURI = "ipfs://campaign";
    }

    function test_basketArrives() public {
        assertEq(vault.pendingFees(), 0.021 ether);
        vault.collect();
        assertEq(vault.fundBalance(address(0)), 0.021 ether);
        assertEq(vault.token(), token);
        assertEq(vault.quote(), address(0));
    }

    function test_noWithdrawPath() public {
        vault.collect();
        string[6] memory sigs = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "claim()",
            "sweep(address)",
            "rescue(address)",
            "transfer(address,uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(CREATOR);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(sigs[i], CREATOR, 1));
            assertFalse(ok, sigs[i]);
        }
        assertEq(vault.fundBalance(address(0)), 0.021 ether);
    }

    function test_fundCampaign_holdersInQuote() public {
        vm.prank(CREATOR);
        bytes32 id = vault.fundCampaign(_campaign(address(0), 0.021 ether, 0));
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        assertEq(s.token, token);
        assertEq(s.funder, address(vault), "leftovers come back to the pool");
        assertEq(s.rewardToken, address(0));
        assertEq(s.epochCount, 10);
        assertEq(s.criterion, 50_000e18);
        uint256 total = s.rewardPerEpoch * 10;
        assertLe(total + (total * STREAM_FEE + 9_999) / 10_000, 0.021 ether);
        assertLt(vault.fundBalance(address(0)), 1e6, "only dust stays");
    }

    function test_fundCampaign_tradersSwappedToUsd() public {
        PlaceCommunityVault.CampaignRequest memory r = _campaign(address(usd), 0.01 ether, 19e18);
        r.kind = IPlaceRewardsDistributor.Kind.Traders;
        vm.prank(CREATOR);
        bytes32 id = vault.fundCampaign(r);
        assertEq(distributor.stream(id).rewardToken, address(usd));
        assertEq(uint8(distributor.stream(id).kind), uint8(IPlaceRewardsDistributor.Kind.Traders));
        assertEq(vault.fundBalance(address(0)), 0.011 ether);
    }

    function test_fundCampaign_inOwnToken() public {
        vm.prank(CREATOR);
        bytes32 id = vault.fundCampaign(_campaign(token, 0.01 ether, 1));
        assertEq(distributor.stream(id).rewardToken, token);
    }

    function test_fundCampaign_guards() public {
        vm.expectRevert(PlaceCommunityVault.NotCreator.selector);
        vault.fundCampaign(_campaign(address(0), 0.01 ether, 0));
        vm.expectPartialRevert(PlaceCommunityVault.SlippageExceeded.selector);
        vm.prank(CREATOR);
        vault.fundCampaign(_campaign(address(usd), 0.01 ether, 1_000e18));
        address unlisted = address(new PlaceCommunityVault(address(0), address(0)));
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.RouteNotListed.selector, address(0), unlisted));
        vm.prank(CREATOR);
        vault.fundCampaign(_campaign(unlisted, 0.01 ether, 0));
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.FundTooSmall.selector, 0.021 ether, 1 ether));
        vm.prank(CREATOR);
        vault.fundCampaign(_campaign(address(0), 1 ether, 0));
    }

    function test_fundStaking() public {
        PlaceCommunityVault.StakingRequest memory r = PlaceCommunityVault.StakingRequest({
            fundAsset: address(0),
            amountIn: 0.01 ether,
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
        assertApproxEqAbs(address(staking).balance, uint256(0.01 ether) * 10_000 / 10_500, 4);
        assertGe(vault.fundBalance(address(0)), 0.011 ether);
    }

    function test_defaultCampaign_after30Days() public {
        uint64 nextAt = uint64(vault.lastFundSpendAt()) + DEFAULT_DELAY;
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.DefaultCampaignTooSoon.selector, nextAt));
        vault.startDefaultCampaign();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        bytes32 id = vault.startDefaultCampaign();
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        assertEq(uint8(s.kind), uint8(IPlaceRewardsDistributor.Kind.Holders));
        assertEq(s.rewardToken, address(0));
        assertEq(s.epochCount, DEFAULT_EPOCHS);
        assertEq(s.startEpoch, distributor.currentEpoch() + 1);
        assertEq(s.criterion, 100_000e18, "the launch's holder threshold");
        assertEq(s.funder, address(vault));
        vm.expectRevert();
        vault.startDefaultCampaign(); // the timer restarted
    }

    function test_defaultCampaign_tooSmall() public {
        // a fresh launch with an empty pool
        (address other,) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 1, 1, [uint32(50), 0, 0, 0, 50], address(0)
            )
        );
        PlaceCommunityVault empty = _community(other);
        assertEq(empty.settings().defaultMinHolding, 10_000e18, "no holders basket: 10,000 tokens");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.FundTooSmall.selector, 0, DEFAULT_MIN));
        empty.startDefaultCampaign();
    }

    function test_unallocatedBudget_returnsToPool() public {
        vm.prank(CREATOR);
        bytes32 id = vault.fundCampaign(_campaign(address(0), 0.021 ether, 0));
        uint256 dust = vault.fundBalance(address(0));
        for (uint256 i = 0; i < 11; i++) {
            _nextDay();
        }
        distributor.closeStream(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        distributor.reclaimUnallocated(id);
        assertEq(vault.fundBalance(address(0)), dust + distributor.stream(id).rewardPerEpoch * 10);
    }

    function test_initialize_onlyOnce() public {
        PlaceCommunityVault.Initialization memory init;
        vm.expectRevert();
        vault.initialize(init);
    }
}
