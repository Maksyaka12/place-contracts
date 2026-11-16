// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EconomyFixture} from "../utils/EconomyFixture.sol";
import {MockEscrow, MockHookPm, MockHub} from "../utils/Mocks.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";

/// @notice Fast fuzzing of the basket split on a stand-alone vault clone (mock escrow, no pool).
contract VaultSplitFuzzTest is Test {
    PlaceCreatorVault internal impl;
    MockEscrow internal escrow;
    MockHub internal hub;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TOKEN = address(0x7001);

    function setUp() public {
        impl = new PlaceCreatorVault();
        escrow = new MockEscrow();
        hub = new MockHub();
    }

    /// The vault asks its "factory" (this test) who the creator is.
    function currentCreatorOf(address) external pure returns (address) {
        return CREATOR;
    }

    function _vault(uint16 burnBps, uint16 communityBps, uint16 x1, uint16 x2) internal returns (PlaceCreatorVault v) {
        v = PlaceCreatorVault(payable(Clones.clone(address(impl))));
        PlaceCreatorVault.Initialization memory init;
        init.token = TOKEN;
        init.poolKey = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(TOKEN), 0, 200, IHooks(address(new MockHookPm(address(1))))
        );
        init.feeEscrow = address(escrow);
        init.burnBps = burnBps;
        init.communityBps = communityBps;
        uint256 n = (x1 != 0 ? 1 : 0) + (x2 != 0 ? 1 : 0);
        init.xShares = new PlaceCreatorVault.XShare[](n);
        uint256 i;
        if (x1 != 0) init.xShares[i++] = PlaceCreatorVault.XShare({xId: 1, bps: x1});
        if (x2 != 0) init.xShares[i] = PlaceCreatorVault.XShare({xId: 2, bps: x2});
        init.xRegistry = address(0xBEEF);
        init.settings.hub = address(hub);
        init.settings.defaultCampaignDelay = 30 days;
        init.settings.rulesHash = keccak256("rules");
        init.settings.rulesURI = "ipfs://rules";
        v.initialize(init);
    }

    /// Every collected wei lands in exactly one basket, each basket gets its floor share, nothing is lost,
    /// and the community fund is whatever is not earmarked.
    function testFuzz_basketSplit(uint16 burnBps, uint16 communityBps, uint16 x1, uint16 x2, uint96 a, uint96 b)
        public
    {
        burnBps = uint16(bound(burnBps, 0, 10_000));
        communityBps = uint16(bound(communityBps, 0, 10_000 - burnBps));
        x1 = uint16(bound(x1, 0, 10_000));
        x2 = uint16(bound(x2, 0, 10_000 - x1));
        PlaceCreatorVault v = _vault(burnBps, communityBps, x1, x2);

        uint256 burnSum;
        uint256 communitySum;
        uint256 xSum;
        uint256 creatorSum;
        uint96[2] memory amounts = [a, b];
        for (uint256 k = 0; k < 2; k++) {
            uint256 amount = amounts[k];
            if (amount == 0) continue;
            vm.deal(address(this), amount);
            escrow.credit{value: amount}(address(v));
            v.collect();
            uint256 toBurn = amount * burnBps / 10_000;
            uint256 toCommunity = amount * communityBps / 10_000;
            uint256 side = amount - toBurn - toCommunity;
            uint256 toX = side * x1 / 10_000 + side * x2 / 10_000;
            burnSum += toBurn;
            communitySum += toCommunity;
            xSum += toX;
            creatorSum += side - toX;
        }
        assertEq(v.burnReserve(), burnSum, "burn basket");
        assertEq(v.xOwedTotal(), xSum, "X shares");
        assertEq(v.xOwed(1) + v.xOwed(2), xSum);
        assertEq(v.creatorOwed(), creatorSum, "creator");
        assertEq(v.fundBalance(address(0)), communitySum, "community fund");
        assertEq(address(v).balance, uint256(a) + b, "nothing lost");
        assertEq(burnSum + communitySum + xSum + creatorSum, uint256(a) + b);
    }

    /// Shares can only go up, and never above 100% together.
    function testFuzz_increaseOnlyUp(uint16 burnBps, uint16 communityBps, uint16 nb, uint16 nc) public {
        burnBps = uint16(bound(burnBps, 0, 10_000));
        communityBps = uint16(bound(communityBps, 0, 10_000 - burnBps));
        PlaceCreatorVault v = _vault(burnBps, communityBps, 0, 0);
        vm.prank(CREATOR);
        try v.increaseEconomics(nb, nc) {
            assertGe(nb, burnBps);
            assertGe(nc, communityBps);
            assertLe(uint256(nb) + nc, 10_000);
        } catch {
            assertTrue(nb < burnBps || nc < communityBps || uint256(nb) + nc > 10_000);
        }
    }
}

/// @notice process() limits on a real launch: per-call cap, interval, reserve accounting, under fuzzed trading.
contract VaultProcessFuzzTest is EconomyFixture {
    address internal token;
    PoolKey internal key;
    PlaceCreatorVault internal vault;

    function setUp() public {
        _deployEconomy();
        (token,, key, vault) = _launchEco(5_000, 2_000, 0, 0);
    }

    function testFuzz_processLimits(uint256 seed) public {
        uint256 lastBurnAt;
        for (uint256 step = 0; step < 6; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            _swap(TRADER, key, token, true, bound(r, 0.01 ether, 3 ether));
            vm.warp(block.timestamp + bound(r >> 64, 1 hours, 2 days));

            uint256 pending = vault.pendingFees();
            uint256 reserveBefore = vault.burnReserve();
            uint256 deadBefore = IERC20(token).balanceOf(address(0xdEaD));
            bool due = lastBurnAt == 0 || vm.getBlockTimestamp() >= lastBurnAt + PROCESS_INTERVAL;
            if (!due) {
                vm.expectRevert();
                vault.process();
                continue;
            }
            (uint256 collected, uint256 quoteIn, uint256 burned) = vault.process();
            lastBurnAt = vm.getBlockTimestamp();
            assertEq(collected, pending);
            uint256 booked = reserveBefore + collected * 5_000 / 10_000;
            uint256 expectIn = booked > MAX_BURN ? MAX_BURN : booked;
            if (expectIn < vault.MIN_BURN_AMOUNT()) expectIn = 0;
            assertEq(quoteIn, expectIn, "min(reserve, cap)");
            assertLe(quoteIn, MAX_BURN, "never above the cap");
            assertEq(vault.burnReserve(), booked - quoteIn, "the rest waits");
            assertEq(IERC20(token).balanceOf(address(0xdEaD)) - deadBefore, burned, "all to 0xdead");
            // a repeat in the same block always reverts
            vm.expectRevert();
            vault.process();
        }
        assertGe(address(vault).balance, vault.burnReserve() + vault.creatorOwed() + vault.xOwedTotal());
    }
}
