// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";
import {ITaxDividendClaimHelper} from "./interfaces/ITaxDividendClaimHelper.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FeeEscrow} from "../FeeEscrow.sol";

interface ITaxDividendWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title TaxDividend
/// @notice Per-launch dividend tracker, deployed as a clone. Holders earn the launch's dividend fees in
///         proportion to their balance through a reward-per-share accumulator with per-holder reward debt.
/// @dev The owner is always the suite factory. Emergency withdrawal may intentionally remove unpaid reward
///      backing.
contract TaxDividend is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 public constant MAX_BATCH_SIZE = TaxSuiteConstants.MAX_BATCH_SIZE;
    address public constant BURN_SINK = TaxSuiteConstants.BURN_SINK;
    address public immutable wrappedNative;
    address public immutable claimHelper;

    struct Initialization {
        address factory;
        address taxToken;
        address quoteToken;
        address hook;
        FeeEscrow feeEscrow;
        uint256 minimumDividendHolding;
        address[] defaultExclusions;
    }

    struct UserInfo {
        uint256 share;
        uint256 rewardDebt;
        /// @dev Settled old-balance earnings; live share accrual is added by withdrawableDividendOf.
        uint256 pendingBalance;
    }

    address private _owner;
    address public rewardToken;
    address public taxToken;
    address public quoteToken;
    address public hook;
    FeeEscrow public feeEscrow;
    IPoolManager public poolManager;
    uint256 public minimumDividendHolding;
    uint256 internal magnifiedDividendPerShare;
    uint256 public totalShares;
    uint256 public totalDividendsAllocated;
    uint256 public totalDividendsWithdrawn;
    uint256 public totalDividendFeesAccrued;
    uint256 public totalBackingReplenished;
    mapping(address holder => UserInfo info) public userInfo;
    mapping(address holder => uint256 amount) public withdrawnDividends;
    mapping(address holder => bool excluded) public excludedFromDividends;
    mapping(address holder => bool excluded) public mandatoryExclusion;
    mapping(address holder => address receiver) internal _dividendReceiver;
    address private _recoveryRecipient;
    uint8 private _recoveryCallbacks;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidBatch();
    error MandatoryExclusion();
    error AlreadyExcluded();
    error NotExcluded();
    error PoolManagerUnlocked();
    error InsufficientAssetBalance();
    error NoEligibleDividendShares();
    error InsufficientRewardBacking(uint256 required, uint256 available);

    event OwnershipInitialized(address indexed factory);
    event DividendShareChanged(address indexed taxToken, address indexed holder, uint256 share, uint256 totalShares);
    event DividendPendingBalanceChanged(address indexed taxToken, address indexed holder, uint256 pendingBalance);
    event DividendRewardDebtChanged(address indexed taxToken, address indexed holder, uint256 rewardDebt);
    event DividendsAllocated(address indexed taxToken, uint256 amount, uint256 magnifiedDividendPerShare);
    event DividendPaid(address indexed taxToken, address indexed holder, address indexed receiver, uint256 amount);
    event DividendReceiverSet(
        address indexed taxToken, address indexed holder, address receiver, address previousReceiver
    );
    event DividendAddressExcluded(address indexed taxToken, address indexed holder);
    event DividendAddressUnexcluded(address indexed taxToken, address indexed holder);
    event DividendFeeAccrued(address indexed taxToken, uint256 amount, uint256 totalAccrued);
    event VoluntaryDividendDeposited(address indexed depositor, uint256 amount);
    event DividendBackingReplenished(address indexed funder, uint256 amount);
    event EmergencyWithdrawal(address indexed asset, address indexed recipient, uint256 amount);

    constructor(address wrappedNativeAddress, address dividendClaimHelper) {
        if (wrappedNativeAddress == address(0) || wrappedNativeAddress.code.length == 0) revert InvalidConfiguration();
        if (dividendClaimHelper.code.length == 0) revert InvalidConfiguration();
        wrappedNative = wrappedNativeAddress;
        claimHelper = dividendClaimHelper;
        _disableInitializers();
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert Unauthorized();
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function initialize(Initialization calldata configuration) external initializer nonReentrant {
        if (
            msg.sender != configuration.factory || configuration.factory.code.length == 0
                || configuration.taxToken.code.length == 0 || configuration.hook.code.length == 0
                || address(configuration.feeEscrow).code.length == 0
                || configuration.feeEscrow.hook() != configuration.hook
                || ITaxDividendClaimHelper(claimHelper).factory() != configuration.factory
                || ITaxDividendClaimHelper(claimHelper).hook() != configuration.hook
                || configuration.defaultExclusions.length > MAX_BATCH_SIZE
        ) revert InvalidConfiguration();
        uint256 supply = IERC20(configuration.taxToken).totalSupply();
        if (supply == 0 || supply >= MAGNITUDE || configuration.minimumDividendHolding > supply) {
            revert InvalidConfiguration();
        }
        address reward = _rewardTokenForQuote(configuration.quoteToken);
        if (reward.code.length == 0 || reward == configuration.taxToken) revert InvalidConfiguration();
        _owner = configuration.factory;
        taxToken = configuration.taxToken;
        quoteToken = configuration.quoteToken;
        rewardToken = reward;
        hook = configuration.hook;
        feeEscrow = configuration.feeEscrow;
        poolManager = configuration.feeEscrow.poolManager();
        minimumDividendHolding = configuration.minimumDividendHolding;
        _excludeMandatory(address(0));
        _excludeMandatory(BURN_SINK);
        _excludeMandatory(address(this));
        _excludeMandatory(taxToken);
        _excludeMandatory(_owner);
        _excludeMandatory(hook);
        _excludeMandatory(address(feeEscrow));
        _excludeMandatory(address(poolManager));
        _excludeMandatory(claimHelper);
        for (uint256 i; i < configuration.defaultExclusions.length; ++i) {
            address account = configuration.defaultExclusions[i];
            if (!excludedFromDividends[account]) {
                excludedFromDividends[account] = true;
                emit DividendAddressExcluded(taxToken, account);
            }
        }
        emit OwnershipInitialized(_owner);
    }

    /// @notice Record the bound token's raw holder balance; eligibility is applied internally.
    function setShare(address holder, uint256 share) external {
        if (msg.sender != taxToken) revert Unauthorized();
        if (_reentrancyGuardEntered()) {
            address expectedHolder = _recoveryRecipient;
            if (_recoveryCallbacks == 2) expectedHolder = address(this);
            if (_recoveryCallbacks == 0 || holder != expectedHolder) revert ReentrancyGuardReentrantCall();
            --_recoveryCallbacks;
            if (share != IERC20(taxToken).balanceOf(holder)) revert InvalidConfiguration();
            _updateShare(holder, share);
            return;
        }
        _setShareGuarded(holder, share);
    }

    function _setShareGuarded(address holder, uint256 share) private nonReentrant {
        _updateShare(holder, share);
    }

    function _updateShare(address holder, uint256 share) private {
        if (excludedFromDividends[holder]) return;
        if (share < minimumDividendHolding) share = 0;
        _setShare(holder, share);
    }

    function refreshShares(address[] calldata holders) external onlyOwner nonReentrant {
        if (holders.length > MAX_BATCH_SIZE) revert InvalidBatch();
        for (uint256 i; i < holders.length; ++i) {
            _refreshShare(holders[i]);
        }
    }

    function excludeAddress(address holder) external onlyOwner nonReentrant {
        if (excludedFromDividends[holder]) revert AlreadyExcluded();
        _setShare(holder, 0);
        excludedFromDividends[holder] = true;
        emit DividendAddressExcluded(taxToken, holder);
    }

    function unexcludeAddress(address holder) external onlyOwner nonReentrant {
        if (mandatoryExclusion[holder]) revert MandatoryExclusion();
        if (!excludedFromDividends[holder]) revert NotExcluded();
        excludedFromDividends[holder] = false;
        _refreshShare(holder);
        emit DividendAddressUnexcluded(taxToken, holder);
    }

    function setDividendReceiver(address holder, address receiver) external onlyOwner nonReentrant {
        if (holder == address(0)) revert InvalidConfiguration();
        address previous = _dividendReceiver[holder];
        _dividendReceiver[holder] = receiver;
        emit DividendReceiverSet(taxToken, holder, receiver, previous);
    }

    function receiverOf(address holder) public view returns (address receiver) {
        receiver = _dividendReceiver[holder];
        if (receiver == address(0)) receiver = holder;
    }

    function notifyDividendFee(uint256 amount) external nonReentrant {
        if (msg.sender != hook) revert Unauthorized();
        if (amount == 0) return;
        if (totalShares == 0) revert NoEligibleDividendShares();
        totalDividendFeesAccrued += amount;
        emit DividendFeeAccrued(taxToken, amount, totalDividendFeesAccrued);
        _allocate(amount);
    }

    function pendingDividendFunding() public view returns (uint256) {
        return feeEscrow.owed(address(this), quoteToken);
    }

    /// @notice Accounting backing, including unredeemed claims; external transfers may still fail.
    function availableRewardBacking() public view returns (uint256) {
        return _heldRewardBacking() + pendingDividendFunding();
    }

    /// @notice Conservative accounting backing, including allocation rounding residue; not an enumerable claim sum.
    function requiredRewardBacking() public view returns (uint256) {
        return totalDividendsAllocated - totalDividendsWithdrawn;
    }

    function rewardBackingDeficit() external view returns (uint256) {
        uint256 backing = requiredRewardBacking();
        uint256 balance = availableRewardBacking();
        if (backing > balance) return backing - balance;
        return 0;
    }

    function depositDividends(uint256 amount) external nonReentrant returns (bool success) {
        _requireSettled();
        if (amount == 0 || totalShares == 0) return false;
        uint256 received = _receiveReward(amount);
        if (received == 0) return false;
        _allocate(received);
        emit VoluntaryDividendDeposited(msg.sender, received);
        return true;
    }

    /// @notice Restore withdrawn backing without creating new dividend entitlements.
    function replenishBacking(uint256 amount) external nonReentrant returns (uint256 received) {
        _requireSettled();
        if (amount == 0) return 0;
        received = _receiveReward(amount);
        totalBackingReplenished += received;
        emit DividendBackingReplenished(msg.sender, received);
    }

    function withdrawDividends() external nonReentrant returns (bool paid) {
        return _withdrawDividendOfUser(msg.sender, true);
    }

    function withdrawDividendsFor(address holder, bool unwrapWrappedNative) external nonReentrant returns (bool paid) {
        return _withdrawDividendOfUser(holder, unwrapWrappedNative);
    }

    /// @notice Recorded unpaid entitlement, including amounts temporarily blocked by exclusion.
    function withdrawableDividendOf(address holder) public view returns (uint256 amount) {
        UserInfo storage info = userInfo[holder];
        uint256 accrued = _accruedFor(info.share, magnifiedDividendPerShare);
        amount = info.pendingBalance;
        if (accrued > info.rewardDebt) amount += accrued - info.rewardDebt;
    }

    function accumulativeDividendOf(address holder) public view returns (uint256) {
        return withdrawableDividendOf(holder) + withdrawnDividends[holder];
    }

    function getMagnifiedDividendPerShare() public view returns (uint256) {
        return magnifiedDividendPerShare;
    }

    /// @notice Fixed-owner administrative withdrawal; amount zero selects the full held asset balance.
    /// @dev May remove unpaid reward backing. Recorded entitlements and allocation counters do not change.
    function emergencyWithdraw(address asset, uint256 amount, address recipient) external onlyOwner nonReentrant {
        if (recipient == address(0)) revert InvalidConfiguration();
        uint256 balance;
        if (asset == address(0)) balance = address(this).balance;
        else balance = IERC20(asset).balanceOf(address(this));
        if (amount == 0) amount = balance;
        if (amount > balance) revert InsufficientAssetBalance();
        if (asset == address(0)) {
            Address.sendValue(payable(recipient), amount);
        } else if (asset == taxToken) {
            // Only this transfer's authenticated sender/recipient notifications may enter the held guard.
            _recoveryRecipient = recipient;
            _recoveryCallbacks = 2;
            if (recipient == address(this)) _recoveryCallbacks = 1;
            IERC20(asset).safeTransfer(recipient, amount);
            if (_recoveryCallbacks != 0) revert ReentrancyGuardReentrantCall();
            delete _recoveryRecipient;
        } else {
            IERC20(asset).safeTransfer(recipient, amount);
        }
        emit EmergencyWithdrawal(asset, recipient, amount);
    }

    function _heldRewardBacking() internal view returns (uint256 balance) {
        balance = IERC20(rewardToken).balanceOf(address(this));
        if (quoteToken == address(0)) balance += address(this).balance;
    }

    function _rewardTokenForQuote(address quote) internal view virtual returns (address) {
        if (quote == address(0)) return wrappedNative;
        return quote;
    }

    function _ensureClaimBacking(uint256 amount) internal {
        if (_heldRewardBacking() < amount && pendingDividendFunding() != 0) {
            feeEscrow.claimFor(address(this), quoteToken);
        }
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (quoteToken == address(0)) {
            if (balance < amount) {
                uint256 nativeAmount = Math.min(address(this).balance, amount - balance);
                if (nativeAmount != 0) {
                    ITaxDividendWrappedNative(wrappedNative).deposit{value: nativeAmount}();
                    balance = IERC20(rewardToken).balanceOf(address(this));
                }
            }
        }
        if (balance < amount) revert InsufficientRewardBacking(amount, balance);
    }

    function _allocate(uint256 amount) internal {
        magnifiedDividendPerShare += Math.mulDiv(amount, MAGNITUDE, totalShares);
        totalDividendsAllocated += amount;
        emit DividendsAllocated(taxToken, amount, magnifiedDividendPerShare);
    }

    function _receiveReward(uint256 amount) internal returns (uint256) {
        IERC20 reward = IERC20(rewardToken);
        uint256 beforeBalance = reward.balanceOf(address(this));
        reward.safeTransferFrom(msg.sender, address(this), amount);
        return reward.balanceOf(address(this)) - beforeBalance;
    }

    function _requireSettled() internal view {
        if (poolManager.isUnlocked()) revert PoolManagerUnlocked();
    }

    function _excludeMandatory(address holder) internal {
        mandatoryExclusion[holder] = true;
        excludedFromDividends[holder] = true;
        emit DividendAddressExcluded(taxToken, holder);
    }

    function _refreshShare(address holder) internal {
        if (excludedFromDividends[holder]) return;
        uint256 share = IERC20(taxToken).balanceOf(holder);
        _updateShare(holder, share);
    }

    function _accruedFor(uint256 share, uint256 mdps) internal pure returns (uint256) {
        return Math.mulDiv(share, mdps, MAGNITUDE);
    }

    function _debtFor(uint256 share, uint256 mdps) internal pure returns (uint256) {
        return Math.mulDiv(share, mdps, MAGNITUDE, Math.Rounding.Ceil);
    }

    function _setShare(address holder, uint256 newShare) internal {
        UserInfo storage info = userInfo[holder];
        uint256 currentShare = info.share;
        if (newShare == currentShare) return;
        uint256 mdps = magnifiedDividendPerShare;
        uint256 currentDebt;
        if (currentShare != 0) currentDebt = info.rewardDebt;
        if (currentShare > 0) {
            uint256 accrued = _accruedFor(currentShare, mdps);
            if (accrued > currentDebt) {
                info.pendingBalance += accrued - currentDebt;
                emit DividendPendingBalanceChanged(taxToken, holder, info.pendingBalance);
            }
        }
        if (newShare > currentShare) totalShares += newShare - currentShare;
        else totalShares -= currentShare - newShare;
        info.share = newShare;
        uint256 newDebt = _debtFor(newShare, mdps);
        if (newDebt != currentDebt) {
            info.rewardDebt = newDebt;
            emit DividendRewardDebtChanged(taxToken, holder, newDebt);
        }
        emit DividendShareChanged(taxToken, holder, newShare, totalShares);
    }

    function _withdrawDividendOfUser(address holder, bool unwrapWrappedNative) internal returns (bool paid) {
        _requireClaimAuthorization(holder);
        _requireSettled();
        if (excludedFromDividends[holder]) return false;
        uint256 amount = withdrawableDividendOf(holder);
        if (amount == 0) return false;
        address receiver = receiverOf(holder);
        _ensureClaimBacking(amount);
        UserInfo storage info = userInfo[holder];
        uint256 newDebt = _debtFor(info.share, magnifiedDividendPerShare);
        if (newDebt != info.rewardDebt) {
            info.rewardDebt = newDebt;
            emit DividendRewardDebtChanged(taxToken, holder, newDebt);
        }
        if (info.pendingBalance != 0) {
            info.pendingBalance = 0;
            emit DividendPendingBalanceChanged(taxToken, holder, 0);
        }
        withdrawnDividends[holder] += amount;
        totalDividendsWithdrawn += amount;
        _payReward(receiver, amount, unwrapWrappedNative);
        emit DividendPaid(taxToken, holder, receiver, amount);
        return true;
    }

    function _payReward(address receiver, uint256 amount, bool unwrapWrappedNative) internal virtual {
        if (rewardToken == wrappedNative && unwrapWrappedNative) {
            ITaxDividendWrappedNative(wrappedNative).withdraw(amount);
            Address.sendValue(payable(receiver), amount);
        } else {
            IERC20(rewardToken).safeTransfer(receiver, amount);
        }
    }

    function _requireClaimAuthorization(address holder) internal view {
        if (msg.sender != holder && msg.sender != claimHelper) revert Unauthorized();
    }

    receive() external payable {}
}
