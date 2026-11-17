// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCommunityVault} from "../../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {PlaceNftCollection} from "../../src/nft/PlaceNftCollection.sol";
import {PlacePriceGuard} from "../../src/nft/PlacePriceGuard.sol";

/// @notice Community Pool: NFT holders campaigns for collections of its token, buyback and burn.
contract CommunityVaultNftTest is LaunchFixture {
    address internal constant ALICE = address(0xA11CE);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal token;
    PoolKey internal key;
    PoolKey[] internal route;
    PlaceCommunityVault internal vault;
    PlaceNftCollection internal official;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        (token,) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 5, 5, [uint32(20), 20, 0, 0, 60], address(0)
            )
        );
        key = _poolKey(token, address(0));
        route.push(key);
        vault = _community(token);
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether); // 0.021 ETH to the community pool
        _warmGuard(route);
        official = _collection(CREATOR, 0.001 ether);
        _mintOne(official);
    }

    function _collection(address who, uint128 price) internal returns (PlaceNftCollection c) {
        PlaceNftCollection.InitParams memory p;
        p.name = "Club";
        p.symbol = "CLUB";
        p.kind = PlaceNftCollection.Kind.Edition;
        p.baseURI = "ipfs://one";
        p.mintPrice = price;
        p.token = token;
        p.economy = PlaceNftCollection.Economy({creatorBps: 10_000, holdersBps: 0, burnBps: 0});
        uint256 fee = nftFactory.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        c = PlaceNftCollection(payable(nftFactory.createCollection{value: fee}(p)));
    }

    function _mintOne(PlaceNftCollection c) internal {
        uint256 cost = c.mintPrice();
        vm.deal(ALICE, ALICE.balance + cost);
        vm.prank(ALICE);
        c.mint{value: cost}(ALICE, 1);
    }

    function _nft(address collection, uint256 amountIn)
        internal
        view
        returns (PlaceCommunityVault.NftCampaignRequest memory r)
    {
        r.collection = collection;
        r.fundAsset = address(0);
        r.amountIn = amountIn;
        r.rewardToken = address(0);
        r.startEpoch = uint64(block.timestamp / 1 days) + 1;
        r.epochCount = 5;
        r.minNfts = 1;
        r.metadataURI = "ipfs://nft-campaign";
    }

    // ───────────────────────────── NFT campaigns ─────────────────────────────

    function test_nftCampaign_streamOnCollection() public {
        vm.prank(CREATOR);
        bytes32 id = vault.fundNftCampaign(_nft(address(official), 0.005 ether));
        PlaceRewardsDistributor.Stream memory s = distributor.stream(id);
        assertEq(s.token, address(official), "stream target is the collection");
        assertEq(uint8(s.kind), uint8(IPlaceRewardsDistributor.Kind.Holders));
        assertEq(s.criterion, 1);
        assertEq(s.funder, address(vault));
        assertEq(s.epochCount, 5);
        assertLe(address(vault).balance, 0.021 ether - 0.0049 ether);
    }

    function test_nftCampaign_guards() public {
        vm.expectRevert(PlaceCommunityVault.NotCreator.selector);
        vault.fundNftCampaign(_nft(address(official), 0.001 ether));

        // Not from the Place NFT factory.
        vm.expectRevert(PlaceCommunityVault.InvalidCollection.selector);
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(usd), 0.001 ether));

        // Made by someone else: no official badge.
        PlaceNftCollection stranger = _collection(ALICE, 0.001 ether);
        _mintOne(stranger);
        vm.expectRevert(PlaceCommunityVault.InvalidCollection.selector);
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(stranger), 0.001 ether));

        // Free mint: the creator could mint everything to own wallets.
        PlaceNftCollection free = _collection(CREATOR, 0);
        _mintOne(free);
        vm.expectRevert(PlaceCommunityVault.InvalidCollection.selector);
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(free), 0.001 ether));

        // Nothing minted yet.
        PlaceNftCollection empty = _collection(CREATOR, 0.001 ether);
        vm.expectRevert(PlaceCommunityVault.InvalidCollection.selector);
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(empty), 0.001 ether));

        // At most 25% of the fund.
        vm.expectRevert(
            abi.encodeWithSelector(PlaceCommunityVault.NftCampaignTooLarge.selector, 0.006 ether, 0.00525 ether)
        );
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(official), 0.006 ether));
    }

    function test_nftCampaign_cooldown() public {
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(official), 0.002 ether));
        uint64 nextAt = uint64(block.timestamp) + 30 days;
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.NftCampaignTooSoon.selector, nextAt));
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(official), 0.001 ether));
        vm.warp(nextAt);
        vm.prank(CREATOR);
        vault.fundNftCampaign(_nft(address(official), 0.001 ether));
    }

    // ───────────────────────────── buyback ─────────────────────────────

    function _buyback(address asset, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (PlaceCommunityVault.BuybackRequest memory r)
    {
        r.fundAsset = asset;
        r.amountIn = amountIn;
        r.minOut = minOut;
    }

    function test_buyback_fromQuoteBurns() public {
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(CREATOR);
        uint256 burned = vault.buybackAndBurn(_buyback(address(0), 0.01 ether, 0));
        assertGt(burned, 0);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, burned);
        assertEq(vault.totalBurned(), burned);
        assertEq(IERC20(token).balanceOf(address(vault)), 0, "nothing kept");
        assertEq(address(vault).balance, 0.011 ether);
    }

    function test_buyback_heldTokensBurnAsIs() public {
        vm.prank(TRADER);
        IERC20(token).transfer(address(vault), 1_000e18); // donation
        vm.prank(CREATOR);
        assertEq(vault.buybackAndBurn(_buyback(token, 1_000e18, 0)), 1_000e18);
        assertEq(vault.totalBurned(), 1_000e18);
    }

    function test_buyback_guards() public {
        vm.expectRevert(PlaceCommunityVault.NotCreator.selector);
        vault.buybackAndBurn(_buyback(address(0), 0.01 ether, 0));

        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.FundTooSmall.selector, 0.021 ether, 1 ether));
        vm.prank(CREATOR);
        vault.buybackAndBurn(_buyback(address(0), 1 ether, 0));

        // The creator's own floor.
        vm.expectPartialRevert(PlaceCommunityVault.SlippageExceeded.selector);
        vm.prank(CREATOR);
        vault.buybackAndBurn(_buyback(address(0), 0.01 ether, type(uint256).max));

        // No route from USD to the token.
        usd.mint(address(vault), 10e18);
        vm.expectRevert(abi.encodeWithSelector(PlaceCommunityVault.RouteNotListed.selector, address(usd), token));
        vm.prank(CREATOR);
        vault.buybackAndBurn(_buyback(address(usd), 10e18, 0));
    }

    function test_buyback_sandwichReverts() public {
        _swap(ATTACKER, key, token, true, 0.3 ether); // front-run pump
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        vm.prank(CREATOR);
        vault.buybackAndBurn(_buyback(address(0), 0.01 ether, 0));
        assertEq(vault.totalBurned(), 0, "nothing spent");
    }
}
