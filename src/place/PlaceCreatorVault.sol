// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IXRecipientRegistry} from "./interfaces/IXRecipientRegistry.sol";
import {IFeeEscrowClaims, ICreatorOf} from "./interfaces/IPlaceLaunchViews.sol";

/// @title PlaceCreatorVault
/// @notice One clone per launch, recorded in the hook as the launch's creator fee recipient; nobody can change
///         that. It receives the creator allocation of every trade (Standard: the whole 70% of the 1% fee; Economy:
///         the creator basket) and splits it, with shares frozen at launch, between X accounts (paid once the
///         account binds a wallet in the XRecipientRegistry) and the creator's payout address (`claim`).
/// @dev    Fees arrive in the launch's quote. `creatorOwed` and `xOwedTotal` are earmarked; anything else the vault
///         holds in the quote (fees just pulled, donations) is booked by the next `collect`.
contract PlaceCreatorVault is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint256 public constant MAX_X_SHARES = 5;

    struct XShare {
        uint256 xId;
        uint16 bps; // of the creator allocation
    }

    struct Initialization {
        address token;
        address quote;
        address feeEscrow;
        XShare[] xShares;
        address xRegistry;
    }

    address public factory;
    IFeeEscrowClaims public feeEscrow;
    address public token;
    address public quote;

    XShare[] internal _xShares;
    IXRecipientRegistry public xRegistry;

    address internal _payoutSetBy;
    address internal _payoutAddress;

    uint256 public creatorOwed;
    uint256 public xOwedTotal;
    mapping(uint256 xId => uint256 amount) public xOwed;

    event Collected(uint256 amount, uint256 toX, uint256 toCreator);
    event CreatorPaid(address indexed payout, uint256 amount);
    event XPaid(uint256 indexed xId, address indexed recipient, uint256 amount);
    event PayoutAddressSet(address indexed creator, address indexed payout);

    error NotCreator();
    error InvalidConfig();
    error XNotBound(uint256 xId);
    error NothingToPay();
    error NativeTransferFailed();

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Called once by the factory in the launch transaction, before the hook registers the pool.
    function initialize(Initialization calldata init) external initializer {
        factory = msg.sender;
        if (init.xShares.length > MAX_X_SHARES) revert InvalidConfig();
        if (init.xShares.length != 0 && init.xRegistry == address(0)) revert InvalidConfig();
        uint256 xSum;
        for (uint256 i = 0; i < init.xShares.length; i++) {
            if (init.xShares[i].xId == 0 || init.xShares[i].bps == 0) revert InvalidConfig();
            for (uint256 j = 0; j < i; j++) {
                if (init.xShares[j].xId == init.xShares[i].xId) revert InvalidConfig();
            }
            xSum += init.xShares[i].bps;
            _xShares.push(init.xShares[i]);
        }
        if (xSum > BPS) revert InvalidConfig();
        token = init.token;
        quote = init.quote;
        feeEscrow = IFeeEscrowClaims(init.feeEscrow);
        xRegistry = IXRecipientRegistry(init.xRegistry);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Pulls the vault's fees from the FeeEscrow and books everything unbooked into the X shares and the
    ///         creator's share. Permissionless and idempotent; it moves no tokens out of the vault.
    function collect() external nonReentrant returns (uint256 amount) {
        return _collect();
    }

    /// @notice Pays an X account's accrued share to the wallet it bound in the registry.
    function claimX(uint256 xId) external nonReentrant returns (uint256 amount) {
        address recipient = xRegistry.recipientOf(xId);
        if (recipient == address(0)) revert XNotBound(xId);
        _collect();
        amount = xOwed[xId];
        if (amount == 0) revert NothingToPay();
        xOwed[xId] = 0;
        xOwedTotal -= amount;
        _send(recipient, amount);
        emit XPaid(xId, recipient, amount);
    }

    // ───────────────────────────── Creator ─────────────────────────────

    /// @notice Collects and pays the creator's share to the payout address.
    function claim() external nonReentrant returns (uint256 paid) {
        _requireCreator();
        _collect();
        paid = creatorOwed;
        if (paid == 0) return 0;
        creatorOwed = 0;
        address payout = payoutAddress();
        _send(payout, paid);
        emit CreatorPaid(payout, paid);
    }

    /// @notice Sets where the creator's share goes. Resets automatically when creator rights move to someone else
    ///         (then the new creator's own address is used until they set one).
    function setPayoutAddress(address payout) external {
        address creator = _requireCreator();
        if (payout == address(0) || payout == address(this)) revert InvalidConfig();
        _payoutSetBy = creator;
        _payoutAddress = payout;
        emit PayoutAddressSet(creator, payout);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function currentCreator() public view returns (address) {
        return ICreatorOf(factory).currentCreatorOf(token);
    }

    function payoutAddress() public view returns (address) {
        address creator = currentCreator();
        return _payoutSetBy == creator ? _payoutAddress : creator;
    }

    function xShares() external view returns (XShare[] memory) {
        return _xShares;
    }

    /// @notice Fees waiting in the FeeEscrow for this vault (not yet collected).
    function pendingFees() external view returns (uint256) {
        return feeEscrow.owed(address(this), quote);
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _collect() internal returns (uint256 amount) {
        if (feeEscrow.owed(address(this), quote) != 0) feeEscrow.claimFor(address(this), quote);
        uint256 balance = _balance();
        uint256 earmarked = creatorOwed + xOwedTotal;
        if (balance <= earmarked) return 0;
        amount = balance - earmarked;
        uint256 toX;
        XShare[] storage shares = _xShares;
        for (uint256 i = 0; i < shares.length; i++) {
            uint256 share = amount * shares[i].bps / BPS;
            xOwed[shares[i].xId] += share;
            toX += share;
        }
        uint256 toCreator = amount - toX;
        xOwedTotal += toX;
        creatorOwed += toCreator;
        emit Collected(amount, toX, toCreator);
    }

    function _requireCreator() internal view returns (address creator) {
        creator = currentCreator();
        if (msg.sender != creator) revert NotCreator();
    }

    function _balance() internal view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    function _send(address to, uint256 amount) internal {
        if (quote == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }
}
