// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IPlaceHub} from "./interfaces/IPlaceHub.sol";
import {IXRecipientRegistry} from "./interfaces/IXRecipientRegistry.sol";

interface IFeeEscrowClaims {
    function owed(address recipient, address currency) external view returns (uint256);
    function claimFor(address recipient, address currency) external;
}

interface ICreatorOf {
    function currentCreatorOf(address token) external view returns (address);
}

/// @title PlaceCreatorVault
/// @notice One clone per launch, recorded in the hook as the launch's creator fee recipient. Nobody can change
///         that (LAUNCH.md decision #16), so the economics promised at launch hold:
///         - **buyback** (`buybackBps` of every fee): bought back from the launch's own pool when the creator
///           claims, with the creator's `minOut`, then burned (sent to 0x…dEaD) or paid to the creator;
///         - **holder rewards** (`rewardsBps`): accumulate here; `startRewardsCampaign` turns them into a
///           PlaceHub holders campaign (snapshot in 24 h, 30-day claims, leftovers burned) once the pool reaches
///           the minimum frozen at launch. Anyone may call it after `campaignInterval`; the creator at any time;
///         - **the rest** goes to X accounts (fixed shares, paid once the account binds a wallet in the
///           XRecipientRegistry) and to the creator's payout address.
///         The current creator (from the factory's creator rights) claims, changes the payout address instantly
///         and may only increase `buybackBps` / `rewardsBps` (or switch "hold" to "burn"), never decrease them.
/// @dev    Single currency: the launch's quote. Accounting: `buybackReserve`, `creatorOwed` and `xOwedTotal` are
///         earmarked; everything else held in the quote (rewards share, hub refunds, donations) is the rewards
///         pool. Fees reach the vault only through `collect` (FeeEscrow pull), which anyone can trigger.
contract PlaceCreatorVault is Initializable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint256 public constant MAX_X_SHARES = 5;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    uint64 public constant SNAPSHOT_DELAY = 24 hours;
    uint32 public constant CLAIM_DURATION = 30 days;
    /// @notice Buyback reserves below this many quote units are carried over instead of swapped.
    uint256 public constant MIN_BUYBACK_AMOUNT = 1_000;

    struct XShare {
        uint256 xId;
        uint16 bps; // of the creator side (after buyback and rewards)
    }

    struct RewardsConfig {
        address hub; // zero when rewardsBps is 0 and no hub was configured
        uint256 minAmount; // minimum pool for a campaign, in quote units
        uint64 interval; // minimum time between campaigns started by non-creators
        bytes32 rulesHash;
        string rulesURI;
    }

    struct Initialization {
        address token;
        PoolKey poolKey;
        address feeEscrow;
        uint16 buybackBps;
        bool buybackBurn;
        uint16 rewardsBps;
        XShare[] xShares;
        address xRegistry;
        RewardsConfig rewards;
    }

    address public factory;
    IPoolManager public poolManager;
    IFeeEscrowClaims public feeEscrow;
    address public token;
    address public quote;
    PoolKey internal _poolKey;
    bool public tokenIsCurrency0;

    uint16 public buybackBps;
    bool public buybackBurn;
    uint16 public rewardsBps;
    XShare[] internal _xShares;
    IXRecipientRegistry public xRegistry;
    RewardsConfig internal _rewards;
    uint64 public lastCampaignAt;

    address internal _payoutSetBy;
    address internal _payoutAddress;

    uint256 public buybackReserve;
    uint256 public creatorOwed;
    uint256 public xOwedTotal;
    mapping(uint256 xId => uint256 amount) public xOwed;

    bool private _swapping;

    event Collected(uint256 amount, uint256 toBuyback, uint256 toRewards, uint256 toX, uint256 toCreator);
    event BoughtBack(uint256 quoteIn, uint256 tokenOut, address indexed destination);
    event CreatorPaid(address indexed payout, uint256 amount);
    event XPaid(uint256 indexed xId, address indexed recipient, uint256 amount);
    event PayoutAddressSet(address indexed creator, address indexed payout);
    event EconomicsIncreased(uint16 buybackBps, bool buybackBurn, uint16 rewardsBps);
    event RewardsCampaignStarted(uint256 indexed campaignId, uint128 pool, uint256 paid, address indexed caller);

    error NotFactory();
    error NotCreator();
    error NotPoolManager();
    error InvalidConfig();
    error OnlyIncrease();
    error RewardsDisabled();
    error RewardsBelowMinimum(uint256 available, uint256 minimum);
    error CampaignTooSoon(uint64 nextAt);
    error XNotBound(uint256 xId);
    error NothingToPay();
    error BuybackBelowMinimum(uint256 tokenOut, uint256 minOut);
    error NativeTransferFailed();

    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Called once by the factory in the launch transaction, before the hook registers the pool.
    function initialize(Initialization calldata init) external initializer {
        factory = msg.sender;
        if (init.buybackBps + uint256(init.rewardsBps) > BPS) revert InvalidConfig();
        if (init.rewardsBps != 0 && init.rewards.hub == address(0)) revert InvalidConfig();
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
        _poolKey = init.poolKey;
        tokenIsCurrency0 = Currency.unwrap(init.poolKey.currency0) == init.token;
        quote = Currency.unwrap(tokenIsCurrency0 ? init.poolKey.currency1 : init.poolKey.currency0);
        poolManager = IPoolManager(address(_hookPoolManager(init.poolKey)));
        feeEscrow = IFeeEscrowClaims(init.feeEscrow);
        buybackBps = init.buybackBps;
        buybackBurn = init.buybackBurn;
        rewardsBps = init.rewardsBps;
        xRegistry = IXRecipientRegistry(init.xRegistry);
        _rewards = init.rewards;
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Pulls the vault's fees from the FeeEscrow and books them: buyback reserve, rewards pool,
    ///         X shares, creator. Permissionless and idempotent.
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

    /// @notice Turns the rewards pool into a PlaceHub holders campaign for this token. Anyone may call it once
    ///         `campaignInterval` has passed since the last one; the creator may call it at any time. Either way
    ///         the pool must be at least the minimum frozen at launch.
    function startRewardsCampaign() external nonReentrant returns (uint256 campaignId) {
        RewardsConfig storage cfg = _rewards;
        if (cfg.hub == address(0)) revert RewardsDisabled();
        if (msg.sender != currentCreator()) {
            uint64 nextAt = lastCampaignAt + cfg.interval;
            // forge-lint: disable-next-line(block-timestamp) campaign cadence is measured in days
            if (lastCampaignAt != 0 && block.timestamp < nextAt) revert CampaignTooSoon(nextAt);
        }
        _collect();
        uint256 available = rewardsAvailable();
        uint256 minimum = cfg.minAmount == 0 ? 1 : cfg.minAmount;
        if (available < minimum) revert RewardsBelowMinimum(available, minimum);

        IPlaceHub hub = IPlaceHub(cfg.hub);
        uint256 feeBps = hub.config().campaignFeeBps(token);
        uint256 pool = available * BPS / (BPS + feeBps);
        if (pool > type(uint128).max) pool = type(uint128).max;
        uint256 due = pool + pool * feeBps / BPS;
        if (pool == 0) revert RewardsBelowMinimum(available, minimum);

        IPlaceHub.CreateParams memory p = IPlaceHub.CreateParams({
            kind: IPlaceHub.Kind.TokenHolders,
            target: token,
            rewardToken: quote,
            pool: uint128(pool),
            snapshotAt: uint64(block.timestamp) + SNAPSHOT_DELAY,
            claimDuration: CLAIM_DURATION,
            burnLeftover: true,
            rulesHash: cfg.rulesHash,
            rulesURI: cfg.rulesURI,
            metadataURI: ""
        });
        lastCampaignAt = uint64(block.timestamp);
        if (quote == address(0)) {
            campaignId = hub.createCampaign{value: due}(p);
        } else {
            IERC20(quote).forceApprove(address(hub), due);
            campaignId = hub.createCampaign(p);
            IERC20(quote).forceApprove(address(hub), 0);
        }
        emit RewardsCampaignStarted(campaignId, uint128(pool), due, msg.sender);
    }

    /// @notice If the Place publisher never posted a root, the hub lets the campaign creator (this vault) take
    ///         the pool back; it returns to the rewards pool. Permissionless: funds can only come here.
    function refundUnpublishedCampaign(uint256 campaignId) external nonReentrant {
        IPlaceHub(_rewards.hub).refundUnpublished(campaignId);
    }

    // ───────────────────────────── Creator ─────────────────────────────

    /// @notice Collects, executes the buyback with the creator's slippage bound and pays the creator.
    /// @param minBuybackOut Minimum launch tokens out of the buyback swap (ignored when nothing is bought back).
    function claim(uint256 minBuybackOut) external nonReentrant returns (uint256 paid, uint256 boughtBack) {
        _requireCreator();
        _collect();
        uint256 reserve = buybackReserve;
        if (reserve >= MIN_BUYBACK_AMOUNT) {
            buybackReserve = 0;
            address destination = buybackBurn ? BURN_SINK : payoutAddress();
            boughtBack = _buyback(reserve, destination);
            if (boughtBack < minBuybackOut) revert BuybackBelowMinimum(boughtBack, minBuybackOut);
            emit BoughtBack(reserve, boughtBack, destination);
        }
        paid = creatorOwed;
        if (paid != 0) {
            creatorOwed = 0;
            address payout = payoutAddress();
            _send(payout, paid);
            emit CreatorPaid(payout, paid);
        }
    }

    /// @notice Sets where the creator's share (and "hold" buybacks) go. Resets automatically when creator
    ///         rights move to someone else (then the new creator's own address is used until they set one).
    function setPayoutAddress(address payout) external {
        address creator = _requireCreator();
        if (payout == address(0) || payout == address(this)) revert InvalidConfig();
        _payoutSetBy = creator;
        _payoutAddress = payout;
        emit PayoutAddressSet(creator, payout);
    }

    /// @notice Raises the buyback and/or rewards shares, or switches the buyback from "hold" to "burn".
    ///         Applies to fees collected after the call (pending fees are booked at the old shares first).
    function increaseEconomics(uint16 newBuybackBps, bool newBuybackBurn, uint16 newRewardsBps) external nonReentrant {
        _requireCreator();
        if (newBuybackBps < buybackBps || newRewardsBps < rewardsBps || (buybackBurn && !newBuybackBurn)) {
            revert OnlyIncrease();
        }
        if (uint256(newBuybackBps) + newRewardsBps > BPS) revert InvalidConfig();
        if (newRewardsBps != 0 && _rewards.hub == address(0)) revert RewardsDisabled();
        _collect();
        buybackBps = newBuybackBps;
        buybackBurn = newBuybackBurn;
        rewardsBps = newRewardsBps;
        emit EconomicsIncreased(newBuybackBps, newBuybackBurn, newRewardsBps);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function currentCreator() public view returns (address) {
        return ICreatorOf(factory).currentCreatorOf(token);
    }

    function payoutAddress() public view returns (address) {
        address creator = currentCreator();
        return _payoutSetBy == creator ? _payoutAddress : creator;
    }

    /// @notice Quote held for holder rewards: everything not earmarked for buyback, creator or X.
    function rewardsAvailable() public view returns (uint256) {
        uint256 balance = _balance();
        uint256 earmarked = buybackReserve + creatorOwed + xOwedTotal;
        return balance > earmarked ? balance - earmarked : 0;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function xShares() external view returns (XShare[] memory) {
        return _xShares;
    }

    function rewardsConfig() external view returns (RewardsConfig memory) {
        return _rewards;
    }

    /// @notice Fees waiting in the FeeEscrow for this vault (not yet collected).
    function pendingFees() external view returns (uint256) {
        return feeEscrow.owed(address(this), quote);
    }

    // ───────────────────────────── Uniswap v4 ─────────────────────────────

    /// @dev Only reachable from this vault's own `unlock` in `_buyback` (the PoolManager calls back the caller).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_swapping) revert NotPoolManager();
        (uint256 amountIn, address destination) = abi.decode(data, (uint256, address));
        PoolKey memory key = _poolKey;
        bool zeroForOne = !tokenIsCurrency0; // quote -> token
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 quoteDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 tokenDelta = zeroForOne ? delta.amount1() : delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast) quoteDelta <= 0 (we pay), tokenDelta >= 0 (we receive)
        uint256 quoteOwed = uint256(uint128(-quoteDelta));
        // forge-lint: disable-next-line(unsafe-typecast) see above
        uint256 tokenOut = uint256(uint128(tokenDelta));
        Currency quoteCurrency = Currency.wrap(quote);
        if (quote == address(0)) {
            poolManager.settle{value: quoteOwed}();
        } else {
            poolManager.sync(quoteCurrency);
            IERC20(quote).safeTransfer(address(poolManager), quoteOwed);
            poolManager.settle();
        }
        if (tokenOut != 0) poolManager.take(Currency.wrap(token), destination, tokenOut);
        return abi.encode(quoteOwed, tokenOut);
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _collect() internal returns (uint256 amount) {
        if (feeEscrow.owed(address(this), quote) == 0) return 0;
        uint256 before = _balance();
        feeEscrow.claimFor(address(this), quote);
        amount = _balance() - before;
        if (amount == 0) return 0;

        uint256 toBuyback = amount * buybackBps / BPS;
        uint256 toRewards = amount * rewardsBps / BPS;
        uint256 creatorSide = amount - toBuyback - toRewards;
        uint256 toX;
        XShare[] storage shares = _xShares;
        for (uint256 i = 0; i < shares.length; i++) {
            uint256 share = creatorSide * shares[i].bps / BPS;
            xOwed[shares[i].xId] += share;
            toX += share;
        }
        uint256 toCreator = creatorSide - toX;
        buybackReserve += toBuyback;
        xOwedTotal += toX;
        creatorOwed += toCreator;
        // toRewards stays in the balance as the unearmarked rewards pool.
        emit Collected(amount, toBuyback, toRewards, toX, toCreator);
    }

    function _buyback(uint256 amountIn, address destination) internal returns (uint256 tokenOut) {
        _swapping = true;
        bytes memory result = poolManager.unlock(abi.encode(amountIn, destination));
        _swapping = false;
        uint256 quotePaid;
        (quotePaid, tokenOut) = abi.decode(result, (uint256, uint256));
        // A partial fill (price limit reached) leaves the unspent quote in the reserve.
        if (quotePaid < amountIn) buybackReserve += amountIn - quotePaid;
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

    function _hookPoolManager(PoolKey calldata key) private view returns (address) {
        return IHookPoolManager(address(key.hooks)).poolManager();
    }
}

interface IHookPoolManager {
    function poolManager() external view returns (address);
}
