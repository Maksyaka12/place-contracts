// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice X (Twitter) account id -> payout wallet, bound once with a signature from the Place verifier.
interface IXRecipientRegistry {
    /// @notice The wallet bound to `xId`, or address(0) if the account has not signed in to Place yet.
    function recipientOf(uint256 xId) external view returns (address);
}
