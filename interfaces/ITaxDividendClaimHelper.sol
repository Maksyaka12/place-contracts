// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITaxDividendClaimHelper {
    struct Claim {
        address token;
        bool unwrapWrappedNative;
    }

    function hook() external view returns (address);
    function factory() external view returns (address);
    function claimDividends(Claim[] calldata claims) external returns (uint256 paidCount, bool[] memory paid);
}
