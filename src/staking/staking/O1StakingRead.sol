// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultId} from "../interfaces/IO1Staking.sol";
import {O1StakingState} from "./O1StakingState.sol";
import {O1StakingMathLib} from "./libraries/O1StakingMathLib.sol";
import {O1StakingObservationLib} from "./libraries/O1StakingObservationLib.sol";

abstract contract O1StakingRead is O1StakingState {
    function deriveVaultId(address creator, VaultParams calldata params)
        external
        pure
        override
        returns (VaultId vaultId)
    {
        return O1StakingMathLib.deriveVaultId(creator, params);
    }

    function previewClaim(VaultId vaultId, address userAddress, uint64[] calldata epochs)
        external
        view
        override
        returns (uint256 reward)
    {
        VaultState storage vault = _requireVault(vaultId);
        uint256 count = epochs.length;
        if (count == 0) revert InvalidClaimBatch();
        uint64 previous;
        for (uint256 i; i < count; i++) {
            uint64 epoch = epochs[i];
            if (i != 0 && epoch <= previous) revert InvalidClaimBatch();
            previous = epoch;
            _validateClaimEpoch(vault, epoch);
            if (_isClaimed(vaultId, userAddress, epoch)) {
                revert EpochAlreadyClaimed();
            }
            uint256 epochReward = _rewardForEpoch(vaultId, userAddress, epoch, vault);
            uint256 paid = epochPaid[vaultId][epoch];
            if (epochReward > uint256(vault.config.rewardPerEpoch) - paid) {
                revert AccountingInvariantBroken();
            }
            reward += epochReward;
        }
    }

    function previewWithdraw(VaultId vaultId, address userAddress, uint64 lotId, uint256 amount)
        external
        view
        override
        returns (uint256 net, uint256 penalty, uint256 forfeitedWeight, bool isEarly)
    {
        VaultState storage vault = _requireVault(vaultId);
        UserState storage user = _users[vaultId][userAddress];
        if (lotId >= user.nextLotId) revert LotNotFound();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint192).max) revert AmountOverflow();
        DepositLot storage lot = _lots[vaultId][userAddress][lotId];
        if (amount > lot.remainingAmount) revert InsufficientLotBalance();

        uint256 timestamp = block.timestamp;
        isEarly = timestamp < lot.unlockAt;
        if (isEarly && vault.config.earlyExitMode == EarlyExitMode.FORBIDDEN) {
            revert EarlyExitForbidden();
        }
        if (isEarly && vault.config.penaltyBps != 0) {
            (penalty,) = O1StakingMathLib.incrementalPenalty(amount, vault.config.penaltyBps, user.penaltyRemainder);
        }
        if (timestamp >= vault.config.startTime && timestamp < vault.endTime) {
            uint256 epochStart =
                O1StakingMathLib.currentEpochStart(vault.config.startTime, vault.config.epochDuration, timestamp);
            uint256 weightStart = lot.eligibleAt > epochStart ? lot.eligibleAt : epochStart;
            forfeitedWeight = amount * (timestamp - weightStart);
        }
        net = amount - penalty;
    }

    function getVault(VaultId vaultId)
        external
        view
        override
        returns (VaultState memory vault, uint64 depositOpenTime)
    {
        VaultState storage stored = _requireVault(vaultId);
        vault = stored;
        depositOpenTime = O1StakingMathLib.depositOpenTime(stored.config.startTime, stored.config.epochDuration);
    }

    function getUserState(VaultId vaultId, address userAddress)
        external
        view
        override
        returns (uint64 nextLotId, uint192 totalStaked, uint16 penaltyRemainder)
    {
        _requireVault(vaultId);
        UserState storage user = _users[vaultId][userAddress];
        return (user.nextLotId, user.totalStaked, user.penaltyRemainder);
    }

    function isClaimed(VaultId vaultId, address userAddress, uint64 epoch)
        external
        view
        override
        returns (bool claimed)
    {
        VaultState storage vault = _requireVault(vaultId);
        if (epoch >= vault.config.epochCount) revert InvalidEpoch();
        return _isClaimed(vaultId, userAddress, epoch);
    }

    function getLot(VaultId vaultId, address userAddress, uint64 lotId)
        external
        view
        override
        returns (DepositLot memory lot)
    {
        _requireVault(vaultId);
        if (lotId >= _users[vaultId][userAddress].nextLotId) {
            revert LotNotFound();
        }
        lot = _lots[vaultId][userAddress][lotId];
    }

    function getUserLots(VaultId vaultId, address userAddress, uint64 cursor, uint64 limit)
        external
        view
        override
        returns (DepositLot[] memory lots, uint64 nextCursor, uint64 totalLots)
    {
        _requireVault(vaultId);
        if (limit == 0) revert InvalidPageSize();
        totalLots = _users[vaultId][userAddress].nextLotId;
        if (cursor > totalLots) revert InvalidLotCursor();

        uint256 remaining = uint256(totalLots) - cursor;
        uint256 count = limit < remaining ? limit : remaining;
        lots = new DepositLot[](count);
        for (uint256 i; i < count; i++) {
            lots[i] = _lots[vaultId][userAddress][uint64(uint256(cursor) + i)];
        }
        nextCursor = uint64(uint256(cursor) + count);
    }

    function epochBounds(VaultId vaultId, uint64 epoch) external view override returns (uint64 start, uint64 end) {
        VaultState storage vault = _requireVault(vaultId);
        if (epoch >= vault.config.epochCount) revert InvalidEpoch();
        return O1StakingMathLib.epochBounds(vault.config.startTime, vault.config.epochDuration, epoch);
    }

    function userCumulativeAt(VaultId vaultId, address userAddress, uint64 timestamp)
        external
        view
        override
        returns (uint256)
    {
        VaultState storage vault = _requireVault(vaultId);
        return O1StakingObservationLib.cumulativeAt(
            _userObservations[vaultId][userAddress], timestamp, vault.config.startTime, vault.endTime
        );
    }

    function totalCumulativeAt(VaultId vaultId, uint64 timestamp) external view override returns (uint256) {
        VaultState storage vault = _requireVault(vaultId);
        return O1StakingObservationLib.cumulativeAt(
            _totalObservations[vaultId], timestamp, vault.config.startTime, vault.endTime
        );
    }

    function _rewardForEpoch(VaultId vaultId, address userAddress, uint64 epoch, VaultState storage vault)
        internal
        view
        returns (uint256)
    {
        (uint64 start, uint64 end) =
            O1StakingMathLib.epochBounds(vault.config.startTime, vault.config.epochDuration, epoch);
        uint256 userRaw = O1StakingObservationLib.cumulativeAt(
            _userObservations[vaultId][userAddress], end, vault.config.startTime, vault.endTime
        )
        - O1StakingObservationLib.cumulativeAt(
            _userObservations[vaultId][userAddress], start, vault.config.startTime, vault.endTime
        );
        uint256 totalRaw = O1StakingObservationLib.cumulativeAt(
            _totalObservations[vaultId], end, vault.config.startTime, vault.endTime
        )
        - O1StakingObservationLib.cumulativeAt(
            _totalObservations[vaultId], start, vault.config.startTime, vault.endTime
        );
        uint256 userForfeited = forfeitedUserWeight[vaultId][userAddress][epoch];
        uint256 totalForfeited = forfeitedTotalWeight[vaultId][epoch];
        if (userForfeited > userRaw || totalForfeited > totalRaw) {
            revert AccountingInvariantBroken();
        }
        uint256 userWeight = userRaw - userForfeited;
        uint256 totalWeight = totalRaw - totalForfeited;
        if (userWeight > totalWeight) revert AccountingInvariantBroken();
        if (totalWeight == 0) return 0;
        return Math.mulDiv(vault.config.rewardPerEpoch, userWeight, totalWeight);
    }

    function _validateClaimEpoch(VaultState storage vault, uint64 epoch) internal view {
        if (epoch >= vault.config.epochCount) revert InvalidEpoch();
        (, uint64 end) = O1StakingMathLib.epochBounds(vault.config.startTime, vault.config.epochDuration, epoch);
        if (block.timestamp < end) revert EpochNotEnded();
    }

    function _isClaimed(VaultId vaultId, address userAddress, uint64 epoch) internal view returns (bool) {
        uint256 word = uint256(epoch) >> 8;
        uint256 bit = uint256(1) << uint8(epoch & 255);
        return (_claimedBitmap[vaultId][userAddress][word] & bit) != 0;
    }
}
