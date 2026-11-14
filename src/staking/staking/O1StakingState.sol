// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {IO1Staking, VaultId} from "../interfaces/IO1Staking.sol";

abstract contract O1StakingState is IO1Staking {
    uint256 public constant override BPS = 10_000;
    uint64 public constant override MIN_EPOCH_DURATION = 1 days;
    uint64 public constant override MAX_EPOCH_DURATION = 365 days;
    uint64 public constant override MAX_EPOCH_COUNT = 50_000;
    uint16 public constant override MAX_PROTOCOL_FEE_BPS = 10_000;
    address public constant override PENALTY_SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant override PENALTY_BURN_GAS = 100_000;

    struct UserState {
        uint64 nextLotId;
        uint192 totalStaked;
        uint16 penaltyRemainder;
    }

    struct Observation {
        uint64 timestamp;
        uint192 balance;
        uint256 cumulativeTokenSeconds;
    }

    struct WithdrawalResult {
        uint64 lotId;
        uint192 amount;
        uint192 remainingAmount;
        uint256 penalty;
        uint256 forfeitedWeight;
    }

    struct WithdrawalContext {
        uint256 timestamp;
        uint64 epoch;
        uint256 epochStart;
        bool active;
    }

    address internal _feeRecipient;
    uint16 internal _feeBps;
    uint64 internal _feeConfigVersion;

    mapping(VaultId => VaultState) internal _vaults;
    mapping(VaultId => mapping(address => UserState)) internal _users;
    mapping(VaultId => mapping(address => mapping(uint64 => DepositLot))) internal _lots;

    mapping(VaultId => Observation[]) internal _totalObservations;
    mapping(VaultId => mapping(address => Observation[])) internal _userObservations;

    mapping(VaultId => mapping(uint64 => uint256)) public override forfeitedTotalWeight;
    mapping(VaultId => mapping(address => mapping(uint64 => uint256))) public override forfeitedUserWeight;
    mapping(VaultId => mapping(uint64 => uint256)) public override epochPaid;
    mapping(VaultId => mapping(address => mapping(uint256 => uint256))) internal _claimedBitmap;

    mapping(address => uint256) public override accounted;

    function _requireVault(VaultId vaultId) internal view returns (VaultState storage vault) {
        vault = _vaults[vaultId];
        if (vault.creator == address(0)) revert VaultNotFound();
    }

    function _validateDestination(address to) internal view {
        if (to == address(0) || to == address(this)) revert ZeroDestination();
    }
}
