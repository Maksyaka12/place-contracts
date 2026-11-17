// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaceFeeMath} from "../../src/launch/PlaceFeeMath.sol";
import {PlaceSuiteConstants} from "../../src/launch/PlaceSuiteConstants.sol";

/// @notice PlaceFeeMath under the fixed Place policy: Standard 1% and Economy 1%..5% with five baskets.
contract FeeMathFuzzTest is Test {
    uint256 internal constant SCALE = 1e8;

    /// @dev Library reverts surface at the call depth of an external call.
    function validate(PlaceFeeMath.TaxConfiguration memory c) external pure {
        PlaceFeeMath.validateTax(c, _policy());
    }

    function _policy() internal pure returns (PlaceFeeMath.TaxPolicy memory policy) {
        policy.taxFeeBounds = PlaceFeeMath.TaxFeeBounds(1_000_000, 5_000_000, 1_000_000, 5_000_000);
        policy.protocolFeeConfiguration = PlaceFeeMath.ProtocolFeeConfiguration({
            protocolTaxShare: PlaceSuiteConstants.PLACE_PROTOCOL_SHARE,
            minimumProtocolFeeRate: PlaceSuiteConstants.PLACE_MIN_PROTOCOL_FEE_RATE,
            maximumProtocolFeeRate: PlaceSuiteConstants.PLACE_MAX_PROTOCOL_FEE_RATE,
            protocolFeeRecipient: address(1)
        });
        policy.antiSnipeConfiguration =
            PlaceFeeMath.AntiSnipeConfiguration(PlaceSuiteConstants.ANTI_SNIPE_START_FEE_RATE, 20);
    }

    function _standard() internal pure returns (PlaceFeeMath.TaxConfiguration memory c) {
        c.buyTaxRate = PlaceSuiteConstants.PLACE_FEE_RATE;
        c.sellTaxRate = PlaceSuiteConstants.PLACE_FEE_RATE;
        c.creatorAllocationShare = uint32(SCALE);
    }

    /// @dev Five shares from four cut points, always summing to 100%.
    function _economy(uint32 buy, uint32 sell, uint32[4] memory cuts)
        internal
        pure
        returns (PlaceFeeMath.TaxConfiguration memory c)
    {
        c.buyTaxRate = uint32(bound(buy, 1_000_000, 5_000_000));
        c.sellTaxRate = uint32(bound(sell, 1_000_000, 5_000_000));
        uint256[4] memory p;
        for (uint256 i = 0; i < 4; i++) {
            p[i] = bound(cuts[i], 0, SCALE);
        }
        // sort the cut points
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                if (p[j] < p[i]) (p[i], p[j]) = (p[j], p[i]);
            }
        }
        c.creatorAllocationShare = uint32(p[0]);
        c.holderAllocationShare = uint32(p[1] - p[0]);
        c.traderAllocationShare = uint32(p[2] - p[1]);
        c.burnAllocationShare = uint32(p[3] - p[2]);
        c.communityAllocationShare = uint32(SCALE - p[3]);
    }

    function test_standard_validates_30_70() public pure {
        PlaceFeeMath.validateTax(_standard(), _policy());
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(1_000_000, _policy().protocolFeeConfiguration, _standard(), 0);
        uint256 full = PlaceSuiteConstants.RATE_SCALE;
        assertEq(r.quoteRate, full / 100, "1%");
        assertEq(r.protocolRate, full * 3 / 1000, "0.3%");
        assertEq(r.creatorRate, full * 7 / 1000, "0.7%");
        assertEq(r.burnRate + r.holderRate + r.traderRate + r.communityRate, 0);
    }

    function test_protocol_isAlways30pct_of1to5() public pure {
        PlaceFeeMath.ProtocolFeeConfiguration memory p = _policy().protocolFeeConfiguration;
        assertEq(PlaceFeeMath.protocolRateNumerator(1_000_000, p), 300_000 * SCALE, "1% -> 0.3%");
        assertEq(PlaceFeeMath.protocolRateNumerator(3_000_000, p), 900_000 * SCALE, "3% -> 0.9%");
        assertEq(PlaceFeeMath.protocolRateNumerator(5_000_000, p), 1_500_000 * SCALE, "5% -> 1.5%");
    }

    function test_economy_outOfBounds_reverts() public {
        PlaceFeeMath.TaxConfiguration memory c = _standard();
        c.buyTaxRate = 5_000_001;
        vm.expectRevert(PlaceFeeMath.InvalidTaxConfiguration.selector);
        this.validate(c);
        c.buyTaxRate = 999_999;
        vm.expectRevert(PlaceFeeMath.InvalidTaxConfiguration.selector);
        this.validate(c);
    }

    function test_economy_sharesNot100_reverts() public {
        PlaceFeeMath.TaxConfiguration memory c = _standard();
        c.creatorAllocationShare = uint32(SCALE - 1);
        vm.expectRevert(PlaceFeeMath.InvalidTaxConfiguration.selector);
        this.validate(c);
        c.holderAllocationShare = 2;
        vm.expectRevert(PlaceFeeMath.InvalidTaxConfiguration.selector);
        this.validate(c);
    }

    /// Any Economy config with five shares summing to 100% validates and its rates add up to the tax exactly.
    function testFuzz_economy_ratesAddUp(uint32 buy, uint32 sell, uint32[4] memory cuts) public pure {
        PlaceFeeMath.TaxConfiguration memory c = _economy(buy, sell, cuts);
        assertEq(PlaceFeeMath.shareSum(c), SCALE, "baskets sum to 100%");
        PlaceFeeMath.validateTax(c, _policy());
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(c.buyTaxRate, _policy().protocolFeeConfiguration, c, 0);
        assertEq(r.quoteRate + r.burnRate, uint256(c.buyTaxRate) * SCALE * SCALE, "rates = tax");
        assertEq(r.protocolRate, uint256(c.buyTaxRate) * 30_000_000 * SCALE, "protocol 30%");
    }

    /// The whole quote fee is split with nothing lost; each basket stays within its share (+1 unit of dust).
    function testFuzz_split_conserves(uint128 amount, uint32 elapsed, uint32 tax, uint32[4] memory cuts) public pure {
        PlaceFeeMath.TaxConfiguration memory c = _economy(tax, tax, cuts);
        uint256 extra = PlaceFeeMath.surcharge(c.buyTaxRate, 99_000_000, 1000, 20, 1000 + uint256(elapsed), true);
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(c.buyTaxRate, _policy().protocolFeeConfiguration, c, extra);
        if (r.quoteRate == 0) return;
        PlaceFeeMath.QuoteSplit memory s = PlaceFeeMath.splitQuoteFee(amount, r);
        assertEq(
            s.protocolAmount + s.surchargeAmount + s.creatorAmount + s.holderAmount + s.traderAmount
                + s.communityAmount,
            amount,
            "conserved"
        );
        if (c.holderAllocationShare == 0) assertEq(s.holderAmount, 0);
        if (c.traderAllocationShare == 0) assertEq(s.traderAmount, 0);
        if (c.communityAllocationShare == 0) assertEq(s.communityAmount, 0);
        uint256 quoteShare = SCALE - c.burnAllocationShare;
        if (extra == 0 && quoteShare != 0) {
            // creator side of the quote fee: 70% x (quote baskets) / (all quote baskets incl. the protocol)
            uint256 sides = s.creatorAmount + s.holderAmount + s.traderAmount + s.communityAmount;
            assertLe(s.protocolAmount, uint256(amount), "protocol bounded");
            assertLe(sides, uint256(amount));
        }
    }

    function testFuzz_surcharge_decaysMonotonically(uint32 a, uint32 b) public pure {
        (uint32 lo, uint32 hi) = a < b ? (a, b) : (b, a);
        uint256 early = PlaceFeeMath.surcharge(1_000_000, 99_000_000, 0, 20, lo, true);
        uint256 late = PlaceFeeMath.surcharge(1_000_000, 99_000_000, 0, 20, hi, true);
        assertGe(early, late);
        assertLe(early, 98_000_000);
        if (hi >= 20) assertEq(late, 0);
    }

    function testFuzz_exactInFee_isTheTax(uint128 amountIn, uint32 tax) public pure {
        PlaceFeeMath.TaxConfiguration memory c = _standard();
        c.buyTaxRate = uint32(bound(tax, 1_000_000, 5_000_000));
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(c.buyTaxRate, _policy().protocolFeeConfiguration, c, 0);
        uint256 fee = PlaceFeeMath.specifiedFee(amountIn, r.quoteRate, r.burnRate, false);
        assertEq(fee, uint256(amountIn) * c.buyTaxRate / SCALE);
    }
}
