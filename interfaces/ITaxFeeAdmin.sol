// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TaxFeeMath} from "../TaxFeeMath.sol";

/// @notice One inclusive tax policy, with atomic complete and focused future-launch updates.
interface ITaxFeeAdmin {
    event TaxPolicyUpdated(uint64 indexed configVersion, TaxFeeMath.TaxPolicy policy);
    function setTaxPolicy(TaxFeeMath.TaxPolicy calldata policy) external;
    function setTaxFeeBounds(TaxFeeMath.TaxFeeBounds calldata bounds) external;
    function setProtocolFeeConfiguration(TaxFeeMath.ProtocolFeeConfiguration calldata configuration) external;
    function setAntiSnipeConfiguration(TaxFeeMath.AntiSnipeConfiguration calldata configuration) external;
    function setMinimumDividendHoldingRequirement(uint256 minimumHolding) external;
    function taxPolicy() external view returns (TaxFeeMath.TaxPolicy memory);
    function previewTaxConfiguration(TaxFeeMath.TaxConfiguration calldata configuration)
        external
        view
        returns (TaxFeeMath.TaxConfigurationPreview memory);
}
