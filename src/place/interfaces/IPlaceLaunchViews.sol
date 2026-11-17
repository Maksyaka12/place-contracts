// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The FeeEscrow functions Place vaults and the rewards distributor call.
interface IFeeEscrowClaims {
    function owed(address recipient, address currency) external view returns (uint256);
    function accountOwed(address recipient, bytes32 account, address currency) external view returns (uint256);
    function claimFor(address recipient, address currency) external;
    function claimAccount(bytes32 account, address currency) external returns (uint256);
}

/// @notice The factory view vaults use to find the current creator of their launch.
interface ICreatorOf {
    function currentCreatorOf(address token) external view returns (address);
}
