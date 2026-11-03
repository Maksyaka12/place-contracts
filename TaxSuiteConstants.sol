// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared compile-time limits. Public contract getters remain aliases for ABI compatibility.
library TaxSuiteConstants {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PERCENTAGE_SCALE = 100_000_000;
    uint256 internal constant RATE_SCALE = 10 ** 24;
    uint32 internal constant MAX_TOTAL_FEE_RATE = 99_000_000;
    uint256 internal constant MAX_BATCH_SIZE = 64;
    uint256 internal constant MAX_BANDS = 10;
    uint256 internal constant MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH = 4_096;
    uint256 internal constant MIN_SUPPLY = 1_000_000e18;
    uint256 internal constant MAX_SUPPLY = 1_000_000_000_000e18;
    address internal constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
}
