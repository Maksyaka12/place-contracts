// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {IO1Staking, VaultId} from "../../interfaces/IO1Staking.sol";

library O1StakingMathLib {
    uint256 internal constant BPS = 10_000;

    function deriveVaultId(address creator, IO1Staking.VaultParams calldata params) internal pure returns (VaultId) {
        return VaultId.wrap(
            keccak256(
                abi.encode(
                    creator,
                    params.stakingToken,
                    params.rewardCurrency,
                    params.startTime,
                    params.epochDuration,
                    params.epochCount,
                    params.rewardPerEpoch,
                    uint8(params.earlyExitMode),
                    params.penaltyBps
                )
            )
        );
    }

    function depositOpenTime(uint64 startTime, uint64 epochDuration) internal pure returns (uint64) {
        return startTime >= epochDuration ? startTime - epochDuration : 0;
    }

    function epochBounds(uint64 startTime, uint64 epochDuration, uint64 epoch)
        internal
        pure
        returns (uint64 start, uint64 end)
    {
        uint256 start256 = uint256(startTime) + uint256(epoch) * epochDuration;
        start = uint64(start256);
        end = uint64(start256 + epochDuration);
    }

    function currentEpochStart(uint64 startTime, uint64 epochDuration, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        uint256 epoch = (timestamp - startTime) / epochDuration;
        return uint256(startTime) + epoch * epochDuration;
    }

    function clampTime(uint64 timestamp, uint64 startTime, uint64 endTime) internal pure returns (uint256) {
        if (timestamp < startTime) return startTime;
        if (timestamp > endTime) return endTime;
        return timestamp;
    }

    function incrementalPenalty(uint256 amount, uint16 penaltyBps, uint16 oldRemainder)
        internal
        pure
        returns (uint256 penalty, uint16 newRemainder)
    {
        uint256 scaledPenalty = amount * penaltyBps + oldRemainder;
        penalty = scaledPenalty / BPS;
        uint256 remainder = scaledPenalty % BPS;
        if (remainder != 0) penalty++;
        if (oldRemainder != 0) penalty--;
        if (penalty > amount || remainder >= BPS) {
            revert IO1Staking.AccountingInvariantBroken();
        }
        newRemainder = uint16(remainder);
    }
}
