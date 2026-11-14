// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

/// @notice The part of `PlaceStaking` (o1's `O1Staking`, GPL-3.0-only, `src/staking/`) that creator vaults call.
///         Written from the public ABI; the struct layout matches `IO1Staking.VaultParams`.
interface IPlaceStaking {
    struct VaultParams {
        address stakingToken;
        address rewardCurrency;
        uint64 startTime;
        uint64 epochDuration;
        uint64 epochCount;
        uint192 rewardPerEpoch;
        uint8 earlyExitMode; // 0 = forbidden, 1 = allowed
        uint16 penaltyBps;
    }

    function createVault(VaultParams calldata params, uint64 expectedFeeConfigVersion)
        external
        payable
        returns (bytes32 vaultId);

    function feeConfig() external view returns (uint16 currentFeeBps, address currentFeeRecipient, uint64 version);
}
