// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Claims the caller's dividends from many tax tokens in one call.
interface ITaxDividendClaimHelper {
    struct Claim {
        address token;
        bool unwrapWrappedNative;
    }

    function hook() external view returns (address);
    function factory() external view returns (address);
    function claimDividends(Claim[] calldata claims) external returns (uint256 paidCount, bool[] memory paid);
}
