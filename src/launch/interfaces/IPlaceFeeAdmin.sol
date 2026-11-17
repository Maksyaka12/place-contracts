// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlaceFeeMath} from "../PlaceFeeMath.sol";

/// @notice Owner controls for the swap fee policy. Place fixes the rates (Standard 1%; Economy 1%..5% per side;
///         30% of the tax to the protocol, at least 0.3% and at most 1.5% of the swap; 99% -> tax anti-snipe over
///         20 s). Only the protocol fee recipient can change, and only for future launches.
interface IPlaceFeeAdmin {
    event TaxPolicyUpdated(uint64 indexed configVersion, PlaceFeeMath.TaxPolicy policy);
    function setProtocolFeeRecipient(address protocolFeeRecipient) external;
    function taxPolicy() external view returns (PlaceFeeMath.TaxPolicy memory);
}
