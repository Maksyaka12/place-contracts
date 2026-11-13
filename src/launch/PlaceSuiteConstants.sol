// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;

/// @notice Shared compile-time constants. Contracts expose some of them as public constants.
library PlaceSuiteConstants {
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

    // Place policy (LAUNCH.md decisions #2, #3, #12), in PERCENTAGE_SCALE units (1e8 = 100%).
    uint32 internal constant PLACE_FEE_RATE = 1_000_000; // 1% of every swap
    uint32 internal constant PLACE_PROTOCOL_SHARE = 25_000_000; // 25% of the fee to the platform
    uint32 internal constant PLACE_PROTOCOL_FEE_RATE = 250_000; // = 0.25% of the swap (min = max)
    uint32 internal constant ANTI_SNIPE_START_FEE_RATE = 99_000_000; // 99% at launch
    uint32 internal constant ANTI_SNIPE_WINDOW_SECONDS = 20; // decays linearly to 1%
    uint256 internal constant NATIVE_LAUNCH_FEE = 0.0005 ether;
}
