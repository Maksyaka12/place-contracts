// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-token dividend tracker. The token updates holder shares on every balance change, the hook
///         reports dividend fees during swaps, and holders withdraw their earnings.
/// @dev The fees stay in FeeEscrow until a withdrawal needs them, then the tracker redeems them.
interface ITaxDividend {
    function owner() external view returns (address);
    function taxToken() external view returns (address);
    function hook() external view returns (address);
    function claimHelper() external view returns (address);
    function feeEscrow() external view returns (address);
    function poolManager() external view returns (address);
    function rewardToken() external view returns (address);
    function minimumDividendHolding() external view returns (uint256);
    /// @notice Supply the raw launched-token balance; the tracker applies minimum and exclusion rules.
    function setShare(address holder, uint256 share) external;
    function totalShares() external view returns (uint256);
    function notifyDividendFee(uint256 amount) external;
    function pendingDividendFunding() external view returns (uint256);
    function availableRewardBacking() external view returns (uint256);
    function requiredRewardBacking() external view returns (uint256);
    function rewardBackingDeficit() external view returns (uint256);
    function withdrawDividends() external returns (bool paid);
    function withdrawDividendsFor(address holder, bool unwrapWrappedNative) external returns (bool paid);
    function withdrawableDividendOf(address holder) external view returns (uint256);
    function receiverOf(address holder) external view returns (address);
    function excludedFromDividends(address holder) external view returns (bool);
}
