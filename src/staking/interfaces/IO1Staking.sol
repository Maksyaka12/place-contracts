// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

type VaultId is bytes32;

interface IO1Staking {
    enum EarlyExitMode {
        FORBIDDEN,
        ALLOWED
    }

    struct VaultParams {
        address stakingToken;
        address rewardCurrency;
        uint64 startTime;
        uint64 epochDuration;
        uint64 epochCount;
        uint192 rewardPerEpoch;
        EarlyExitMode earlyExitMode;
        uint16 penaltyBps;
    }

    struct VaultState {
        VaultParams config;
        address creator;
        uint64 endTime;
        uint192 totalStaked;
        uint256 rewardRemaining;
    }

    struct DepositLot {
        uint192 remainingAmount;
        uint64 eligibleAt;
        uint64 unlockAt;
    }

    error VaultAlreadyExists();
    error VaultNotFound();
    error InvalidConfig();
    error InvalidEpoch();
    error ProgramEnded();
    error DepositNotOpen();
    error ZeroAmount();
    error ZeroDestination();
    error AmountOverflow();
    error LotIdOverflow();
    error VaultFundingMismatch();
    error InvalidFeeConfig();
    error FeeConfigUnchanged();
    error FeeConfigVersionOverflow();
    error FeeConfigMismatch();
    error ProtocolFeeTransferFailed();
    error UnsupportedTokenBehavior();
    error LotNotFound();
    error InsufficientLotBalance();
    error EarlyExitForbidden();
    error EpochNotEnded();
    error EpochAlreadyClaimed();
    error InvalidClaimBatch();
    error InvalidWithdrawBatch();
    error InvalidPageSize();
    error InvalidLotCursor();
    error AccountingInvariantBroken();
    error CurrencyInsolvent();
    error NativeTransferFailed();
    error OnlySelf();

    event FeeConfigUpdated(
        uint64 indexed version, uint16 oldFeeBps, uint16 newFeeBps, address oldFeeRecipient, address newFeeRecipient
    );
    event VaultCreated(
        VaultId indexed vaultId,
        address indexed creator,
        address indexed stakingToken,
        address rewardCurrency,
        uint64 startTime,
        uint64 epochDuration,
        uint64 epochCount,
        uint192 rewardPerEpoch,
        EarlyExitMode earlyExitMode,
        uint16 penaltyBps,
        uint256 totalReward,
        uint256 protocolFee,
        uint16 feeBps,
        address feeRecipient,
        uint64 feeConfigVersion
    );
    event Deposited(
        VaultId indexed vaultId,
        address indexed user,
        uint64 indexed lotId,
        uint256 amount,
        uint64 depositTime,
        uint64 unlockAt
    );
    event Withdrawn(
        VaultId indexed vaultId,
        address indexed user,
        uint64 indexed lotId,
        address to,
        uint256 amount,
        uint256 remainingAmount,
        uint256 penalty,
        bool penaltyBurned,
        uint256 forfeitedWeight
    );
    event EpochRewardClaimed(VaultId indexed vaultId, uint64 indexed epoch, address indexed user, uint256 reward);

    function BPS() external view returns (uint256);

    function MIN_EPOCH_DURATION() external view returns (uint64);

    function MAX_EPOCH_DURATION() external view returns (uint64);

    function MAX_EPOCH_COUNT() external view returns (uint64);

    function MAX_PROTOCOL_FEE_BPS() external view returns (uint16);

    function PENALTY_SINK() external view returns (address);

    function PENALTY_BURN_GAS() external view returns (uint256);

    function forfeitedTotalWeight(VaultId vaultId, uint64 epoch) external view returns (uint256);

    function forfeitedUserWeight(VaultId vaultId, address userAddress, uint64 epoch) external view returns (uint256);

    function epochPaid(VaultId vaultId, uint64 epoch) external view returns (uint256);

    function accounted(address currency) external view returns (uint256);

    function createVault(VaultParams calldata params, uint64 expectedFeeConfigVersion)
        external
        payable
        returns (VaultId vaultId);

    function setFeeConfig(uint16 newFeeBps, address newFeeRecipient) external;

    function feeConfig() external view returns (uint16 currentFeeBps, address currentFeeRecipient, uint64 version);

    function deposit(VaultId vaultId, uint256 amount) external returns (uint64 lotId);

    function withdraw(VaultId vaultId, uint64 lotId, uint256 amount, address to) external;

    function withdrawLots(VaultId vaultId, uint64[] calldata lotIds, uint256[] calldata amounts, address to)
        external
        returns (uint256 totalNet, uint256 totalPenalty);

    function claim(VaultId vaultId, uint64[] calldata epochs, address to) external returns (uint256 reward);

    function previewClaim(VaultId vaultId, address userAddress, uint64[] calldata epochs)
        external
        view
        returns (uint256 reward);

    function previewWithdraw(VaultId vaultId, address userAddress, uint64 lotId, uint256 amount)
        external
        view
        returns (uint256 net, uint256 penalty, uint256 forfeitedWeight, bool isEarly);

    function deriveVaultId(address creator, VaultParams calldata params) external pure returns (VaultId vaultId);

    function getUserState(VaultId vaultId, address userAddress)
        external
        view
        returns (uint64 nextLotId, uint192 totalStaked, uint16 penaltyRemainder);

    function isClaimed(VaultId vaultId, address userAddress, uint64 epoch) external view returns (bool claimed);

    function getVault(VaultId vaultId) external view returns (VaultState memory vault, uint64 depositOpenTime);

    function getLot(VaultId vaultId, address userAddress, uint64 lotId) external view returns (DepositLot memory lot);

    function getUserLots(VaultId vaultId, address userAddress, uint64 cursor, uint64 limit)
        external
        view
        returns (DepositLot[] memory lots, uint64 nextCursor, uint64 totalLots);

    function epochBounds(VaultId vaultId, uint64 epoch) external view returns (uint64 start, uint64 end);

    function userCumulativeAt(VaultId vaultId, address userAddress, uint64 timestamp) external view returns (uint256);

    function totalCumulativeAt(VaultId vaultId, uint64 timestamp) external view returns (uint256);

    function _sendPenaltyExact(address token, uint256 amount) external;
}
