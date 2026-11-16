// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of the Place hub (`place-web/contracts/src/PlaceHub.sol`, v1.0.0) that creator vaults use.
///         The vault is the campaign creator, so refunds and non-burned leftovers come back to it.
interface IPlaceHub {
    enum Kind {
        TokenHolders,
        NftHolders
    }

    struct CreateParams {
        Kind kind;
        address target;
        address rewardToken;
        uint128 pool;
        uint64 snapshotAt;
        uint32 claimDuration;
        bool burnLeftover;
        bytes32 rulesHash;
        string rulesURI;
        string metadataURI;
    }

    function config() external view returns (IPlaceConfig);
    function createCampaign(CreateParams calldata p) external payable returns (uint256 id);
    function refundUnpublished(uint256 id) external;
}

/// @notice The part of `PlaceConfig` the vault reads: the hub's fee for a target (5% like every campaign;
///         the vault pays whatever the hub asks out of the community fund).
interface IPlaceConfig {
    function campaignFeeBps(address target) external view returns (uint16);
}
