// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaceFeeMath} from "../../src/launch/PlaceFeeMath.sol";
import {PlaceSuiteConstants} from "../../src/launch/PlaceSuiteConstants.sol";

/// @notice PlaceFeeMath (o1's TaxFeeMath, unchanged) under the fixed Place policy.
contract FeeMathFuzzTest is Test {
    uint256 internal constant SCALE = 1e8;

    function _policy() internal pure returns (PlaceFeeMath.TaxPolicy memory policy) {
        uint32 rate = PlaceSuiteConstants.PLACE_FEE_RATE;
        policy.taxFeeBounds = PlaceFeeMath.TaxFeeBounds(rate, rate, rate, rate);
        policy.protocolFeeConfiguration = PlaceFeeMath.ProtocolFeeConfiguration({
            protocolTaxShare: PlaceSuiteConstants.PLACE_PROTOCOL_SHARE,
            minimumProtocolFeeRate: PlaceSuiteConstants.PLACE_PROTOCOL_FEE_RATE,
            maximumProtocolFeeRate: PlaceSuiteConstants.PLACE_PROTOCOL_FEE_RATE,
            protocolFeeRecipient: address(1)
        });
        policy.antiSnipeConfiguration =
            PlaceFeeMath.AntiSnipeConfiguration(PlaceSuiteConstants.ANTI_SNIPE_START_FEE_RATE, 20);
    }

    function _config() internal pure returns (PlaceFeeMath.TaxConfiguration memory c) {
        c.buyTaxRate = PlaceSuiteConstants.PLACE_FEE_RATE;
        c.sellTaxRate = PlaceSuiteConstants.PLACE_FEE_RATE;
        c.creatorAllocationShare = uint32(SCALE);
    }

    function test_policyAndConfigValidate() public pure {
        bool dividends = PlaceFeeMath.validateTax(_config(), _policy(), 1e27);
        assertFalse(dividends);
    }

    function test_rates_1pct_25_75() public pure {
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(1_000_000, _policy().protocolFeeConfiguration, _config(), 0);
        uint256 full = PlaceSuiteConstants.RATE_SCALE;
        assertEq(r.quoteRate, full / 100, "1%");
        assertEq(r.protocolRate, full / 400, "0.25%");
        assertEq(r.creatorRate, full * 3 / 400, "0.75%");
        assertEq(r.burnRate + r.dividendRate + r.integratorRate, 0);
    }

    /// The whole quote fee is split with nothing lost, platform gets 25% (+ the surcharge), creator the rest.
    function testFuzz_split_conserves(uint128 amount, uint32 elapsed) public pure {
        uint256 extra = PlaceFeeMath.surcharge(1_000_000, 99_000_000, 1000, 20, 1000 + uint256(elapsed), true);
        PlaceFeeMath.Rates memory r =
            PlaceFeeMath.rates(1_000_000, _policy().protocolFeeConfiguration, _config(), extra);
        (uint256 p, uint256 s, uint256 c, uint256 d, uint256 i) = PlaceFeeMath.splitQuoteFee(amount, r);
        assertEq(p + s + c + d + i, amount);
        assertEq(d + i, 0);
        if (extra == 0) {
            assertEq(s, 0);
            assertApproxEqAbs(p * 3, c, 3);
        }
        assertLe(c, uint256(amount) * 3 / 4 + 1, "creator never above 75% of the fee");
    }

    function testFuzz_surcharge_decaysMonotonically(uint32 a, uint32 b) public pure {
        (uint32 lo, uint32 hi) = a < b ? (a, b) : (b, a);
        uint256 early = PlaceFeeMath.surcharge(1_000_000, 99_000_000, 0, 20, lo, true);
        uint256 late = PlaceFeeMath.surcharge(1_000_000, 99_000_000, 0, 20, hi, true);
        assertGe(early, late);
        assertLe(early, 98_000_000);
        if (hi >= 20) assertEq(late, 0);
    }

    function testFuzz_exactInFee_isOnePercent(uint128 amountIn) public pure {
        PlaceFeeMath.Rates memory r = PlaceFeeMath.rates(1_000_000, _policy().protocolFeeConfiguration, _config(), 0);
        uint256 fee = PlaceFeeMath.specifiedFee(amountIn, r.quoteRate, r.burnRate, false);
        assertEq(fee, uint256(amountIn) / 100);
    }
}
