// SPDX-License-Identifier: MIT
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

    // Place policy, in PERCENTAGE_SCALE units (1e8 = 100%).
    uint32 internal constant PLACE_FEE_RATE = 1_000_000; // Standard: 1% of every swap
    uint32 internal constant MIN_ECONOMY_TAX_RATE = 1_000_000; // Economy: each side 1%..5%
    uint32 internal constant MAX_ECONOMY_TAX_RATE = 5_000_000;
    uint32 internal constant PLACE_PROTOCOL_SHARE = 30_000_000; // 30% of the tax to the platform, 70% to the creator
    uint32 internal constant PLACE_MIN_PROTOCOL_FEE_RATE = 300_000; // protocol cut: at least 0.3% of the swap
    uint32 internal constant PLACE_MAX_PROTOCOL_FEE_RATE = 1_500_000; // and at most 1.5% of the swap
    /// @notice Smallest holder-reward threshold an Economy launch may set (10,000 tokens).
    uint256 internal constant MIN_HOLDER_REWARD_HOLDING = 10_000e18;
    /// @notice Economy reward stream kinds (PlaceRewardsDistributor).
    uint8 internal constant STREAM_HOLDERS = 0;
    uint8 internal constant STREAM_TRADERS = 1;

    /// @notice Id of a launch's own reward stream: the FeeEscrow account the hook credits and the
    ///         PlaceRewardsDistributor stream that collects it.
    function economyStreamId(address token, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, kind));
    }
    uint32 internal constant ANTI_SNIPE_START_FEE_RATE = 99_000_000; // 99% at launch
    uint32 internal constant ANTI_SNIPE_WINDOW_SECONDS = 20; // decays linearly to 1%
    uint256 internal constant NATIVE_LAUNCH_FEE = 0.0005 ether;

    // Base B20: factory precompile, ASSET variant, token decimals.
    address internal constant B20_FACTORY = 0xB20f000000000000000000000000000000000000;
    uint8 internal constant B20_ASSET_VARIANT = 0;
    uint8 internal constant B20_PARAMS_VERSION = 1;
    uint8 internal constant TOKEN_DECIMALS = 18;
    bytes32 internal constant B20_METADATA_ROLE = keccak256("METADATA_ROLE");
}
