// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Implemented by a contract that can receive a token's creator rights through
///         `safeTransferCreatorRights`. Return `onCreatorRightsReceived.selector` to accept them.
interface ICreatorRightsReceiver {
    function onCreatorRightsReceived(address previousCreator, address token, bytes calldata callbackData)
        external
        payable
        returns (bytes4 selector);
}
