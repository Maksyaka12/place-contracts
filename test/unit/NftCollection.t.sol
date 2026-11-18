// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceNftCollection} from "../../src/nft/PlaceNftCollection.sol";
import {PlaceNftFactory} from "../../src/nft/PlaceNftFactory.sol";
import {PlaceNftSwapper} from "../../src/nft/PlaceNftSwapper.sol";
import {PlacePriceGuard} from "../../src/nft/PlacePriceGuard.sol";

/// @dev An external (non-Place) token whose `owner()` is its creator.
contract OwnedToken is MockERC20 {
    address public owner;

    constructor(address o) MockERC20("Owned", "OWN", 18) {
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
    address internal constant CAROL = address(0xCA201);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ETH = address(0);
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
        PoolKey[] memory both = new PoolKey[](2);
        both[0] = key;
        both[1] = ethUsd;
        _warmGuard(both);
        c = _create(CREATOR, _p());
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Place token pair, holders paid in ETH, 50 / 30 / 20.
    function _p() internal view returns (PlaceNftCollection.InitParams memory p) {
        p.name = "Place Club";
        p.symbol = "CLUB";
        p.kind = PlaceNftCollection.Kind.Unique;
        p.baseURI = "ipfs://folder/";
        p.uriSuffix = ".json";
        p.contractURI = "ipfs://collection";
        p.maxSupply = 100;
        p.maxPerWallet = 0;
        p.mintPrice = PRICE;
        p.token = token;
        p.tokenPayments = true;
        p.rewardToken = ETH;
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

    function _mintToken(address who, uint256 qty) internal returns (uint256 paid) {
        address pair = c.token();
        uint256 due = c.quoteTokenPrice(qty);
        vm.startPrank(who);
        IERC20(pair).approve(address(c), due);
        (, paid) = c.mintWithToken(who, qty, due);
        vm.stopPrank();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _reward(uint256 id) internal view returns (uint256) {
        return c.claimable(id);
    }

    /// @dev Moves `n` whole UTC days ahead (same time of day).
    function _days(uint256 n) internal {
        vm.warp(vm.getBlockTimestamp() + n * 1 days);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Moves to `secondsIntoDay` of the next UTC day.
    function _toNextDayAt(uint256 secondsIntoDay) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + secondsIntoDay);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev The holders share of a payment of `amount` in the default 50 / 30 / 20 economy.
    function _holdersShare(uint256 amount) internal pure returns (uint256) {
        return (amount - amount * 2_000 / 10_000) * 3_000 / 10_000;
    }

    function _assertSolvent() internal view {
        assertGe(address(c).balance, c.reserved(ETH), "ETH solvent");
        assertGe(IERC20(token).balanceOf(address(c)), c.reserved(token), "token solvent");
        assertGe(usd.balanceOf(address(c)), c.reserved(address(usd)), "usd solvent");
    }

    function _next() internal {
        vm.warp(vm.getBlockTimestamp() + GUARD_INTERVAL);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev An external token with an ETH pool (no hook, 1 ETH ~ 2000 tokens) and a registry route.
    function _externalPair(address tokenOwner) internal returns (OwnedToken t, PoolKey memory k) {
        t = new OwnedToken(tokenOwner);
        k = PoolKey(Currency.wrap(ETH), Currency.wrap(address(t)), 3000, 60, IHooks(address(0)));
        pm.initialize(k, TickMath.getSqrtPriceAtTick(76_020));
        t.mint(address(this), 1_000_000e18);
        t.approve(address(lp), type(uint256).max);
        vm.deal(address(this), address(this).balance + 20 ether);
        lp.modifyLiquidity{value: 20 ether}(k, IPoolManager.ModifyLiquidityParams(-887_220, 887_220, 1e20, 0), "");
        PoolKey[] memory r = new PoolKey[](1);
        r[0] = k;
        rewards.setRoute(ETH, address(t), r);
    }

    // ───────────────────────────── factory ─────────────────────────────

    function test_create_officialFlagFeeAndSwapper() public {
        uint256 platformBefore = PLATFORM.balance;
        assertTrue(c.official(), "token creator");
        assertEq(c.owner(), CREATOR);
        assertEq(c.rewardToken(), ETH);
        assertTrue(nftFactory.isCollection(address(c)));
        assertEq(nftFactory.collectionsOf(token)[0], address(c));
        assertEq(address(PlaceNftSwapper(payable(nftFactory.swapper())).factory()), address(nftFactory));
        PlaceNftCollection other = _create(BOB, _p());
        assertFalse(other.official(), "anyone else: no badge");
        assertEq(PLATFORM.balance - platformBefore, nftFactory.creationFee(), "creation fee to the platform");

        // External token with a registry route: owner() decides.
        (OwnedToken ext,) = _externalPair(BOB);
        PlaceNftCollection.InitParams memory p = _p();
        p.token = address(ext);
        p.launchPool.tickSpacing = 0;
        assertTrue(_create(BOB, p).official());
        assertFalse(_create(ALICE, p).official());
    }

    function test_create_requiresRoutes() public {
        vm.deal(CREATOR, 1 ether);
        // A token without a Place pool or a registry route.
        PlaceNftCollection.InitParams memory p = _p();
        p.token = address(new OwnedToken(CREATOR));
        p.launchPool.tickSpacing = 0;
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftSwapper.NoRoute.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        // A Place token without its launch pool (no registry route either).
        p = _p();
        p.launchPool.tickSpacing = 0;
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftSwapper.NoRoute.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        // Reward token without a route from ETH.
        p = _p();
        p.rewardToken = address(new OwnedToken(CREATOR));
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftFactory.InvalidRewardToken.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        // Paid mint without a pair token.
        p = _p();
        p.token = ETH;
        p.launchPool.tickSpacing = 0;
        p.tokenPayments = false;
        p.economy = PlaceNftCollection.Economy({creatorBps: 7_000, holdersBps: 3_000, burnBps: 0});
        vm.prank(CREATOR);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        nftFactory.createCollection{value: 0.0005 ether}(p);

        // Free collection without a pair: fine (royalties only, holders in ETH).
        p.mintPrice = 0;
        PlaceNftCollection free = _create(CREATOR, p);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        vm.prank(CREATOR);
        free.setMint(1, 0, 0, false);
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
    }

    // ───────────────────────────── ETH economy ─────────────────────────────

    /// @notice The first mint funds the holders pool (its own NFTs are the holders): the minter gets nothing on the
    ///         mint day and its share from the next 00:00 UTC; the burn share buys and burns the pair token at once.
    function test_firstMint_fundsPool_minterEarnsFromNextDay() public {
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        _mint(ALICE, 2); // 0.002 ETH
        uint64 today = uint64(vm.getBlockTimestamp() / 1 days);
        assertEq(c.platformOwed(ETH), 0.0004 ether, "20%");
        assertEq(c.creatorOwed(ETH), 0.0008 ether, "50% of 80%, nothing more");
        assertEq(c.rewardRate(), uint256(0.00048 ether) * 1e36 / 30, "30% of 80% into the pool");
        assertEq(c.periodFinish(), today + 30);
        assertEq(c.buybackPending(), 0, "burn share swapped in the mint");
        assertGt(c.totalBurned(), 0);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, c.totalBurned());
        assertEq(_reward(1) + _reward(2), 0, "nothing on the mint day");
        assertEq(c.reserved(ETH), 0.00168 ether);
        assertEq(address(c).balance, 0.00168 ether);

        _days(1);
        assertEq(_reward(1), 0.00048 ether / 30 / 2, "first portion at the next 00:00 UTC");
        assertEq(_reward(2), 0.00048 ether / 30 / 2);
        _days(30);
        assertEq(_reward(1) + _reward(2), 0.00048 ether, "the minter gets the whole holders share back");
        uint256 aliceBefore = ALICE.balance;
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
        vm.prank(ALICE);
        c.claim(ids);
        assertEq(ALICE.balance - aliceBefore, 0.00048 ether);

        uint256 platformBefore = PLATFORM.balance;
        c.payOut(ETH);
        assertEq(PLATFORM.balance - platformBefore, 0.0004 ether);
        assertEq(CREATOR.balance, 0.0008 ether);
        vm.expectRevert(PlaceNftCollection.NothingToDo.selector);
        c.payOut(ETH);
        assertEq(c.reserved(ETH), 0, "nothing stranded");
        _assertSolvent();
    }

    /// @notice A first mint of several NFTs spreads its holders share over all of them, equally per NFT.
    function test_firstMint_manyNftsShareThePool() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 4); // 4 x 0.00024 ETH into the pool, 4 NFTs from tomorrow
        assertEq(c.rewardRate(), uint256(0.00096 ether) * 1e36 / 30);
        _days(1);
        for (uint256 id = 1; id <= 4; id++) {
            assertEq(_reward(id), 0.00096 ether / 30 / 4, "equal per NFT");
        }
        vm.prank(ALICE);
        c.transferFrom(ALICE, BOB, 4); // the day accrued stays with ALICE
        _days(30);
        for (uint256 id = 1; id <= 3; id++) {
            assertEq(_reward(id), 0.00024 ether);
        }
        assertEq(_reward(4), 0.00024 ether - 0.00096 ether / 30 / 4, "BOB from the transfer on");
        assertEq(c.credit(ALICE), 0.00096 ether / 30 / 4);
        _assertSolvent();
    }

    /// @notice The holders share goes to a pool paid over 30 days: nothing on the mint day, 1/30 per UTC day
    ///         to every NFT that exists at 00:00, and nothing more after the 30th day.
    function test_pool_paysOverThirtyDays() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 1); // 0.00024 ETH into the pool: the first mint's NFT is its holder
        uint64 today = uint64(vm.getBlockTimestamp() / 1 days);
        assertEq(c.periodFinish(), today + 30);
        assertEq(c.rewardRate(), uint256(0.00024 ether) * 1e36 / 30);
        _mint(BOB, 1); // + 0.00024 ETH the same day; BOB's NFT also earns from tomorrow
        assertEq(c.periodFinish(), today + 30);
        assertEq(c.rewardRate(), uint256(0.00048 ether) * 1e36 / 30);
        assertEq(_reward(1), 0, "nothing accrues on the income day");
        _days(1);
        assertEq(_reward(1), 0.00048 ether / 30 / 2);
        assertEq(_reward(2), 0.00048 ether / 30 / 2);
        _days(29);
        assertApproxEqAbs(_reward(1), 0.00024 ether, 1);
        _days(10);
        assertApproxEqAbs(_reward(1), 0.00024 ether, 1, "the pool ended after 30 days");
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        uint256 paid = c.claim(_ids(1));
        assertEq(ALICE.balance - before, paid);
        assertEq(_reward(1), 0);
        _assertSolvent();
    }

    /// @notice A second income after one day re-spreads what is left plus the new income over 30 new days.
    function test_pool_secondIncomeAfterOneDay() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 1);
        _mint(BOB, 1); // X = 0.00048 (both mints) over 2 NFTs
        _days(1); // day 1: X/30 accrued
        _mint(CAROL, 1); // Y = 0.00024, pool = 29X/30 + Y over 30 days, 3 NFTs from now
        uint64 today = uint64(vm.getBlockTimestamp() / 1 days);
        assertEq(c.periodFinish(), today + 30);
        uint256 x = 0.00048 ether;
        uint256 y = 0.00024 ether;
        assertApproxEqAbs(c.rewardRate(), (x * 29 / 30 + y) * 1e36 / 30, 1e36);
        uint256 firstDay = x / 30 / 2;
        assertEq(_reward(1), firstDay);
        assertEq(_reward(3), 0, "CAROL gets nothing from the day already accrued");
        _days(30);
        uint256 rest = (x * 29 / 30 + y) / 3;
        assertApproxEqAbs(_reward(1), firstDay + rest, 3);
        assertApproxEqAbs(_reward(3), rest, 3, "but shares the running pool equally");
        assertApproxEqAbs(_reward(1) + _reward(2) + _reward(3), x + y, 10, "every income is paid in full");
        _assertSolvent();
    }

    /// @notice A second income after 30 days finds the pool finished and starts a new one of its own.
    function test_pool_secondIncomeAfterThirtyDays() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 1);
        _mint(BOB, 1); // X (both mints) over 2 NFTs
        _days(30);
        uint256 x = 0.00048 ether;
        uint256 y = 0.00024 ether;
        assertApproxEqAbs(_reward(1), x / 2, 1);
        _mint(CAROL, 1); // Y alone over the next 30 days, 3 NFTs
        assertEq(c.rewardRate(), y * 1e36 / 30);
        _days(30);
        assertApproxEqAbs(_reward(1), x / 2 + y / 3, 2);
        assertApproxEqAbs(_reward(3), y / 3, 2);
        _assertSolvent();
    }

    /// @notice 5 -> 10 -> 50 NFTs: equal per NFT at each daily accrual; the newest NFTs miss the days before them.
    function test_pool_perNftAsTheCollectionGrows() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 5); // 0.0012 into the pool
        _mint(BOB, 5); // + 0.0012 the same day: X = 0.0024
        _days(10); // 10 days of X/30 over 10 NFTs
        _mint(CAROL, 40); // Y = 0.0096, 50 NFTs from tomorrow
        uint256 x = 0.0024 ether;
        uint256 tenDays = x / 30 * 10 / 10;
        assertApproxEqAbs(_reward(1), tenDays, 1);
        assertApproxEqAbs(_reward(6), tenDays, 1, "BOB shares the pool from the first accrual after his mint");
        assertEq(_reward(11), 0);
        _days(30);
        uint256 rest = (x * 20 / 30 + 0.0096 ether) / 50;
        assertApproxEqAbs(_reward(1), tenDays + rest, 50);
        assertApproxEqAbs(_reward(50), rest, 50);
        _assertSolvent();
    }

    /// @notice A transfer mid-stream: the days accrued so far stay with the seller, later days go to the buyer.
    function test_pool_transferMidStream() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 1);
        _mint(BOB, 1);
        uint256 perDay = 0.00048 ether / 30 / 2;
        _days(5);
        vm.prank(ALICE);
        c.transferFrom(ALICE, CAROL, 1);
        assertEq(c.credit(ALICE), 5 * perDay, "credited to the seller");
        assertEq(_reward(1), 0, "the buyer starts from now");
        _days(5);
        assertEq(_reward(1), 5 * perDay);

        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        c.claim(new uint256[](0)); // the seller claims without the NFT
        assertEq(ALICE.balance - before, 5 * perDay);
        vm.expectRevert(abi.encodeWithSelector(PlaceNftCollection.NotTokenOwner.selector, 1));
        vm.prank(ALICE);
        c.claim(_ids(1));
        before = CAROL.balance;
        vm.prank(CAROL);
        c.claim(_ids(1));
        assertEq(CAROL.balance - before, 5 * perDay);
        _assertSolvent();
    }

    /// @notice Accruals happen at 00:00 UTC exactly: one second before, nothing; at midnight, one portion.
    function test_pool_utcDayBoundary() public {
        _toNextDayAt(1 days - 2); // 23:59:58
        _mint(ALICE, 1);
        _mint(BOB, 1);
        vm.warp(vm.getBlockTimestamp() + 1); // 23:59:59
        assertEq(_reward(1), 0);
        vm.warp(vm.getBlockTimestamp() + 1); // 00:00:00
        assertEq(_reward(1), 0.00048 ether / 30 / 2);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1); // 23:59:59 of the same day
        assertEq(_reward(1), 0.00048 ether / 30 / 2, "one portion per day");
    }

    /// @notice Odd amounts and NFT counts: holders never get more than the pool, and the dust left is tiny.
    function test_pool_roundingDust() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.mintPrice = 0.000777777777777777 ether;
        c = _create(CREATOR, p);
        _toNextDayAt(12 hours);
        _mint(ALICE, 3); // first income, 3 NFTs
        _mint(BOB, 4); // second income the same day, then 7 NFTs accrue
        _days(3);
        _mint(CAROL, 2); // third income
        _days(31);
        uint256 income =
            _holdersShare(p.mintPrice * 3) + _holdersShare(p.mintPrice * 4) + _holdersShare(p.mintPrice * 2); // every mint, the first one too
        uint256 sum;
        for (uint256 id = 1; id <= 9; id++) {
            sum += _reward(id);
        }
        assertLe(sum, income + 1, "never more than the pool");
        assertLe(income - Math.min(sum, income), 20, "dust of a few wei");
        address[3] memory who = [ALICE, BOB, CAROL];
        uint256 next;
        for (uint256 i = 0; i < 3; i++) {
            uint256 n = i == 0 ? 3 : i == 1 ? 4 : 2;
            uint256[] memory ids = new uint256[](n);
            for (uint256 j = 0; j < n; j++) {
                ids[j] = ++next;
            }
            vm.prank(who[i]);
            c.claim(ids);
        }
        c.payOut(ETH);
        assertEq(address(c).balance, c.reserved(ETH), "only the dust stays reserved");
        assertLe(c.reserved(ETH), 20);
    }

    function test_mint_limitsAndWindow() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.maxPerWallet = 5;
        c = _create(CREATOR, p);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PlaceNftCollection.WrongPayment.selector, 0, PRICE));
        c.mint(ALICE, 1);
        _mint(ALICE, 5);
        vm.expectRevert(PlaceNftCollection.WalletLimit.selector);
        vm.prank(ALICE);
        c.mint{value: PRICE}(ALICE, 1);

        vm.prank(CREATOR);
        c.setMint(PRICE, uint64(block.timestamp + 1 days), 0, true);
        vm.deal(BOB, 1 ether);
        vm.expectRevert(PlaceNftCollection.MintClosed.selector);
        vm.prank(BOB);
        c.mint{value: PRICE}(BOB, 1);
        vm.warp(block.timestamp + 1 days);
        _mint(BOB, 1);

        p = _p();
        p.maxSupply = 3;
        c = _create(CREATOR, p);
        _mint(BOB, 3);
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
        assertEq(c.reserved(ETH), 0);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        vm.prank(CREATOR);
        c.setMint(0, 0, 0, true);
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

    // ───────────────────────────── reward token and swaps ─────────────────────────────

    /// @notice Holders paid in USD: the ETH holders share is swapped ETH -> USD in the mint transaction and the
    ///         USD joins the pool.
    function test_rewardToken_ethShareSwappedInTheMint() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.rewardToken = address(usd);
        c = _create(CREATOR, p);
        _mint(ALICE, 1); // 0.00024 ETH -> ~0.48 USD into the pool
        assertApproxEqRel(c.rewardRate() * 30 / 1e36, 0.48e18, 0.02e18, "1 ETH ~ 2000 USD, minus the pool fee");
        _mint(BOB, 1); // another ~0.48 USD
        assertEq(c.pendingHolders(ETH), 0);
        assertEq(c.buybackPending(), 0);
        assertApproxEqRel(c.rewardRate() * 30 / 1e36, 0.96e18, 0.02e18);
        _days(30);
        uint256 r = _reward(1);
        assertApproxEqRel(r, 0.48e18, 0.02e18, "half of the pool over 2 NFTs");
        vm.prank(ALICE);
        c.claim(_ids(1));
        assertEq(usd.balanceOf(ALICE), r);
        _assertSolvent();
    }

    /// @notice Paid in the pair token, holders paid in ETH: the token share is sold through the launch pool.
    function test_rewardToken_tokenPaymentSwappedToEth() public {
        _mint(ALICE, 1);
        uint256 ethPool = c.rewardRate();
        assertEq(ethPool, uint256(0.00024 ether) * 1e36 / 30, "the first ETH mint funds the pool directly");
        _mintToken(ALICE, 1); // the same day: re-spreads the whole pool plus the swapped share
        assertEq(c.pendingHolders(token), 0);
        assertApproxEqRel(
            (c.rewardRate() - ethPool) * 30 / 1e36,
            0.00024 ether,
            0.05e18,
            "the ETH value of the token share, minus tax and fees"
        );
        _assertSolvent();
    }

    /// @notice Pair token, holders paid in USD: token -> ETH (launch pool) -> USD in one guarded swap.
    function test_rewardToken_twoHopsFromThePairToken() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.rewardToken = address(usd);
        c = _create(CREATOR, p);
        _mint(ALICE, 1); // ETH -> USD
        uint256 ethPool = c.rewardRate();
        assertApproxEqRel(ethPool * 30 / 1e36, 0.48e18, 0.02e18);
        _mintToken(ALICE, 1); // token -> ETH -> USD
        assertEq(c.pendingHolders(token), 0);
        assertApproxEqRel((c.rewardRate() - ethPool) * 30 / 1e36, 0.48e18, 0.06e18);
        _assertSolvent();
    }

    /// @notice A non-Place pair: any token with a registry route. Token mints, burns and buybacks use the route.
    function test_nonPlacePair_routeFromTheRegistry() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.token = address(usd);
        p.launchPool.tickSpacing = 0;
        c = _create(CREATOR, p);
        assertFalse(c.official());

        uint256 deadBefore = usd.balanceOf(DEAD);
        _mint(ALICE, 1); // first mint: the ETH burn share buys USD and burns it, the holders share joins the pool
        uint256 burnedByEth = usd.balanceOf(DEAD) - deadBefore;
        assertApproxEqRel(burnedByEth, 0.00016 ether * 2000, 0.02e18);
        uint256 ethPool = c.rewardRate();
        assertEq(ethPool, uint256(0.00024 ether) * 1e36 / 30);

        usd.mint(BOB, 100e18);
        uint256 due = c.quoteTokenPrice(1);
        assertApproxEqRel(due, 2e18, 0.02e18, "0.001 ETH ~ 2 USD");
        uint256 paid = _mintToken(BOB, 1);
        uint256 rest = paid - paid * 2_000 / 10_000;
        assertEq(usd.balanceOf(DEAD) - deadBefore - burnedByEth, rest * 2_000 / 10_000, "USD burn share at once");
        assertEq(c.totalBurned(), usd.balanceOf(DEAD) - deadBefore);
        // The USD holders share was sold for ETH (the reward token) in the same mint.
        assertApproxEqRel((c.rewardRate() - ethPool) * 30 / 1e36, 0.00024 ether, 0.02e18);
        _assertSolvent();
    }

    // ───────────────────────────── deferred swaps ─────────────────────────────

    /// @notice While the pair's price is manipulated the mint still succeeds; the swaps wait, and the holders
    ///         share joins the pool when a later mint swaps it.
    function test_deferral_mintNeverFails_poolFundedOnSwap() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.rewardToken = token; // holders paid in the pair token
        c = _create(CREATOR, p);
        _toNextDayAt(12 hours); // every mint below on one UTC day
        _mint(ALICE, 1); // fair price: the first mint's ETH share is swapped into the pool at once
        uint256 firstPool = c.rewardRate();
        assertGt(firstPool, 0);
        assertEq(c.pendingHolders(ETH), 0);
        _next();
        _swap(ATTACKER, key, token, true, 0.05 ether); // pump: spot > 3% off the reference
        _mint(BOB, 1);
        _mint(CAROL, 1);
        assertEq(c.pendingHolders(ETH), 0.00024 ether + 0.00024 ether);
        assertEq(c.buybackPending(), 0.00032 ether);
        assertEq(c.rewardRate(), firstPool, "nothing added to the pool before the swap");

        _swap(ATTACKER, key, token, false, IERC20(token).balanceOf(ATTACKER)); // price back in the band
        _next();
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        _mint(ALICE, 1); // swaps everything waiting (and this mint's share) into the pool
        assertEq(c.pendingHolders(ETH), 0);
        assertEq(c.buybackPending(), 0, "waiting burn ran");
        assertGt(IERC20(token).balanceOf(DEAD) - deadBefore, 0);
        uint256 funded = c.rewardRate() * 30 / 1e36;
        assertGt(c.rewardRate(), firstPool);
        _days(30);
        assertApproxEqAbs(_reward(1), funded / 4, 4, "4 NFTs exist at every accrual after the swap");
        _assertSolvent();
    }

    // ───────────────────────────── royalties ─────────────────────────────

    /// @notice ETH royalties wait for the next mint (or `processPending` after sold out) and join the pool.
    function test_royalties_ethWaitsThenJoinsThePool() public {
        PlaceNftCollection.InitParams memory p = _p();
        p.maxSupply = 3;
        c = _create(CREATOR, p);
        _toNextDayAt(12 hours);
        _mint(ALICE, 2); // 0.00048 into the pool
        (address receiver, uint256 amount) = c.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(c));
        assertEq(amount, 0.05 ether);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 0.05 ether}(""); // a marketplace pays the royalty
        assertTrue(ok);
        assertEq(c.rewardRate(), uint256(0.00048 ether) * 1e36 / 30, "royalty not split yet");
        uint256 creatorBefore = c.creatorOwed(ETH);
        _mint(BOB, 1); // sold out
        assertEq(c.creatorOwed(ETH) - creatorBefore, 0.02 ether + 0.0004 ether);
        // The first mint's share (the same day) plus 30% of 80% of the royalty and of this mint.
        uint256 x = 0.00048 ether + 0.012 ether + 0.00024 ether;
        assertEq(c.rewardRate(), x * 1e36 / 30);

        // Sold out: anyone splits later royalties into the pool.
        _days(10);
        (ok,) = address(c).call{value: 0.03 ether}("");
        assertEq(c.processPending(ETH), 0.03 ether);
        assertEq(c.processPending(ETH), 0, "nothing new: no revert");
        _days(30);
        uint256 total = _reward(1) + _reward(2) + _reward(3);
        assertApproxEqAbs(total, x + 0.0072 ether, 10, "both incomes paid in full");
        _assertSolvent();
    }

    function test_royalties_wethTokenAndOtherAssets() public {
        MockWETH weth = new MockWETH();
        nftFactory.setWeth(address(weth));
        _toNextDayAt(12 hours);
        _mint(ALICE, 1); // 0.00024 into the pool
        weth.deposit{value: 0.01 ether}();
        weth.transfer(address(c), 0.01 ether);
        uint256 creatorBefore = c.creatorOwed(ETH);
        assertEq(c.processPending(address(weth)), 0.01 ether);
        assertEq(weth.balanceOf(address(c)), 0);
        assertEq(c.creatorOwed(ETH) - creatorBefore, 0.004 ether);
        assertEq(
            c.rewardRate(),
            uint256(0.00024 ether + 0.0024 ether) * 1e36 / 30,
            "the mint's share + 30% of 80% into the pool"
        );

        // Royalty in the pair token: its burn share is burned at once.
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        vm.prank(TRADER);
        IERC20(token).transfer(address(c), 1_000e18);
        c.processPending(token);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, 160e18, "20% of 80%");

        // Any other ERC-20: 20% platform, 80% creator.
        usd.mint(address(c), 100e18);
        c.processPending(address(usd));
        c.payOut(address(usd));
        assertEq(usd.balanceOf(PLATFORM), 20e18);
        assertEq(usd.balanceOf(CREATOR), 80e18);
        _assertSolvent();
    }

    function test_royalties_settableCapped() public {
        vm.prank(CREATOR);
        c.setRoyaltyBps(1_000);
        vm.expectRevert(PlaceNftCollection.InvalidConfig.selector);
        vm.prank(CREATOR);
        c.setRoyaltyBps(1_001);
    }

    // ───────────────────────────── token payments ─────────────────────────────

    function test_mintWithToken_marketPriceAndBurn() public {
        uint256 due = c.quoteTokenPrice(1);
        (uint256 refOut, uint256 spotOut) = guard.quote(route, ETH, PRICE);
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
        assertEq(c.creatorOwed(token), rest - rest * 2_000 / 10_000 - rest * 3_000 / 10_000, "50% to the creator");
        assertEq(c.pendingHolders(token), 0, "first mint: the holders share is swapped into the pool");
        assertGt(c.rewardRate(), 0);
        _assertSolvent();
    }

    // ───────────────────────────── empty collection ─────────────────────────────

    /// @notice ETH royalties split while no NFT exists and none is minted: the holders share goes to the creator
    ///         (a pool without NFTs could never pay out); the next mint's pool holds only its own share.
    function test_royalties_ethOnEmptyCollection_holdersShareToCreator() public {
        _toNextDayAt(12 hours);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 0.05 ether}("");
        assertTrue(ok);
        assertEq(c.processPending(ETH), 0.05 ether);
        assertEq(c.platformOwed(ETH), 0.01 ether);
        assertEq(c.creatorOwed(ETH), 0.032 ether, "50% + the 30% holders share of 80%");
        assertEq(c.rewardRate(), 0, "pool empty");
        assertEq(c.periodFinish(), 0);
        assertEq(c.pendingHolders(ETH), 0);
        assertEq(c.buybackPending(), 0, "burn share bought and burned");
        assertEq(c.reserved(ETH), 0.042 ether);
        _assertSolvent();

        _days(2);
        _mint(ALICE, 1);
        assertEq(c.rewardRate(), uint256(0.00024 ether) * 1e36 / 30, "only the mint's own share");
        _days(31);
        assertEq(_reward(1), 0.00024 ether);
        c.payOut(ETH);
        assertEq(CREATOR.balance, 0.032 ether + 0.0004 ether);
        vm.prank(ALICE);
        c.claim(_ids(1));
        assertEq(c.reserved(ETH), 0, "nothing stranded");
        _assertSolvent();
    }

    /// @notice Mints over several days, a royalty and transfers: after the pool ends every holders income is paid
    ///         out to the wei, and once everyone claims and the creator and platform are paid, nothing stays reserved
    ///         beyond rounding dust.
    function test_pool_solventAfterThirtyDays_noStrandedRewards() public {
        _toNextDayAt(12 hours);
        _mint(ALICE, 3); // first mint: funds the pool
        _days(5);
        _mint(BOB, 2);
        vm.prank(ALICE);
        c.transferFrom(ALICE, CAROL, 2);
        _days(2);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(c).call{value: 0.01 ether}("");
        assertTrue(ok);
        c.processPending(ETH);
        uint256 income = _holdersShare(0.003 ether) + _holdersShare(0.002 ether) + _holdersShare(0.01 ether);
        _assertSolvent();
        _days(31);
        uint64 today = uint64(vm.getBlockTimestamp() / 1 days);
        assertLt(c.periodFinish(), today, "the pool ended");

        uint256 sum;
        for (uint256 id = 1; id <= 5; id++) {
            sum += _reward(id);
        }
        sum += c.credit(ALICE); // NFT 2 before the transfer
        assertLe(sum, income, "never more than the pool");
        assertLe(income - sum, 10, "dust of a few wei");

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 3);
        vm.prank(ALICE);
        c.claim(ids);
        vm.prank(CAROL);
        c.claim(_ids(2));
        (ids[0], ids[1]) = (4, 5);
        vm.prank(BOB);
        c.claim(ids);
        c.payOut(ETH);
        assertEq(c.buybackPending(), 0);
        assertEq(c.credit(ALICE) + c.credit(BOB) + c.credit(CAROL), 0);
        assertEq(address(c).balance, c.reserved(ETH), "nothing unaccounted");
        assertLe(c.reserved(ETH), 10, "only rounding dust stays");
        _days(30);
        for (uint256 id = 1; id <= 5; id++) {
            assertEq(_reward(id), 0, "nothing accrues after the end");
        }
        _assertSolvent();
    }

    function test_mintWithToken_disabled() public {
        vm.prank(CREATOR);
        c.setMint(PRICE, 0, 0, false);
        vm.expectRevert(PlaceNftCollection.TokenPaymentsDisabled.selector);
        c.mintWithToken(ALICE, 1, type(uint256).max);
    }

    // ───────────────────────────── manipulation ─────────────────────────────

    /// @notice A flash pump in the same block does not lower what a token buyer pays.
    function test_manipulation_smallPumpCannotLowerTokenPrice() public {
        uint256 dueBefore = c.quoteTokenPrice(1);
        _swap(ATTACKER, key, token, true, 0.0002 ether);
        (uint256 refOut, uint256 spotOut) = guard.quote(route, ETH, PRICE);
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
        _mint(ALICE, 1); // ETH mints keep working; the burn waits
        assertEq(c.buybackPending(), 0.00016 ether);
    }

    /// @notice An observation written in the current block is ignored by quotes in that block.
    function test_manipulation_pumpThenObserveSameBlockIgnored() public {
        (uint256 refBefore,) = guard.quote(route, ETH, PRICE);
        _next();
        _swap(ATTACKER, key, token, true, 0.05 ether);
        guard.observeRoute(route);
        PlacePriceGuard.Observation memory o = guard.observation(key.toId());
        assertEq(o.updatedBlock, block.number);
        _swap(ATTACKER, key, token, false, IERC20(token).balanceOf(ATTACKER));
        (uint256 refNow,) = guard.quote(route, ETH, PRICE);
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
        assertTrue(ref1 != ref0);
        vm.roll(block.number + 1);
        guard.observeRoute(route);
        assertEq(guard.observation(key.toId()).refPrice, ref1, "no second step inside the interval");
        _next();
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        guard.quote(route, ETH, PRICE);
    }

    function test_guard_notReadyAndBounds() public {
        (OwnedToken ext, PoolKey memory k) = _externalPair(BOB);
        ext; // fresh pool, never observed
        PoolKey[] memory other = new PoolKey[](1);
        other[0] = k;
        vm.expectRevert(abi.encodeWithSelector(PlacePriceGuard.PriceNotReady.selector, k.toId(), 0));
        guard.quote(other, ETH, 1 ether);
        guard.observeRoute(other);
        vm.expectPartialRevert(PlacePriceGuard.PriceNotReady.selector);
        guard.quote(other, ETH, 1 ether);
        vm.warp(block.timestamp + GUARD_WARMUP);
        vm.roll(block.number + 1);
        (uint256 refOut, uint256 spotOut) = guard.quote(other, ETH, 1 ether);
        assertApproxEqRel(refOut, 2_000e18, 0.01e18, "1 ETH ~ 2000 tokens");
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

    /// @notice A sandwich around a waiting buyback reverts it; once the price is back anyone runs it in slices.
    function test_buyback_publicSlicesAndSandwichReverts() public {
        _next();
        _swap(ATTACKER, key, token, true, 0.05 ether);
        _mint(ALICE, 5); // burn share 0.0008 ETH waits
        assertEq(c.buybackPending(), 0.0008 ether);
        vm.expectPartialRevert(PlacePriceGuard.PriceDeviation.selector);
        c.buyback(type(uint256).max);

        _swap(ATTACKER, key, token, false, IERC20(token).balanceOf(ATTACKER));
        _next();
        vm.prank(BOB);
        uint256 burned = c.buyback(0.0003 ether);
        assertGt(burned, 0);
        assertEq(c.buybackPending(), 0.0005 ether);
        assertEq(c.totalBurned(), burned);
        c.buyback(type(uint256).max);
        vm.expectRevert(PlaceNftCollection.NothingToDo.selector);
        c.buyback(1);
        _assertSolvent();
    }

    /// @notice A front-run inside the guard's band costs the in-mint buyback at most deviation + impact.
    function test_buyback_smallSandwichLossBounded() public {
        (uint256 refOut,) = guard.quote(route, ETH, 0.0008 ether);
        _swap(ATTACKER, key, token, true, 0.0002 ether); // small pump, inside the 3% band
        _mint(ALICE, 5); // burn 0.0008 ETH in the mint
        assertEq(c.buybackPending(), 0);
        assertGe(c.totalBurned(), refOut * (10_000 - GUARD_DEVIATION - MAX_IMPACT) / 10_000);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    /// @notice Any economy and reward token, mints in ETH and the pair token, a transfer and claims: every split
    ///         is fully owed and the contract stays solvent in every asset.
    function testFuzz_economyConservesAndSolvent(uint16 creatorBps, uint16 holdersBps, uint8 a, uint8 b, uint8 rt)
        public
    {
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        holdersBps = uint16(bound(holdersBps, 0, 10_000 - creatorBps));
        uint256 qa = bound(a, 1, 5);
        uint256 qb = bound(b, 1, 5);
        PlaceNftCollection.InitParams memory p = _p();
        p.economy = PlaceNftCollection.Economy({
            creatorBps: creatorBps, holdersBps: holdersBps, burnBps: 10_000 - creatorBps - holdersBps
        });
        uint256 r = rt % 3;
        p.rewardToken = r == 0 ? ETH : r == 1 ? token : address(usd);
        c = _create(CREATOR, p);
        _mint(ALICE, qa);
        _mint(BOB, qb);
        _mintToken(ALICE, 1);
        vm.prank(ALICE);
        c.transferFrom(ALICE, CAROL, 1);
        _mint(BOB, 1);
        _assertSolvent();
        _days(31);
        uint256[] memory ids = new uint256[](qa - 1);
        for (uint256 i = 0; i < qa - 1; i++) {
            ids[i] = i + 2;
        }
        vm.prank(ALICE);
        c.claim(ids);
        vm.prank(CAROL);
        c.claim(_ids(1));
        c.payOut(ETH);
        if (c.creatorOwed(token) + c.platformOwed(token) != 0) c.payOut(token);
        _assertSolvent();
        assertEq(c.buybackPending(), 0, "no manipulation: every burn ran");
    }
}
