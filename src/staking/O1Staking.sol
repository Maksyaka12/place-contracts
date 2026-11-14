// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultId} from "./interfaces/IO1Staking.sol";
import {O1StakingRead} from "./staking/O1StakingRead.sol";
import {O1StakingAssetLib} from "./staking/libraries/O1StakingAssetLib.sol";
import {O1StakingMathLib} from "./staking/libraries/O1StakingMathLib.sol";
import {O1StakingObservationLib} from "./staking/libraries/O1StakingObservationLib.sol";

contract O1Staking is Ownable2Step, ReentrancyGuard, O1StakingRead {
    constructor(address initialOwner, uint16 initialFeeBps, address initialFeeRecipient) Ownable(initialOwner) {
        _validateFeeConfig(initialFeeBps, initialFeeRecipient);
        _feeBps = initialFeeBps;
        _feeRecipient = initialFeeRecipient;
        _feeConfigVersion = 1;
        emit FeeConfigUpdated(1, 0, initialFeeBps, address(0), initialFeeRecipient);
    }

    receive() external payable {
        revert VaultFundingMismatch();
    }

    function createVault(VaultParams calldata params, uint64 expectedFeeConfigVersion)
        external
        payable
        override
        nonReentrant
        returns (VaultId vaultId)
    {
        if (expectedFeeConfigVersion != _feeConfigVersion) {
            revert FeeConfigMismatch();
        }
        (uint64 endTime, uint256 totalReward) = _validateVaultParams(params);

        vaultId = O1StakingMathLib.deriveVaultId(msg.sender, params);
        if (_vaults[vaultId].creator != address(0)) revert VaultAlreadyExists();

        O1StakingAssetLib.erc20Balance(params.stakingToken, address(this));

        uint16 currentFeeBps = _feeBps;
        address currentFeeRecipient = _feeRecipient;
        uint64 currentFeeVersion = _feeConfigVersion;
        uint256 protocolFee = Math.mulDiv(totalReward, currentFeeBps, BPS, Math.Rounding.Ceil);
        if (totalReward > type(uint256).max - protocolFee) {
            revert InvalidConfig();
        }
        uint256 totalFunding = totalReward + protocolFee;

        address rewardCurrency = params.rewardCurrency;
        if (rewardCurrency == address(0)) {
            if (msg.value != totalFunding) revert VaultFundingMismatch();
        } else if (msg.value != 0) {
            revert VaultFundingMismatch();
        }
        uint256 oldActual = _actualBalanceBeforeCreate(rewardCurrency);
        uint256 oldAccounted = accounted[rewardCurrency];
        if (oldActual < oldAccounted) revert CurrencyInsolvent();
        if (oldAccounted > type(uint256).max - totalReward) {
            revert AccountingInvariantBroken();
        }
        uint256 newAccounted = oldAccounted + totalReward;

        VaultState storage vault = _vaults[vaultId];
        vault.config = params;
        vault.creator = msg.sender;
        vault.endTime = endTime;
        vault.rewardRemaining = totalReward;
        accounted[rewardCurrency] = newAccounted;

        if (rewardCurrency == address(0)) {
            uint256 balanceBeforeFee = address(this).balance;
            if (balanceBeforeFee != oldActual + msg.value) {
                revert VaultFundingMismatch();
            }
            if (protocolFee != 0) {
                (bool success,) = payable(currentFeeRecipient).call{value: protocolFee}("");
                if (!success) revert ProtocolFeeTransferFailed();
            }
            if (address(this).balance != balanceBeforeFee - protocolFee) {
                revert ProtocolFeeTransferFailed();
            }
            if (address(this).balance != oldActual + totalReward) {
                revert VaultFundingMismatch();
            }
        } else {
            O1StakingAssetLib.pullERC20Exact(rewardCurrency, msg.sender, totalFunding);
            if (protocolFee != 0) {
                O1StakingAssetLib.pushERC20Exact(rewardCurrency, currentFeeRecipient, protocolFee);
            }
            uint256 expectedBalance = oldActual + totalReward;
            if (O1StakingAssetLib.erc20Balance(rewardCurrency, address(this)) != expectedBalance) {
                revert VaultFundingMismatch();
            }
        }

        if (O1StakingAssetLib.actualBalance(rewardCurrency) < newAccounted) {
            revert CurrencyInsolvent();
        }
        emit VaultCreated(
            vaultId,
            msg.sender,
            params.stakingToken,
            rewardCurrency,
            params.startTime,
            params.epochDuration,
            params.epochCount,
            params.rewardPerEpoch,
            params.earlyExitMode,
            params.penaltyBps,
            totalReward,
            protocolFee,
            currentFeeBps,
            currentFeeRecipient,
            currentFeeVersion
        );
    }

    function setFeeConfig(uint16 newFeeBps, address newFeeRecipient) external override onlyOwner nonReentrant {
        _validateFeeConfig(newFeeBps, newFeeRecipient);
        uint16 oldFeeBps = _feeBps;
        address oldFeeRecipient = _feeRecipient;
        if (oldFeeBps == newFeeBps && oldFeeRecipient == newFeeRecipient) {
            revert FeeConfigUnchanged();
        }
        uint64 version = _feeConfigVersion;
        if (version == type(uint64).max) revert FeeConfigVersionOverflow();
        unchecked {
            version++;
        }
        _feeBps = newFeeBps;
        _feeRecipient = newFeeRecipient;
        _feeConfigVersion = version;
        emit FeeConfigUpdated(version, oldFeeBps, newFeeBps, oldFeeRecipient, newFeeRecipient);
    }

    function feeConfig()
        external
        view
        override
        returns (uint16 currentFeeBps, address currentFeeRecipient, uint64 version)
    {
        return (_feeBps, _feeRecipient, _feeConfigVersion);
    }

    function deposit(VaultId vaultId, uint256 amount) external override nonReentrant returns (uint64 lotId) {
        VaultState storage vault = _requireVault(vaultId);
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint192).max) revert AmountOverflow();

        uint256 timestamp = block.timestamp;
        uint64 depositOpenTime = O1StakingMathLib.depositOpenTime(vault.config.startTime, vault.config.epochDuration);
        if (timestamp < depositOpenTime) revert DepositNotOpen();
        if (timestamp >= vault.endTime) revert ProgramEnded();

        UserState storage user = _users[vaultId][msg.sender];
        lotId = user.nextLotId;
        if (lotId == type(uint64).max) revert LotIdOverflow();

        uint192 amount192 = uint192(amount);
        uint192 oldUserBalance = user.totalStaked;
        uint192 oldTotalBalance = vault.totalStaked;
        if (amount192 > type(uint192).max - oldUserBalance || amount192 > type(uint192).max - oldTotalBalance) {
            revert AmountOverflow();
        }
        uint192 newUserBalance = oldUserBalance + amount192;
        uint192 newTotalBalance = oldTotalBalance + amount192;

        address token = vault.config.stakingToken;
        uint256 oldActual = O1StakingAssetLib.erc20Balance(token, address(this));
        uint256 oldAccounted = accounted[token];
        if (oldActual < oldAccounted) revert CurrencyInsolvent();
        if (oldAccounted > type(uint256).max - amount) {
            revert AccountingInvariantBroken();
        }

        uint64 eligibleAt = timestamp < vault.config.startTime ? vault.config.startTime : uint64(timestamp);
        uint256 uncappedUnlockAt = uint256(eligibleAt) + vault.config.epochDuration;
        uint64 unlockAt = uncappedUnlockAt < vault.endTime ? uint64(uncappedUnlockAt) : vault.endTime;

        user.nextLotId = lotId + 1;
        user.totalStaked = newUserBalance;
        vault.totalStaked = newTotalBalance;
        _lots[vaultId][msg.sender][lotId] =
            DepositLot({remainingAmount: amount192, eligibleAt: eligibleAt, unlockAt: unlockAt});
        accounted[token] = oldAccounted + amount;

        uint64 checkpointTime = uint64(timestamp);
        O1StakingObservationLib.write(
            _userObservations[vaultId][msg.sender],
            checkpointTime,
            oldUserBalance,
            newUserBalance,
            vault.config.startTime,
            vault.endTime
        );
        O1StakingObservationLib.write(
            _totalObservations[vaultId],
            checkpointTime,
            oldTotalBalance,
            newTotalBalance,
            vault.config.startTime,
            vault.endTime
        );

        O1StakingAssetLib.pullERC20Exact(token, msg.sender, amount);
        if (O1StakingAssetLib.erc20Balance(token, address(this)) != oldActual + amount) {
            revert UnsupportedTokenBehavior();
        }
        if (O1StakingAssetLib.erc20Balance(token, address(this)) < accounted[token]) revert CurrencyInsolvent();

        emit Deposited(vaultId, msg.sender, lotId, amount, checkpointTime, unlockAt);
    }

    function withdraw(VaultId vaultId, uint64 lotId, uint256 amount, address to) external override nonReentrant {
        uint64[] memory lotIds = new uint64[](1);
        uint256[] memory amounts = new uint256[](1);
        lotIds[0] = lotId;
        amounts[0] = amount;
        _executeWithdrawals(vaultId, lotIds, amounts, to);
    }

    function withdrawLots(VaultId vaultId, uint64[] calldata lotIds, uint256[] calldata amounts, address to)
        external
        override
        nonReentrant
        returns (uint256 totalNet, uint256 totalPenalty)
    {
        return _executeWithdrawals(vaultId, lotIds, amounts, to);
    }

    function claim(VaultId vaultId, uint64[] calldata epochs, address to)
        external
        override
        nonReentrant
        returns (uint256 reward)
    {
        VaultState storage vault = _requireVault(vaultId);
        _validateDestination(to);
        uint256 count = epochs.length;
        if (count == 0) revert InvalidClaimBatch();

        address currency = vault.config.rewardCurrency;
        uint256 oldAccounted = accounted[currency];
        if (O1StakingAssetLib.actualBalance(currency) < oldAccounted) {
            revert CurrencyInsolvent();
        }

        uint256[] memory rewards = new uint256[](count);
        uint64 previous;
        for (uint256 i; i < count; i++) {
            uint64 epoch = epochs[i];
            if (i != 0 && epoch <= previous) revert InvalidClaimBatch();
            previous = epoch;
            _validateClaimEpoch(vault, epoch);
            _setClaimed(vaultId, msg.sender, epoch);

            uint256 epochReward = _rewardForEpoch(vaultId, msg.sender, epoch, vault);
            uint256 paid = epochPaid[vaultId][epoch];
            if (epochReward > uint256(vault.config.rewardPerEpoch) - paid) {
                revert AccountingInvariantBroken();
            }
            epochPaid[vaultId][epoch] = paid + epochReward;
            if (epochReward > vault.rewardRemaining) {
                revert AccountingInvariantBroken();
            }
            vault.rewardRemaining -= epochReward;
            rewards[i] = epochReward;
            reward += epochReward;
        }

        if (reward > oldAccounted) revert AccountingInvariantBroken();
        uint256 newAccounted = oldAccounted - reward;
        accounted[currency] = newAccounted;
        if (reward != 0) {
            O1StakingAssetLib.transferCurrencyOut(currency, to, reward);
        }
        if (O1StakingAssetLib.actualBalance(currency) < newAccounted) {
            revert CurrencyInsolvent();
        }

        for (uint256 i; i < count; i++) {
            emit EpochRewardClaimed(vaultId, epochs[i], msg.sender, rewards[i]);
        }
    }

    function _sendPenaltyExact(address token, uint256 amount) external override {
        if (msg.sender != address(this) || !_reentrancyGuardEntered()) {
            revert OnlySelf();
        }
        O1StakingAssetLib.pushERC20ExactAndRemainSolvent(token, PENALTY_SINK, amount, accounted[token]);
    }

    function _executeWithdrawals(VaultId vaultId, uint64[] memory lotIds, uint256[] memory amounts, address to)
        private
        returns (uint256 totalNet, uint256 totalPenalty)
    {
        VaultState storage vault = _requireVault(vaultId);
        _validateDestination(to);
        uint256 count = lotIds.length;
        if (count == 0 || count != amounts.length) {
            revert InvalidWithdrawBatch();
        }

        address token = vault.config.stakingToken;
        uint256 oldAccounted = accounted[token];
        if (O1StakingAssetLib.erc20Balance(token, address(this)) < oldAccounted) {
            revert CurrencyInsolvent();
        }

        UserState storage user = _users[vaultId][msg.sender];
        WithdrawalContext memory context = _withdrawalContext(vault);
        WithdrawalResult[] memory results = new WithdrawalResult[](count);
        uint16 localRemainder = user.penaltyRemainder;
        uint256 totalAmount;
        uint256 totalForfeited;
        uint64 previousLotId;

        for (uint256 i; i < count; i++) {
            uint64 lotId = lotIds[i];
            if (i != 0 && lotId <= previousLotId) revert InvalidWithdrawBatch();
            previousLotId = lotId;
            (WithdrawalResult memory result, uint16 newRemainder) =
                _prepareLotWithdrawal(vaultId, msg.sender, vault, user, lotId, amounts[i], context, localRemainder);
            localRemainder = newRemainder;
            results[i] = result;
            totalAmount += result.amount;
            totalPenalty += result.penalty;
            totalForfeited += result.forfeitedWeight;
        }

        if (totalPenalty > totalAmount) revert AccountingInvariantBroken();
        totalNet = totalAmount - totalPenalty;
        uint192 oldUserBalance = user.totalStaked;
        uint192 oldTotalBalance = vault.totalStaked;
        if (totalAmount > oldUserBalance || totalAmount > oldTotalBalance) {
            revert AccountingInvariantBroken();
        }
        uint192 newUserBalance = oldUserBalance - uint192(totalAmount);
        uint192 newTotalBalance = oldTotalBalance - uint192(totalAmount);

        for (uint256 i; i < count; i++) {
            WithdrawalResult memory result = results[i];
            _lots[vaultId][msg.sender][result.lotId].remainingAmount = result.remainingAmount;
        }
        user.penaltyRemainder = localRemainder;
        user.totalStaked = newUserBalance;
        vault.totalStaked = newTotalBalance;

        if (context.timestamp < vault.endTime) {
            uint64 checkpointTime = uint64(context.timestamp);
            O1StakingObservationLib.write(
                _userObservations[vaultId][msg.sender],
                checkpointTime,
                oldUserBalance,
                newUserBalance,
                vault.config.startTime,
                vault.endTime
            );
            O1StakingObservationLib.write(
                _totalObservations[vaultId],
                checkpointTime,
                oldTotalBalance,
                newTotalBalance,
                vault.config.startTime,
                vault.endTime
            );
        }
        if (context.active) {
            forfeitedUserWeight[vaultId][msg.sender][context.epoch] += totalForfeited;
            forfeitedTotalWeight[vaultId][context.epoch] += totalForfeited;
        }

        if (totalAmount > oldAccounted) revert AccountingInvariantBroken();
        uint256 newAccounted = oldAccounted - totalAmount;
        accounted[token] = newAccounted;

        if (totalNet != 0) {
            O1StakingAssetLib.pushERC20Exact(token, to, totalNet);
        }
        bool burned = totalPenalty != 0 && _attemptPenaltyBurn(token, totalPenalty);
        if (O1StakingAssetLib.erc20Balance(token, address(this)) < newAccounted) {
            revert CurrencyInsolvent();
        }

        for (uint256 i; i < count; i++) {
            WithdrawalResult memory result = results[i];
            emit Withdrawn(
                vaultId,
                msg.sender,
                result.lotId,
                to,
                result.amount,
                result.remainingAmount,
                result.penalty,
                burned && result.penalty != 0,
                result.forfeitedWeight
            );
        }
    }

    function _prepareLotWithdrawal(
        VaultId vaultId,
        address userAddress,
        VaultState storage vault,
        UserState storage user,
        uint64 lotId,
        uint256 amount,
        WithdrawalContext memory context,
        uint16 oldRemainder
    ) private view returns (WithdrawalResult memory result, uint16 newRemainder) {
        if (lotId >= user.nextLotId) revert LotNotFound();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint192).max) revert AmountOverflow();
        DepositLot storage lot = _lots[vaultId][userAddress][lotId];
        if (amount > lot.remainingAmount) revert InsufficientLotBalance();

        bool isEarly = context.timestamp < lot.unlockAt;
        if (isEarly && vault.config.earlyExitMode == EarlyExitMode.FORBIDDEN) {
            revert EarlyExitForbidden();
        }

        uint256 penalty;
        newRemainder = oldRemainder;
        if (isEarly && vault.config.penaltyBps != 0) {
            (penalty, newRemainder) = O1StakingMathLib.incrementalPenalty(amount, vault.config.penaltyBps, oldRemainder);
        }

        uint256 forfeitedWeight;
        if (context.active) {
            uint256 weightStart = lot.eligibleAt > context.epochStart ? lot.eligibleAt : context.epochStart;
            forfeitedWeight = amount * (context.timestamp - weightStart);
        }

        uint192 amount192 = uint192(amount);
        result = WithdrawalResult({
            lotId: lotId,
            amount: amount192,
            remainingAmount: lot.remainingAmount - amount192,
            penalty: penalty,
            forfeitedWeight: forfeitedWeight
        });
    }

    function _withdrawalContext(VaultState storage vault) private view returns (WithdrawalContext memory context) {
        context.timestamp = block.timestamp;
        if (context.timestamp >= vault.config.startTime && context.timestamp < vault.endTime) {
            context.active = true;
            context.epoch = uint64((context.timestamp - vault.config.startTime) / vault.config.epochDuration);
            context.epochStart = O1StakingMathLib.currentEpochStart(
                vault.config.startTime, vault.config.epochDuration, context.timestamp
            );
        }
    }

    function _attemptPenaltyBurn(address token, uint256 amount) private returns (bool success) {
        bytes memory callData = abi.encodeCall(this._sendPenaltyExact, (token, amount));
        address target = address(this);
        uint256 gasLimit = PENALTY_BURN_GAS;
        assembly ("memory-safe") {
            success := call(gasLimit, target, 0, add(callData, 0x20), mload(callData), 0, 0)
        }
    }

    function _setClaimed(VaultId vaultId, address userAddress, uint64 epoch) private {
        uint256 word = uint256(epoch) >> 8;
        uint256 bit = uint256(1) << uint8(epoch & 255);
        uint256 bitmap = _claimedBitmap[vaultId][userAddress][word];
        if ((bitmap & bit) != 0) revert EpochAlreadyClaimed();
        _claimedBitmap[vaultId][userAddress][word] = bitmap | bit;
    }

    function _validateVaultParams(VaultParams calldata params)
        private
        view
        returns (uint64 endTime, uint256 totalReward)
    {
        if (
            params.stakingToken == address(0) || params.stakingToken == address(this)
                || params.rewardCurrency == address(this) || params.epochDuration < MIN_EPOCH_DURATION
                || params.epochDuration > MAX_EPOCH_DURATION || params.epochCount == 0
                || params.epochCount > MAX_EPOCH_COUNT || params.rewardPerEpoch == 0
                || params.startTime < block.timestamp
        ) revert InvalidConfig();
        if (
            (params.earlyExitMode == EarlyExitMode.FORBIDDEN && params.penaltyBps != 0)
                || (params.earlyExitMode == EarlyExitMode.ALLOWED && params.penaltyBps >= BPS)
        ) revert InvalidConfig();

        uint256 duration = uint256(params.epochDuration) * params.epochCount;
        uint256 endTime256 = uint256(params.startTime) + duration;
        if (endTime256 > type(uint64).max) revert InvalidConfig();
        endTime = uint64(endTime256);
        totalReward = uint256(params.rewardPerEpoch) * params.epochCount;
    }

    function _validateFeeConfig(uint16 feeBps, address feeRecipientAddress) private view {
        if (feeBps > MAX_PROTOCOL_FEE_BPS || feeRecipientAddress == address(0) || feeRecipientAddress == address(this))
        {
            revert InvalidFeeConfig();
        }
    }

    function _actualBalanceBeforeCreate(address currency) private view returns (uint256) {
        if (currency == address(0)) return address(this).balance - msg.value;
        return O1StakingAssetLib.erc20Balance(currency, address(this));
    }
}
