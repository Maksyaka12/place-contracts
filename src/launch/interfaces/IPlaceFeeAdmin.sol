// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;
import {PlaceFeeMath} from "../PlaceFeeMath.sol";

/// @notice Owner controls for the swap fee policy. Every update applies to future launches only. `setTaxPolicy`
///         replaces the whole policy at once; the other setters change one part of it.
interface IPlaceFeeAdmin {
    event TaxPolicyUpdated(uint64 indexed configVersion, PlaceFeeMath.TaxPolicy policy);
    function setTaxPolicy(PlaceFeeMath.TaxPolicy calldata policy) external;
    function setTaxFeeBounds(PlaceFeeMath.TaxFeeBounds calldata bounds) external;
    function setProtocolFeeConfiguration(PlaceFeeMath.ProtocolFeeConfiguration calldata configuration) external;
    function setAntiSnipeConfiguration(PlaceFeeMath.AntiSnipeConfiguration calldata configuration) external;
    function taxPolicy() external view returns (PlaceFeeMath.TaxPolicy memory);
    function previewTaxConfiguration(PlaceFeeMath.TaxConfiguration calldata configuration)
        external
        view
        returns (PlaceFeeMath.TaxConfigurationPreview memory);
}
