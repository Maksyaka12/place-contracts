// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;

import {PlaceFeeMath} from "../PlaceFeeMath.sol";

/// @notice Owner controls for the swap fee policy. Place fixes the rates (1% fee, 25% of it to the protocol,
///         the rest to the creator side, 99% -> 1% anti-snipe over 20 s); only the protocol fee recipient can
///         change, and only for future launches. o1's setTaxPolicy / setTaxFeeBounds /
///         setProtocolFeeConfiguration / setAntiSnipeConfiguration / setMinimumDividendHoldingRequirement are removed.
interface IPlaceFeeAdmin {
    event TaxPolicyUpdated(uint64 indexed configVersion, PlaceFeeMath.TaxPolicy policy);
    function setProtocolFeeRecipient(address protocolFeeRecipient) external;
    function taxPolicy() external view returns (PlaceFeeMath.TaxPolicy memory);
    function previewTaxConfiguration() external view returns (PlaceFeeMath.TaxConfigurationPreview memory);
}
