// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fee math for the tax suite: policy validation, the protocol cut, the split of the remainder, the
///         anti-snipe surcharge and swap fee amounts. Every rounding rule is defined here.
library TaxFeeMath {
    uint256 internal constant PERCENTAGE_SCALE = TaxSuiteConstants.PERCENTAGE_SCALE;
    uint256 internal constant RATE_SCALE = TaxSuiteConstants.RATE_SCALE;
    uint256 internal constant MAX_TOTAL_FEE_RATE = TaxSuiteConstants.MAX_TOTAL_FEE_RATE;

    struct TaxFeeBounds {
        uint32 minimumBuyTaxRate;
        uint32 maximumBuyTaxRate;
        uint32 minimumSellTaxRate;
        uint32 maximumSellTaxRate;
    }

    struct ProtocolFeeConfiguration {
        uint32 protocolTaxShare;
        uint32 minimumProtocolFeeRate;
        uint32 maximumProtocolFeeRate;
        address protocolFeeRecipient;
    }

    struct AntiSnipeConfiguration {
        uint32 startTotalFeeRate;
        uint32 windowSeconds;
    }

    struct TaxPolicy {
        TaxFeeBounds taxFeeBounds;
        ProtocolFeeConfiguration protocolFeeConfiguration;
        AntiSnipeConfiguration antiSnipeConfiguration;
        uint256 minimumDividendHoldingRequirement;
    }

    /// @dev Shares divide the remainder after protocol, using the same split on both trading sides.
    struct TaxConfiguration {
        uint32 buyTaxRate;
        uint32 sellTaxRate;
        uint32 creatorAllocationShare;
        uint32 burnAllocationShare;
        uint32 dividendAllocationShare;
        uint32 integratorAllocationShare;
        uint256 minimumDividendHolding;
    }

    struct Rates {
        uint256 quoteRate;
        uint256 burnRate;
        uint256 protocolRate;
        uint256 creatorRate;
        uint256 dividendRate;
        uint256 integratorRate;
        uint256 surchargeRate;
    }

    struct TaxConfigurationPreview {
        uint64 configVersion;
        Rates buyRates;
        Rates sellRates;
        bool dividendsEnabled;
        uint256 minimumDividendHoldingRequirement;
    }

    error InvalidTaxBounds();
    error InvalidTaxConfiguration();
    error InvalidProtocolFeeConfiguration();
    error InvalidMinimumDividendHoldingRequirement();
    error InvalidFeeSchedule();

    function validatePolicy(TaxPolicy memory policy, uint256 supply) internal pure {
        _validateProtocol(policy.protocolFeeConfiguration);
        uint256 minimum = policy.protocolFeeConfiguration.minimumProtocolFeeRate;
        TaxFeeBounds memory bounds = policy.taxFeeBounds;
        _validateSideBounds(bounds.minimumBuyTaxRate, bounds.maximumBuyTaxRate, minimum);
        _validateSideBounds(bounds.minimumSellTaxRate, bounds.maximumSellTaxRate, minimum);
        AntiSnipeConfiguration memory anti = policy.antiSnipeConfiguration;
        if (
            anti.startTotalFeeRate > MAX_TOTAL_FEE_RATE
                || (anti.windowSeconds != 0
                    && (anti.startTotalFeeRate < bounds.maximumBuyTaxRate
                        || anti.startTotalFeeRate < bounds.maximumSellTaxRate))
        ) revert InvalidFeeSchedule();
        if (policy.minimumDividendHoldingRequirement > supply) revert InvalidMinimumDividendHoldingRequirement();
    }

    function _validateSideBounds(uint256 minimum, uint256 maximum, uint256 protocolMinimum) private pure {
        if (
            minimum > maximum || maximum > MAX_TOTAL_FEE_RATE || (minimum != 0 && minimum < protocolMinimum)
                || (maximum != 0 && maximum < protocolMinimum)
        ) revert InvalidTaxBounds();
    }

    function _validateProtocol(ProtocolFeeConfiguration memory protocol) private pure {
        if (
            protocol.protocolTaxShare > PERCENTAGE_SCALE
                || protocol.minimumProtocolFeeRate > protocol.maximumProtocolFeeRate
                || protocol.maximumProtocolFeeRate > MAX_TOTAL_FEE_RATE
        ) revert InvalidProtocolFeeConfiguration();
    }

    function validateTax(TaxConfiguration memory tax, TaxPolicy memory policy, uint256 supply)
        internal
        pure
        returns (bool dividendsEnabled)
    {
        validatePolicy(policy, supply);
        TaxFeeBounds memory bounds = policy.taxFeeBounds;
        if (
            tax.buyTaxRate < bounds.minimumBuyTaxRate || tax.buyTaxRate > bounds.maximumBuyTaxRate
                || tax.sellTaxRate < bounds.minimumSellTaxRate || tax.sellTaxRate > bounds.maximumSellTaxRate
        ) revert InvalidTaxConfiguration();
        uint256 buyRemainder = uint256(tax.buyTaxRate) * PERCENTAGE_SCALE
            - protocolRateNumerator(tax.buyTaxRate, policy.protocolFeeConfiguration);
        uint256 sellRemainder = uint256(tax.sellTaxRate) * PERCENTAGE_SCALE
            - protocolRateNumerator(tax.sellTaxRate, policy.protocolFeeConfiguration);
        uint256 shares = uint256(tax.creatorAllocationShare) + tax.burnAllocationShare + tax.dividendAllocationShare
            + tax.integratorAllocationShare;
        if (buyRemainder == 0 && sellRemainder == 0) {
            if (shares != 0 || tax.minimumDividendHolding != 0) revert InvalidTaxConfiguration();
            return false;
        }
        if (shares != PERCENTAGE_SCALE) revert InvalidTaxConfiguration();
        dividendsEnabled = tax.dividendAllocationShare != 0;
        if (dividendsEnabled) {
            if (
                tax.minimumDividendHolding < policy.minimumDividendHoldingRequirement
                    || tax.minimumDividendHolding > supply
            ) revert InvalidMinimumDividendHoldingRequirement();
        } else if (tax.minimumDividendHolding != 0) {
            revert InvalidTaxConfiguration();
        }
    }

    /// @dev Denominator is PERCENTAGE_SCALE squared. An admitted zero side bypasses the positive floor.
    function protocolRateNumerator(uint256 totalTaxRate, ProtocolFeeConfiguration memory protocol)
        internal
        pure
        returns (uint256)
    {
        _validateProtocol(protocol);
        if (totalTaxRate > MAX_TOTAL_FEE_RATE) revert InvalidTaxConfiguration();
        if (totalTaxRate == 0) return 0;
        if (totalTaxRate < protocol.minimumProtocolFeeRate) revert InvalidTaxConfiguration();
        return Math.min(
            Math.max(
                totalTaxRate * protocol.protocolTaxShare, uint256(protocol.minimumProtocolFeeRate) * PERCENTAGE_SCALE
            ),
            uint256(protocol.maximumProtocolFeeRate) * PERCENTAGE_SCALE
        );
    }

    function rates(
        uint256 totalTaxRate,
        ProtocolFeeConfiguration memory protocol,
        TaxConfiguration memory tax,
        uint256 surchargeRate
    ) internal pure returns (Rates memory result) {
        if (totalTaxRate > MAX_TOTAL_FEE_RATE || surchargeRate > MAX_TOTAL_FEE_RATE - totalTaxRate) {
            revert InvalidFeeSchedule();
        }
        uint256 protocolNumerator = protocolRateNumerator(totalTaxRate, protocol);
        uint256 remainder = totalTaxRate * PERCENTAGE_SCALE - protocolNumerator;
        result.protocolRate = protocolNumerator * PERCENTAGE_SCALE;
        result.creatorRate = remainder * tax.creatorAllocationShare;
        result.burnRate = remainder * tax.burnAllocationShare;
        result.dividendRate = remainder * tax.dividendAllocationShare;
        result.integratorRate = remainder * tax.integratorAllocationShare;
        result.surchargeRate = surchargeRate * PERCENTAGE_SCALE * PERCENTAGE_SCALE;
        result.quoteRate = result.protocolRate + result.creatorRate + result.dividendRate + result.integratorRate
            + result.surchargeRate;
        if (result.quoteRate + result.burnRate != (totalTaxRate + surchargeRate) * PERCENTAGE_SCALE * PERCENTAGE_SCALE)
        {
            revert InvalidTaxConfiguration();
        }
    }

    function surcharge(
        uint256 normalFeeRate,
        uint256 openingTotalRate,
        uint256 launchTime,
        uint256 duration,
        uint256 timestamp,
        bool enabled
    ) internal pure returns (uint256) {
        if (normalFeeRate > MAX_TOTAL_FEE_RATE || openingTotalRate > MAX_TOTAL_FEE_RATE) {
            revert InvalidFeeSchedule();
        }
        if (!enabled || duration == 0) return 0;
        if (normalFeeRate > openingTotalRate) revert InvalidFeeSchedule();
        if (timestamp <= launchTime) return openingTotalRate - normalFeeRate;
        uint256 elapsed = timestamp - launchTime;
        if (elapsed >= duration) return 0;
        return Math.mulDiv(openingTotalRate - normalFeeRate, duration - elapsed, duration);
    }

    /// @dev Specified input is gross; specified output is net. Exact output has one combined gross-up denominator.
    function specifiedFee(uint256 amount, uint256 specifiedRate, uint256 otherRate, bool exactOutput)
        internal
        pure
        returns (uint256)
    {
        _validateRates(specifiedRate, otherRate);
        if (!exactOutput) return Math.mulDiv(amount, specifiedRate, RATE_SCALE);
        return Math.mulDiv(amount, specifiedRate, RATE_SCALE - specifiedRate - otherRate, Math.Rounding.Ceil);
    }

    /// @dev Gross input minus its own fee enters the pool, whichever leg the user specifies.
    function unspecifiedFee(uint256 poolAmount, uint256 specifiedRate, uint256 unspecifiedRate, bool exactOutput)
        internal
        pure
        returns (uint256)
    {
        _validateRates(specifiedRate, unspecifiedRate);
        if (exactOutput) {
            return Math.mulDiv(poolAmount, unspecifiedRate, RATE_SCALE - unspecifiedRate, Math.Rounding.Ceil);
        }
        return Math.mulDiv(poolAmount, unspecifiedRate, RATE_SCALE - specifiedRate);
    }

    function splitQuoteFee(uint256 amount, Rates memory rate)
        internal
        pure
        returns (
            uint256 protocolAmount,
            uint256 surchargeAmount,
            uint256 creatorAmount,
            uint256 dividendAmount,
            uint256 integratorAmount
        )
    {
        if (amount == 0) return (0, 0, 0, 0, 0);
        if (rate.quoteRate == 0) revert InvalidFeeSchedule();
        protocolAmount = Math.mulDiv(amount, rate.protocolRate, rate.quoteRate);
        surchargeAmount = Math.mulDiv(amount, rate.surchargeRate, rate.quoteRate);
        uint256 remaining = amount - protocolAmount - surchargeAmount;
        uint256 allocationRate = rate.creatorRate + rate.dividendRate + rate.integratorRate;
        if (allocationRate == 0) {
            if (rate.protocolRate != 0) protocolAmount += remaining;
            else surchargeAmount += remaining;
        } else if (rate.dividendRate != 0) {
            creatorAmount = Math.mulDiv(remaining, rate.creatorRate, allocationRate);
            integratorAmount = Math.mulDiv(remaining, rate.integratorRate, allocationRate);
            dividendAmount = remaining - creatorAmount - integratorAmount;
        } else if (rate.creatorRate != 0) {
            integratorAmount = Math.mulDiv(remaining, rate.integratorRate, allocationRate);
            creatorAmount = remaining - integratorAmount;
        } else {
            integratorAmount = remaining;
        }
    }

    function _validateRates(uint256 firstRate, uint256 secondRate) private pure {
        uint256 maximum = MAX_TOTAL_FEE_RATE * PERCENTAGE_SCALE * PERCENTAGE_SCALE;
        if (firstRate > maximum || secondRate > maximum - firstRate) revert InvalidFeeSchedule();
    }
}
