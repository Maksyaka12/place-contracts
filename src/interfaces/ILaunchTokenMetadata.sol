// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;

/// @notice Metadata updates a launch token accepts from its factory, for launches with editable metadata.
interface ILaunchTokenMetadata {
    function updateName(string calldata newName) external;
    function updateContractURI(string calldata newContractURI) external;
    function updateExtraMetadata(string calldata metadataKey, string calldata metadataValue) external;
}
