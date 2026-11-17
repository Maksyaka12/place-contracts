// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceNftCollection} from "../../src/nft/PlaceNftCollection.sol";
import {PlaceNftFactory} from "../../src/nft/PlaceNftFactory.sol";
import {PlacePriceGuard} from "../../src/nft/PlacePriceGuard.sol";

contract OwnedToken {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// @dev Minimal WETH: royalties paid in WETH are unwrapped by the collection.
contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

contract NftCollectionTest is LaunchFixture {
    using PoolIdLibrary for PoolKey;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint128 internal constant PRICE = 0.001 ether;

    address internal token;
    PoolKey internal key;
    PoolKey[] internal route;
    PlaceNftCollection internal c;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        (token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        key = _poolKey(token, address(0));
        route.push(key);
        vm.warp(vm.getBlockTimestamp() + 21); // after the anti-snipe window
        _swap(TRADER, key, token, true, 0.01 ether);
        _swap(ALICE, key, token, true, 0.01 ether);
        _warmGuard(route);
        c = _create(CREATOR, _p());
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _p() internal view returns (PlaceNftCollection.InitParams memory p) {
        p.name = "Place Club";
        p.symbol = "CLUB";
        p.kind = PlaceNftCollection.Kind.Unique;
        p.baseURI = "ipfs://folder/";
        p.uriSuffix = ".json";
        p.contractURI = "ipfs://collection";
        p.maxSupply = 100;
        p.maxPerWallet = 5;
        p.mintPrice = PRICE;
        p.token = token;
        p.tokenPayments = true;
        p.royaltyBps = 500;
        p.economy = PlaceNftCollection.Economy({creatorBps: 5_000, holdersBps: 3_000, burnBps: 2_000});
        p.launchPool = key;
    }

    function _create(address who, PlaceNftCollection.InitParams memory p) internal returns (PlaceNftCollection) {
        uint256 fee = nftFactory.creationFee();
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        return PlaceNftCollection(payable(nftFactory.createCollection{value: fee}(p)));
    }

    function _mint(address who, uint256 qty) internal returns (uint256 first) {
        uint256 cost = uint256(c.mintPrice()) * qty;
        vm.deal(who, who.balance + cost);
        vm.prank(who);
        first = c.mint{value: cost}(who, qty);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _assertSolvent() internal view {
        assertGe(address(c).balance, c.reserved(address(0)), "ETH solvent");
        assertGe(IERC20(token).balanceOf(address(c)), c.reserved(token), "token solvent");
    }

    function _next() internal {
        vm.warp(vm.getBlockTimestamp() + GUARD_INTERVAL);
        vm.roll(vm.getBlockNumber() + 1);
    }

    // ───────────────────────────── factory ─────────────────────────────

    function test_create_officialFlagAndFee() public {
        uint256 platformBefore = PLATFORM.balance;
        assertTrue(c.official(), "token creator");
        assertEq(c.owner(), CREATOR);
        assertTrue(nftFactory.isCollection(address(c)));
        assertEq(nftFactory.collectionsOf(token)[0], address(c));
        PlaceNftCollection other = _create(BOB, _p());
        assertFalse(other.official(), "anyone else: no badge");
        assertEq(nftFactory.collectionsOf(token).length, 2);
        assertEq(PLATFORM.balance - platformBefore, nftFactory.creationFee(), "creation fee to the platform");

        // External token: owner() decides.
        PlaceNftCollection.InitParams memory p = _p();
        p.token = address(new OwnedToken(BOB));
        p.launchPool.tickSpacing = 0;
        p.tokenPayments = false;
        assertTrue(_create(BOB, p).official());
        assertFalse(_create(ALICE, p).official());
    }

    function test_create_rejectsWrongPoolFeeAndEconomy() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.launchPool = ethUsd;
        vm.deal(CREATOR, 1 ether);
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftFactory.InvalidLaunchPool.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(PlaceNftFactory.WrongFee.selector, 0, 0.0005 ether));
        nftFactory.createCollection(_p());

        p = _p();
        p.economy.burnBps = 1_000; // sum 9 000
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        p = _p();
        p.royaltyBps = 1_001;
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        p = _p();
        p.token = address(0);
        p.launchPool.tickSpacing = 0;
        p.tokenPayments = false; // burn share without a token
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);
    }

    // ───────────────────────────── ETH economy ─────────────────────────────

    function test_mintEth_splitsTwentyPercentPlatformAndCreatorShares() public {
        _mint(ALICE, 2); // 0.002 ETH
        assertEq(c.platformOwed(address(0)), 0.0004 ether, "20%");
        assertEq(c.creatorOwed(address(0)), 0.0008 ether, "50% of 80%");
        assertEq(c.buybackPending(), 0.00032 ether, "20% of 80%");
        (uint256 e1,) = c.claimable(1);
        (uint256 e2,) = c.claimable(2);
        assertEq(e1 + e2, 0.00048 ether, "30% of 80% to holders");
        assertEq(address(c).balance, 0.002 ether);
        assertEq(c.reserved(address(0)), 0.002 ether);

        uint256 platformBefore = PLATFORM.balance;
        c.payPlatform(address(0));
        c.payCreator(address(0));
        assertEq(PLATFORM.balance - platformBefore, 0.0004 ether);
        assertEq(CREATOR.balance, 0.0008 ether);
        vm.expectRevert(PlaceNftCollection.NothingToDo.selector);
        c.payCreator(address(0));
        _assertSolvent();
    }

    function test_holders_accumulatorPerNft() public {
        _mint(ALICE, 1); // holders: 0.00024 ETH to NFT 1 (the only one)
        _mint(BOB, 1); // 0.00024 ETH split between NFTs 1 and 2
        (uint256 a,) = c.claimable(1);
        (uint256 b,) = c.claimable(2);
        assertEq(a, 0.00024 ether + 0.00012 ether);
        assertEq(b, 0.00012 ether, "NFT 2 earns only from its own mint on");

        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        (uint256 paid,) = c.claim(_ids(1));
        assertEq(paid, a);
        assertEq(ALICE.balance - before, a);
        (a,) = c.claimable(1);
        assertEq(a, 0);

        vm.expectRevert(abi.encodeWithSelector(PlaceNftCollection.NotTokenOwner.selector, 2));
        vm.prank(ALICE);
        c.claim(_ids(2));

        // Unclaimed rewards travel with the NFT.
        vm.prank(BOB);
        c.transferFrom(BOB, ALICE, 2);
        vm.prank(ALICE);
        (paid,) = c.claim(_ids(2));
        assertEq(paid, 0.00012 ether);
        _assertSolvent();
    }

    function test_mint_limitsAndWindow() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PlaceNftCollection.WrongPayment.selector, 0, PRICE));
        c.mint(ALICE, 1);
        _mint(ALICE, 5);
        vm.expectRevert(PlaceNftCollection.WalletLimit.selector);
        vm.prank(ALICE);
        c.mint{value: PRICE}(ALICE, 1);

        vm.prank(CREATOR);
        c.setMintWindow(uint64(block.timestamp + 1 days), 0);
        vm.deal(BOB, 1 ether);
        vm.expectRevert(PlaceNftCollection.MintClosed.selector);
        vm.prank(BOB);
        c.mint{value: PRICE}(BOB, 1);
        vm.warp(block.timestamp + 1 days);
        _mint(BOB, 1);

        PlaceNftCollection.InitParams memory p = _p();
        p.maxSupply = 3;
        p.maxPerWallet = 0;
        c = _create(CREATOR, p);
        _mint(BOB, 3);
        vm.deal(BOB, 1 ether);
        vm.expectRevert(PlaceNftCollection.SoldOut.selector);
        vm.prank(BOB);
        c.mint{value: PRICE}(BOB, 1);
    }

    function test_freeMint_noEconomy() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.mintPrice = 0;
        p.tokenPayments = false;
        c = _create(CREATOR, p);
        _mint(ALICE, 2);
        assertEq(c.totalSupply(), 2);
        assertEq(c.reserved(address(0)), 0);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        vm.prank(CREATOR);
        c.setTokenPayments(true);
    }

    // ───────────────────────────── metadata ─────────────────────────────

    function test_metadata_uniqueEditionAndFreeze() public {
        _mint(ALICE, 2);
        assertEq(c.tokenURI(2), "ipfs://folder/2.json");
        assertEq(c.contractURI(), "ipfs://collection");
        assertEq(c.name(), "Place Club");
        assertEq(c.symbol(), "CLUB");
        vm.prank(CREATOR);
        c.setBaseURI("ipfs://new/", "");
        assertEq(c.tokenURI(1), "ipfs://new/1");
        vm.prank(CREATOR);
        c.freezeMetadata();
        vm.expectRevert(PlaceNftCollection.Frozen.selector);
        vm.prank(CREATOR);
        c.setBaseURI("ipfs://x/", "");
        vm.expectRevert();
        vm.prank(ALICE);
        c.setContractURI("x");

        PlaceNftCollection.InitParams memory p = _p();
        p.kind = PlaceNftCollection.Kind.Edition;
        p.maxSupply = 0; // open edition
        p.baseURI = "ipfs://one.json";
        c = _create(CREATOR, p);
        _mint(BOB, 3);
        assertEq(c.tokenURI(3), "ipfs://one.json");
        assertTrue(c.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(c.supportsInterface(0x80ac58cd)); // ERC-721
    }

    // ───────────────────────────── royalties ─────────────────────────────

    function test_royalties_ethTokenAndOtherAssets() public {
        _mint(ALICE, 2);
        (address receiver, uint256 amount) = c.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(c));
        assertEq(amount, 0.05 ether);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 0.05 ether}("");
        assertTrue(ok);
        uint256 creatorBefore = c.creatorOwed(address(0));
        assertEq(c.distributeRoyalties(address(0)), 0.05 ether);
        assertEq(c.creatorOwed(address(0)) - creatorBefore, 0.02 ether, "50% of 80%");
        (uint256 e1,) = c.claimable(1);
        assertEq(e1, 0.00024 ether + 0.006 ether, "30% of 80% over 2 NFTs");
        vm.expectRevert(PlaceNftCollection.NothingToDo.selector);
        c.distributeRoyalties(address(0));

        // Royalty in the linked token: the burn share is burned at once.
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(TRADER);
        IERC20(token).transfer(address(c), 1_000e18);
        c.distributeRoyalties(token);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, 160e18, "20% of 80%");
        (, uint256 t1) = c.claimable(1);
        assertEq(t1, 120e18);
        assertEq(c.totalBurned(token), 160e18);

        // Any other ERC-20: 20% platform, 80% creator.
        usd.mint(address(c), 100e18);
        c.distributeRoyalties(address(usd));
        assertEq(usd.balanceOf(PLATFORM), 20e18);
        assertEq(usd.balanceOf(CREATOR), 80e18);
        _assertSolvent();
    }

    function test_royalties_wethIsUnwrapped() public {
        MockWETH weth = new MockWETH();
        nftFactory.setWeth(address(weth));
        _mint(ALICE, 1);
        weth.deposit{value: 0.01 ether}();
        weth.transfer(address(c), 0.01 ether);
        uint256 creatorBefore = c.creatorOwed(address(0));
        assertEq(c.distributeRoyalties(address(weth)), 0.01 ether);
        assertEq(weth.balanceOf(address(c)), 0);
        assertEq(c.creatorOwed(address(0)) - creatorBefore, 0.004 ether);
        assertEq(c.buybackPending(), 0.00016 ether + 0.0016 ether);
        _assertSolvent();
    }

    function test_royalties_settable_capped() public {
        vm.prank(CREATOR);
        c.setRoyaltyBps(1_000);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        vm.prank(CREATOR);
        c.setRoyaltyBps(1_001);
    }

    // ───────────────────────────── token payments ─────────────────────────────

    function test_mintWithToken_marketPriceAndBurn() public {
        uint256 due = c.quoteTokenPrice(1);
        (uint256 refOut, uint256 spotOut) = guard.quote(route, address(0), PRICE);
        assertEq(due, refOut > spotOut ? refOut : spotOut);
        assertGt(due, 0);

        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.startPrank(ALICE);
        IERC20(token).approve(address(c), due);
        vm.expectRevert(abi.encodeWithSelector(PlaceNftCollection.TokenAmountAboveMax.selector, due, due - 1));
        c.mintWithToken(ALICE, 1, due - 1);
        (uint256 id, uint256 paid) = c.mintWithToken(ALICE, 1, due);
        vm.stopPrank();
        assertEq(id, 1);
        assertEq(paid, due);
        uint256 platform = due * 2_000 / 10_000;
        uint256 rest = due - platform;
        assertEq(c.platformOwed(token), platform);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, rest * 2_000 / 10_000, "token burn share burned");
        (, uint256 t1) = c.claimable(1);
        assertEq(t1, rest * 3_000 / 10_000);
        _assertSolvent();
    }

    function test_mintWithToken_disabled() public {
        vm.prank(CREATOR);
        c.setTokenPayments(false);
        vm.expectRevert(PlaceNftCollection.TokenPaymentsDisabled.selector);
        c.mintWithToken(ALICE, 1, type(uint256).max);
    }

    /// @notice A flash pump in the same block (the token gets more expensive, so fewer tokens per ETH) does not
    ///         lower what the buyer pays: the guard's reference from an earlier block sets the floor.
    function test_manipulation_smallPumpCannotLowerTokenPrice() public {
        uint256 dueBefore = c.quoteTokenPrice(1);
        _swap(ATTACKER, key, token, true, 0.0002 ether); // pump in the same block
        (uint256 refOut, uint256 spotOut) = guard.quote(route, address(0), PRICE);
        assertLt(spotOut, refOut, "spot says fewer tokens");
        assertEq(c.quoteTokenPrice(1), dueBefore, "buyer still pays the reference amount");
    }

    function test_manipulation_bigPumpRefusesTokenMints() public {
        _swap(ATTACKER, key, token, true, 0.05 ether);
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        c.quoteTokenPrice(1);
        vm.startPrank(ALICE);
        IERC20(token).approve(address(c), type(uint256).max);
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        c.mintWithToken(ALICE, 1, type(uint256).max);
        vm.stopPrank();
        _mint(ALICE, 1); // ETH mints keep working
    }

    /// @notice An observation written in the current block is ignored by quotes in that block.
    function test_manipulation_pumpThenObserveSameBlockIgnored() public {
        (uint256 refBefore,) = guard.quote(route, address(0), PRICE);
        _next();
        _swap(ATTACKER, key, token, true, 0.05 ether);
        guard.observeRoute(route);
        PlacePriceGuard.Observation memory o = guard.observation(key.toId());
        assertEq(o.updatedBlock, block.number);
        _swap(ATTACKER, key, token, false, IERC20(token).balanceOf(ATTACKER)); // dump back
        (uint256 refNow,) = guard.quote(route, address(0), PRICE);
        assertEq(refNow, refBefore, "previous reference used in this block");
    }

    /// @notice A pump that holds across blocks moves the reference by at most 1% per observation interval.
    function test_manipulation_referenceMovesAtMostOneStep() public {
        uint160 ref0 = guard.observation(key.toId()).refPrice;
        _swap(ATTACKER, key, token, true, 0.05 ether);
        _next();
        guard.observeRoute(route);
        uint160 ref1 = guard.observation(key.toId()).refPrice;
        assertLe(guard.deviationBps(ref0, ref1), GUARD_STEP + 1);
        assertGt(ref1 != ref0 ? 1 : 0, 0);
        // A second observation inside the interval is a no-op.
        vm.roll(block.number + 1);
        guard.observeRoute(route);
        assertEq(guard.observation(key.toId()).refPrice, ref1);
        // It still takes many intervals before quotes accept the pumped price.
        _next();
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        guard.quote(route, address(0), PRICE);
    }

    function test_guard_notReadyAndBounds() public {
        PoolKey[] memory other = new PoolKey[](1);
        other[0] = ethUsd;
        vm.expectRevert(abi.encodeWithSelector(PlacePriceGuard.PriceNotReady.selector, ethUsd.toId(), 0));
        guard.quote(other, address(0), 1 ether);
        guard.observeRoute(other);
        vm.expectPartialRevert(PlacePriceGuard.PriceNotReady.selector);
        guard.quote(other, address(0), 1 ether);
        vm.warp(block.timestamp + GUARD_WARMUP);
        vm.roll(block.number + 1);
        (uint256 refOut, uint256 spotOut) = guard.quote(other, address(0), 1 ether);
        assertApproxEqRel(refOut, 2_000e18, 0.01e18, "1 ETH ~ 2000 USD");
        assertEq(refOut, spotOut);

        vm.expectRevert(PlacePriceGuard.InvalidConfig.selector);
        guard.setConfig(PlacePriceGuard.Config({minInterval: 5, warmup: 60, maxStepBps: 100, maxDeviationBps: 300}));
        vm.expectRevert(PlacePriceGuard.InvalidConfig.selector);
        guard.setConfig(PlacePriceGuard.Config({minInterval: 60, warmup: 60, maxStepBps: 5_000, maxDeviationBps: 300}));
        vm.expectRevert();
        vm.prank(ATTACKER);
        guard.setConfig(PlacePriceGuard.Config({minInterval: 60, warmup: 60, maxStepBps: 100, maxDeviationBps: 300}));
    }

    // ───────────────────────────── buyback ─────────────────────────────

    function test_buyback_anyoneBuysAndBurns() public {
        _mint(ALICE, 5); // buyback pending 0.0008 ETH
        uint256 pending = c.buybackPending();
        assertEq(pending, 0.0008 ether);
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(BOB);
        uint256 burned = c.buyback(type(uint256).max);
        assertGt(burned, 0);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, burned);
        assertEq(c.totalBurned(token), burned);
        assertEq(c.buybackPending(), 0);
        vm.expectRevert(PlaceNftCollection.NothingToDo.selector);
        c.buyback(1);
        _assertSolvent();
    }

    function test_buyback_sandwichReverts() public {
        _mint(ALICE, 5);
        _swap(ATTACKER, key, token, true, 0.05 ether); // front-run pump
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        c.buyback(type(uint256).max);
        assertEq(c.buybackPending(), 0.0008 ether, "nothing spent");
    }

    /// @notice A front-run inside the guard's deviation band costs the buyback at most deviation + impact.
    function test_buyback_smallSandwichLossBounded() public {
        _mint(ALICE, 5);
        (uint256 refOut,) = guard.quote(route, address(0), 0.0008 ether);
        _swap(ATTACKER, key, token, true, 0.0002 ether); // small pump, inside the 3% band
        uint256 burned = c.buyback(type(uint256).max);
        assertGe(burned, refOut * (10_000 - GUARD_DEVIATION - MAX_IMPACT) / 10_000);
    }

    function test_buyback_partialAmounts() public {
        _mint(ALICE, 5);
        c.buyback(0.0003 ether);
        assertEq(c.buybackPending(), 0.0005 ether);
        _assertSolvent();
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    /// @notice Every split adds up to the payment and the contract stays solvent after any mints and claims.
    function testFuzz_splitConservesAndSolvent(uint16 creatorBps, uint16 holdersBps, uint8 a, uint8 b) public {
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        holdersBps = uint16(bound(holdersBps, 0, 10_000 - creatorBps));
        uint256 qa = bound(a, 1, 5);
        uint256 qb = bound(b, 1, 5);
        PlaceNftCollection.InitParams memory p = _p();
        p.economy = PlaceNftCollection.Economy({
            creatorBps: creatorBps, holdersBps: holdersBps, burnBps: 10_000 - creatorBps - holdersBps
        });
        c = _create(CREATOR, p);
        _mint(ALICE, qa);
        _mint(BOB, qb);
        uint256 total = PRICE * (qa + qb);
        assertEq(address(c).balance, total);
        assertEq(c.reserved(address(0)), total, "everything is owed to someone");
        uint256[] memory ids = new uint256[](qa);
        for (uint256 i = 0; i < qa; i++) {
            ids[i] = i + 1;
        }
        vm.prank(ALICE);
        c.claim(ids);
        c.payPlatform(address(0));
        if (c.creatorOwed(address(0)) != 0) c.payCreator(address(0));
        _assertSolvent();
    }
}
