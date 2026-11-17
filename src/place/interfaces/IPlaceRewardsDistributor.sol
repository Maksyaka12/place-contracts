// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The part of PlaceRewardsDistributor that the launch factory and community vaults call.
interface IPlaceRewardsDistributor {
    enum Kind {
        Holders,
        Traders
    }

    /// @notice The reward streams of one Economy launch, registered by the factory in the launch transaction.
    struct LaunchStreams {
        address token;
        address quote;
        PoolKey poolKey;
        address rewardToken;
        address rewardRegistry;
        bool holders;
        uint256 minHolding;
        bool traders;
        uint256 minDailyVolume;
    }

    /// @notice A stream funded up front for `epochCount` daily epochs (rewards hub, community vaults).
    struct CreateParams {
        address token;
        Kind kind;
        address rewardToken;
        uint64 startEpoch;
        uint64 epochCount;
        uint256 rewardPerEpoch;
        uint256 criterion;
        string metadataURI;
    }

    function factory() external view returns (address);
    function registerLaunch(LaunchStreams calldata streams) external;
    function createStream(CreateParams calldata params) external payable returns (bytes32 streamId);
    function streamFeeBps() external view returns (uint16);
    function currentEpoch() external view returns (uint64);
}
