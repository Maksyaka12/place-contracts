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
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IPlaceHub} from "./interfaces/IPlaceHub.sol";
import {IPlaceStaking} from "./interfaces/IPlaceStaking.sol";
import {IPlaceRewardTokenRegistry} from "./interfaces/IPlaceRewardTokenRegistry.sol";
import {IXRecipientRegistry} from "./interfaces/IXRecipientRegistry.sol";

interface IFeeEscrowClaims {
    function owed(address recipient, address currency) external view returns (uint256);
    function claimFor(address recipient, address currency) external;
}

interface ICreatorOf {
    function currentCreatorOf(address token) external view returns (address);
}

interface IHookPoolManager {
    function poolManager() external view returns (address);
}

/// @title PlaceCreatorVault
/// @notice One clone per launch, recorded in the hook as the launch's creator fee recipient; nobody can change
///         that (LAUNCH.md decision #16). "The token's economics is a contract, not a promise" (LAUNCH.md §4):
///         the creator's 0.7% of every trade is split into three baskets, frozen at launch (bps, sum <= 100%):
///         - **burn** (`burnBps`): bought back in the launch's own pool and sent to 0x…dEaD by `process()`, which
///           anyone may call (Place's daily cron, the creator's claim). At most `maxBurnPerProcess` per call and
///           not more often than `processInterval` (both frozen at launch), so the buybacks stay small and a
///           sandwich does not pay against the pool's 1% fee each way;
///         - **community fund** (`communityBps`): stays here. The creator cannot withdraw it. It leaves only into
///           a PlaceHub holders campaign for this token (`fundCampaign`) or a PlaceStaking program for this
///           token (`fundStaking`), in any reward token of the white list: the vault swaps the fund along the
///           route the PlaceRewardTokenRegistry lists, with the creator's `minOut` and a per-hop price impact
///           cap, in the same transaction. If the fund is not used for `defaultCampaignDelay` (30 days), anyone
///           starts the default holders campaign (`startDefaultCampaign`);
///         - **the rest** goes to X accounts (fixed shares, paid once the account binds a wallet in the
///           XRecipientRegistry) and to the creator's payout address (`claim`).
///         The creator (current holder of the creator rights) can raise `burnBps`/`communityBps` later
///         (`increaseEconomics`, decision #22), never lower them.
/// @dev    Fees arrive in the launch's quote only through `_collect` (FeeEscrow pull). In the quote,
///         `burnReserve`, `creatorOwed` and `xOwedTotal` are earmarked and everything else is the community fund
///         (its share, hub refunds, donations, swap dust). Any other asset the vault holds (refunds of campaigns
///         paid in another reward token, swap leftovers) belongs to the fund as a whole.
contract PlaceCreatorVault is Initializable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint16 public constant BPS = 10_000;
    uint256 public constant MAX_X_SHARES = 5;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    /// @notice Default campaign: snapshot one day after the start, claims open for 30 days, leftovers burned.
    uint64 public constant DEFAULT_SNAPSHOT_DELAY = 24 hours;
    uint32 public constant DEFAULT_CLAIM_DURATION = 30 days;
    /// @notice Bounds for the snapshot delay the creator picks in `fundCampaign`.
    uint64 public constant MIN_SNAPSHOT_DELAY = 1 hours;
    uint64 public constant MAX_SNAPSHOT_DELAY = 30 days;
    /// @notice Burn reserves below this many quote units are carried over instead of swapped.
    uint256 public constant MIN_BURN_AMOUNT = 1_000;

    struct XShare {
        uint256 xId;
        uint16 bps; // of the creator side (after burn and community)
    }

    /// @notice Copied from the factory at launch and frozen (LAUNCH.md §4.2–4.3).
    struct Settings {
        address hub; // PlaceHub for fund campaigns (required when communityBps > 0)
        address staking; // PlaceStaking for fund programs (zero: none)
        address rewardRegistry; // PlaceRewardTokenRegistry (zero: the fund cannot swap)
        uint64 processInterval; // minimum time between two burns
        uint64 defaultCampaignDelay; // fund idle this long -> anyone starts the default campaign
        uint128 maxBurnPerProcess; // quote units per burn (0 = no cap)
        uint128 defaultCampaignMinimum; // quote units
        bytes32 rulesHash; // rules template committed by every fund campaign
        string rulesURI;
    }

    struct Initialization {
        address token;
        PoolKey poolKey;
        address feeEscrow;
        uint16 burnBps;
        uint16 communityBps;
        XShare[] xShares;
        address xRegistry;
        Settings settings;
    }

    /// @notice A holders campaign for this token, paid from the community fund (creator only).
    struct CampaignRequest {
        address fundAsset; // what the fund spends: the quote or another asset the fund holds
        uint256 amountIn; // how much of it, hub fee included
        address rewardToken; // == fundAsset: no swap; else a listed route (or this token through its own pool)
        uint256 minOut; // minimum reward tokens out of the swap
        uint64 snapshotDelay;
        uint32 claimDuration;
        bool burnLeftover;
        string metadataURI;
    }

    /// @notice A PlaceStaking program for this token, paid from the community fund (creator only).
    struct StakingRequest {
        address fundAsset;
        uint256 amountIn; // fund spent, staking fee included
        address rewardToken;
        uint256 minOut;
        uint64 startTime;
        uint64 epochDuration;
        uint64 epochCount;
        uint8 earlyExitMode; // 0 = forbidden, 1 = allowed with penaltyBps (burned)
        uint16 penaltyBps;
    }

    address public factory;
    IPoolManager public poolManager;
    IFeeEscrowClaims public feeEscrow;
    address public token;
    address public quote;
    PoolKey internal _poolKey;
    bool public tokenIsCurrency0;

    uint16 public burnBps;
    uint16 public communityBps;
    XShare[] internal _xShares;
    IXRecipientRegistry public xRegistry;
    Settings internal _settings;

    uint64 public lastProcessAt;
    uint64 public lastFundSpendAt;

    address internal _payoutSetBy;
    address internal _payoutAddress;

    uint256 public burnReserve;
    uint256 public creatorOwed;
    uint256 public xOwedTotal;
    mapping(uint256 xId => uint256 amount) public xOwed;

    bool private _swapping;

    event Collected(uint256 amount, uint256 toBurn, uint256 toCommunity, uint256 toX, uint256 toCreator);
    event Burned(uint256 quoteIn, uint256 tokenOut, address indexed caller);
    event CreatorPaid(address indexed payout, uint256 amount);
    event XPaid(uint256 indexed xId, address indexed recipient, uint256 amount);
    event PayoutAddressSet(address indexed creator, address indexed payout);
    event EconomicsIncreased(uint16 burnBps, uint16 communityBps);
    event FundSwapped(address indexed fundAsset, address indexed rewardToken, uint256 amountIn, uint256 amountOut);
    event FundCampaignCreated(
        uint256 indexed campaignId, address indexed rewardToken, uint256 pool, uint256 paid, bool isDefault
    );
    event FundStakingCreated(
        bytes32 indexed stakingVaultId,
        address indexed rewardToken,
        uint256 rewardPerEpoch,
        uint64 epochCount,
        uint256 paid
    );

    error NotCreator();
    error NotPoolManager();
    error InvalidConfig();
    error OnlyIncrease();
    error CommunityDisabled();
    error StakingDisabled();
    error ProcessTooSoon(uint64 nextAt);
    error DefaultCampaignTooSoon(uint64 nextAt);
    error FundTooSmall(uint256 available, uint256 needed);
    error RouteNotListed(address fundAsset, address rewardToken);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error PriceImpactTooHigh(uint256 impactBps, uint256 maxBps);
    error PartialFill();
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
        _validateShares(init.burnBps, init.communityBps, init.settings.hub);
        if (init.settings.hub != address(0)) {
            if (init.settings.rulesHash == bytes32(0) || bytes(init.settings.rulesURI).length == 0) {
                revert InvalidConfig();
            }
            if (init.settings.defaultCampaignDelay == 0) revert InvalidConfig();
        }
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
        poolManager = IPoolManager(IHookPoolManager(address(init.poolKey.hooks)).poolManager());
        feeEscrow = IFeeEscrowClaims(init.feeEscrow);
        burnBps = init.burnBps;
        communityBps = init.communityBps;
        xRegistry = IXRecipientRegistry(init.xRegistry);
        _settings = init.settings;
        lastFundSpendAt = uint64(block.timestamp);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Pulls the vault's fees from the FeeEscrow and books them into the baskets. Permissionless and
    ///         idempotent; it moves no tokens out of the vault.
    function collect() external nonReentrant returns (uint256 amount) {
        return _collect();
    }

    /// @notice The daily step (LAUNCH.md §4.2): collects the fees, books them and buys back up to
    ///         `maxBurnPerProcess` of the burn reserve in the launch's own pool, sending the tokens to 0x…dEaD.
    ///         Anyone may call it once per `processInterval`. No slippage input: the cap and the interval are the
    ///         protection, and whatever is not bought now stays in the reserve.
    function process() external nonReentrant returns (uint256 collected, uint256 quoteIn, uint256 tokensBurned) {
        uint64 nextAt = nextProcessAt();
        // forge-lint: disable-next-line(block-timestamp) the cadence is measured in hours
        if (block.timestamp < nextAt) revert ProcessTooSoon(nextAt);
        collected = _collect();
        (quoteIn, tokensBurned) = _burn();
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
        _send(quote, recipient, amount);
        emit XPaid(xId, recipient, amount);
    }

    /// @notice If the creator has not spent the community fund for `defaultCampaignDelay`, anyone (Place's cron)
    ///         turns the whole fund (in the quote) into the default holders campaign: snapshot in 24 h, 30-day
    ///         claims, leftovers burned, the rules template frozen at launch (LAUNCH.md decision #21).
    function startDefaultCampaign() external nonReentrant returns (uint256 campaignId) {
        Settings storage s = _settings;
        if (s.hub == address(0)) revert CommunityDisabled();
        uint64 nextAt = lastFundSpendAt + s.defaultCampaignDelay;
        // forge-lint: disable-next-line(block-timestamp) measured in days
        if (block.timestamp < nextAt) revert DefaultCampaignTooSoon(nextAt);
        _collect();
        uint256 available = fundBalance(quote);
        uint256 minimum = s.defaultCampaignMinimum == 0 ? 1 : s.defaultCampaignMinimum;
        if (available < minimum) revert FundTooSmall(available, minimum);
        lastFundSpendAt = uint64(block.timestamp);
        uint256 pool;
        uint256 paid;
        (campaignId, pool, paid) =
            _createCampaign(quote, available, DEFAULT_SNAPSHOT_DELAY, DEFAULT_CLAIM_DURATION, true, "");
        emit FundCampaignCreated(campaignId, quote, pool, paid, true);
    }

    /// @notice If the Place publisher never posted a root, the hub lets the campaign creator (this vault) take the
    ///         pool back; it returns to the community fund. Permissionless: funds can only come here.
    function refundUnpublishedCampaign(uint256 campaignId) external nonReentrant {
        IPlaceHub(_settings.hub).refundUnpublished(campaignId);
    }

    // ───────────────────────────── Creator ─────────────────────────────

    /// @notice Collects, burns if the interval allows (the same limits as `process`) and pays the creator's share.
    function claim() external nonReentrant returns (uint256 paid) {
        _requireCreator();
        _collect();
        // forge-lint: disable-next-line(block-timestamp) the cadence is measured in hours
        if (block.timestamp >= nextProcessAt()) _burn();
        paid = creatorOwed;
        if (paid == 0) return 0;
        creatorOwed = 0;
        address payout = payoutAddress();
        _send(quote, payout, paid);
        emit CreatorPaid(payout, paid);
    }

    /// @notice A PlaceHub holders campaign for this token from the community fund. The target (this token), the
    ///         kind (holders) and the rules (the template frozen at launch) are fixed; the creator picks the
    ///         amount, the reward token from the white list, the snapshot delay, the claim window and what
    ///         happens to leftovers. The hub fee (5%, like every campaign) comes out of `amountIn`.
    function fundCampaign(CampaignRequest calldata r) external nonReentrant returns (uint256 campaignId) {
        _requireCreator();
        if (_settings.hub == address(0)) revert CommunityDisabled();
        if (r.snapshotDelay < MIN_SNAPSHOT_DELAY || r.snapshotDelay > MAX_SNAPSHOT_DELAY) revert InvalidConfig();
        uint256 budget = _spendFund(r.fundAsset, r.amountIn, r.rewardToken, r.minOut);
        uint256 pool;
        uint256 paid;
        (campaignId, pool, paid) =
            _createCampaign(r.rewardToken, budget, r.snapshotDelay, r.claimDuration, r.burnLeftover, r.metadataURI);
        emit FundCampaignCreated(campaignId, r.rewardToken, pool, paid, false);
    }

    /// @notice A PlaceStaking program for stakers of this token from the community fund: the whole swap output,
    ///         minus the staking fee, becomes the program's budget (`rewardPerEpoch` x `epochCount`); rounding
    ///         dust stays in the fund.
    function fundStaking(StakingRequest calldata r) external nonReentrant returns (bytes32 stakingVaultId) {
        _requireCreator();
        IPlaceStaking staking = IPlaceStaking(_settings.staking);
        if (address(staking) == address(0)) revert StakingDisabled();
        if (r.epochCount == 0) revert InvalidConfig();
        uint256 budget = _spendFund(r.fundAsset, r.amountIn, r.rewardToken, r.minOut);
        (uint16 feeBps,, uint64 version) = staking.feeConfig();
        uint256 perEpoch = budget * BPS / (BPS + uint256(feeBps)) / r.epochCount;
        if (perEpoch > type(uint192).max) perEpoch = type(uint192).max;
        if (perEpoch != 0 && _stakingTotal(perEpoch, r.epochCount, feeBps) > budget) perEpoch -= 1;
        if (perEpoch == 0) revert FundTooSmall(budget, r.epochCount);
        uint256 total = _stakingTotal(perEpoch, r.epochCount, feeBps);
        IPlaceStaking.VaultParams memory p = IPlaceStaking.VaultParams({
            stakingToken: token,
            rewardCurrency: r.rewardToken,
            startTime: r.startTime,
            epochDuration: r.epochDuration,
            epochCount: r.epochCount,
            // forge-lint: disable-next-line(unsafe-typecast) capped at uint192 max above
            rewardPerEpoch: uint192(perEpoch),
            earlyExitMode: r.earlyExitMode,
            penaltyBps: r.penaltyBps
        });
        if (r.rewardToken == address(0)) {
            stakingVaultId = staking.createVault{value: total}(p, version);
        } else {
            IERC20(r.rewardToken).forceApprove(address(staking), total);
            stakingVaultId = staking.createVault(p, version);
            IERC20(r.rewardToken).forceApprove(address(staking), 0);
        }
        emit FundStakingCreated(stakingVaultId, r.rewardToken, perEpoch, r.epochCount, total);
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

    /// @notice Raises the burn and/or community shares (LAUNCH.md decision #22). Applies to fees collected after
    ///         the call; pending fees are booked at the old shares first.
    function increaseEconomics(uint16 newBurnBps, uint16 newCommunityBps) external nonReentrant {
        _requireCreator();
        if (newBurnBps < burnBps || newCommunityBps < communityBps) revert OnlyIncrease();
        _validateShares(newBurnBps, newCommunityBps, _settings.hub);
        _collect();
        burnBps = newBurnBps;
        communityBps = newCommunityBps;
        emit EconomicsIncreased(newBurnBps, newCommunityBps);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function currentCreator() public view returns (address) {
        return ICreatorOf(factory).currentCreatorOf(token);
    }

    function payoutAddress() public view returns (address) {
        address creator = currentCreator();
        return _payoutSetBy == creator ? _payoutAddress : creator;
    }

    /// @notice The community fund held in `asset` (not counting fees still in the FeeEscrow).
    function fundBalance(address asset) public view returns (uint256) {
        uint256 balance = _balanceOf(asset);
        if (asset != quote) return balance;
        uint256 earmarked = burnReserve + creatorOwed + xOwedTotal;
        return balance > earmarked ? balance - earmarked : 0;
    }

    /// @notice When `process()` may next burn.
    function nextProcessAt() public view returns (uint64) {
        return lastProcessAt == 0 ? 0 : lastProcessAt + _settings.processInterval;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function xShares() external view returns (XShare[] memory) {
        return _xShares;
    }

    function settings() external view returns (Settings memory) {
        return _settings;
    }

    /// @notice Fees waiting in the FeeEscrow for this vault (not yet collected).
    function pendingFees() external view returns (uint256) {
        return feeEscrow.owed(address(this), quote);
    }

    // ───────────────────────────── Uniswap v4 ─────────────────────────────

    /// @dev Only reachable from this vault's own `unlock` in `_swap` (the PoolManager calls back the caller).
    ///      Exact-in hops from `input`; `strict` (fund swaps) requires full fills and caps each hop's price impact,
    ///      the burn (single hop, own pool) accepts a partial fill and leaves the rest in the reserve.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_swapping) revert NotPoolManager();
        (address input, PoolKey[] memory hops, uint256 amountIn, address destination, bool strict) =
            abi.decode(data, (address, PoolKey[], uint256, address, bool));
        uint256 maxImpact = strict ? IPlaceRewardTokenRegistry(_settings.rewardRegistry).maxPriceImpactBps() : 0;
        address current = input;
        uint256 amount = amountIn;
        uint256 paid;
        for (uint256 i = 0; i < hops.length; i++) {
            PoolKey memory key = hops[i];
            bool zeroForOne = Currency.unwrap(key.currency0) == current;
            PoolId id = key.toId();
            (uint160 priceBefore,,,) = StateLibrary.getSlot0(poolManager, id);
            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
            int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
            if (inDelta > 0 || outDelta < 0) revert PartialFill();
            // forge-lint: disable-next-line(unsafe-typecast) inDelta <= 0 (we pay)
            uint256 spent = uint256(uint128(-inDelta));
            if (i == 0) paid = spent;
            if (strict) {
                if (spent != amount) revert PartialFill();
                (uint160 priceAfter,,,) = StateLibrary.getSlot0(poolManager, id);
                uint256 impact = _impactBps(priceBefore, priceAfter);
                if (impact > maxImpact) revert PriceImpactTooHigh(impact, maxImpact);
            }
            // forge-lint: disable-next-line(unsafe-typecast) outDelta >= 0 (we receive)
            amount = uint256(uint128(outDelta));
            current = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        }
        if (input == address(0)) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(Currency.wrap(input));
            IERC20(input).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        }
        if (amount != 0) poolManager.take(Currency.wrap(current), destination, amount);
        return abi.encode(paid, amount);
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _collect() internal returns (uint256 amount) {
        if (feeEscrow.owed(address(this), quote) == 0) return 0;
        uint256 before = _balanceOf(quote);
        feeEscrow.claimFor(address(this), quote);
        amount = _balanceOf(quote) - before;
        if (amount == 0) return 0;

        uint256 toBurn = amount * burnBps / BPS;
        uint256 toCommunity = amount * communityBps / BPS;
        uint256 creatorSide = amount - toBurn - toCommunity;
        uint256 toX;
        XShare[] storage shares = _xShares;
        for (uint256 i = 0; i < shares.length; i++) {
            uint256 share = creatorSide * shares[i].bps / BPS;
            xOwed[shares[i].xId] += share;
            toX += share;
        }
        uint256 toCreator = creatorSide - toX;
        burnReserve += toBurn;
        xOwedTotal += toX;
        creatorOwed += toCreator;
        // toCommunity stays in the balance as the unearmarked community fund.
        emit Collected(amount, toBurn, toCommunity, toX, toCreator);
    }

    /// @dev Buys back min(reserve, cap) in the launch's own pool to 0x…dEaD and starts the next interval.
    function _burn() internal returns (uint256 quoteIn, uint256 tokenOut) {
        lastProcessAt = uint64(block.timestamp);
        uint256 amount = burnReserve;
        uint256 cap = _settings.maxBurnPerProcess;
        if (cap != 0 && amount > cap) amount = cap;
        if (amount < MIN_BURN_AMOUNT) return (0, 0);
        burnReserve -= amount;
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = _poolKey;
        (quoteIn, tokenOut) = _swap(quote, hops, amount, BURN_SINK, false);
        // A partial fill (price limit reached) leaves the unspent quote in the reserve.
        if (quoteIn < amount) burnReserve += amount - quoteIn;
        emit Burned(quoteIn, tokenOut, msg.sender);
    }

    /// @dev Takes `amountIn` of `fundAsset` from the community fund and, if needed, swaps it into `rewardToken`
    ///      along the listed route. Returns the reward tokens now set aside for the program (held by the vault).
    function _spendFund(address fundAsset, uint256 amountIn, address rewardToken, uint256 minOut)
        internal
        returns (uint256 out)
    {
        _collect();
        uint256 available = fundBalance(fundAsset);
        if (amountIn == 0 || amountIn > available) revert FundTooSmall(available, amountIn);
        lastFundSpendAt = uint64(block.timestamp);
        if (rewardToken == fundAsset) return amountIn;
        PoolKey[] memory hops;
        if (fundAsset == quote && rewardToken == token) {
            hops = new PoolKey[](1);
            hops[0] = _poolKey;
        } else if (_settings.rewardRegistry != address(0)) {
            hops = IPlaceRewardTokenRegistry(_settings.rewardRegistry).routeOf(fundAsset, rewardToken);
        }
        if (hops.length == 0 || _settings.rewardRegistry == address(0)) {
            revert RouteNotListed(fundAsset, rewardToken);
        }
        uint256 paid;
        (paid, out) = _swap(fundAsset, hops, amountIn, address(this), true);
        if (out < minOut) revert SlippageExceeded(out, minOut);
        emit FundSwapped(fundAsset, rewardToken, paid, out);
    }

    function _createCampaign(
        address rewardToken,
        uint256 budget,
        uint64 snapshotDelay,
        uint32 claimDuration,
        bool burnLeftover,
        string memory metadataURI
    ) internal returns (uint256 campaignId, uint256 pool, uint256 due) {
        IPlaceHub hub = IPlaceHub(_settings.hub);
        uint256 feeBps = hub.config().campaignFeeBps(token);
        pool = budget * BPS / (BPS + feeBps);
        if (pool > type(uint128).max) pool = type(uint128).max;
        if (pool == 0) revert FundTooSmall(budget, BPS + feeBps);
        due = pool + pool * feeBps / BPS;
        IPlaceHub.CreateParams memory p = IPlaceHub.CreateParams({
            kind: IPlaceHub.Kind.TokenHolders,
            target: token,
            rewardToken: rewardToken,
            // forge-lint: disable-next-line(unsafe-typecast) capped at uint128 max above
            pool: uint128(pool),
            snapshotAt: uint64(block.timestamp) + snapshotDelay,
            claimDuration: claimDuration,
            burnLeftover: burnLeftover,
            rulesHash: _settings.rulesHash,
            rulesURI: _settings.rulesURI,
            metadataURI: metadataURI
        });
        if (rewardToken == address(0)) {
            campaignId = hub.createCampaign{value: due}(p);
        } else {
            IERC20(rewardToken).forceApprove(address(hub), due);
            campaignId = hub.createCampaign(p);
            IERC20(rewardToken).forceApprove(address(hub), 0);
        }
    }

    function _swap(address input, PoolKey[] memory hops, uint256 amountIn, address destination, bool strict)
        internal
        returns (uint256 paid, uint256 out)
    {
        _swapping = true;
        bytes memory result = poolManager.unlock(abi.encode(input, hops, amountIn, destination, strict));
        _swapping = false;
        (paid, out) = abi.decode(result, (uint256, uint256));
    }

    function _validateShares(uint16 burn, uint16 community, address hub) internal pure {
        if (uint256(burn) + community > BPS) revert InvalidConfig();
        if (community != 0 && hub == address(0)) revert CommunityDisabled();
    }

    function _requireCreator() internal view returns (address creator) {
        creator = currentCreator();
        if (msg.sender != creator) revert NotCreator();
    }

    function _balanceOf(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _stakingTotal(uint256 perEpoch, uint64 epochCount, uint16 feeBps) internal pure returns (uint256) {
        uint256 reward = perEpoch * epochCount;
        return reward + (reward * feeBps + BPS - 1) / BPS;
    }

    /// @dev |price_after / price_before - 1| in bps, from the two sqrt prices.
    function _impactBps(uint160 sqrtBefore, uint160 sqrtAfter) internal pure returns (uint256) {
        uint256 ratio = FullMath.mulDiv(sqrtAfter, 1e18, sqrtBefore);
        uint256 price = FullMath.mulDiv(ratio, ratio, 1e18);
        uint256 move = price > 1e18 ? price - 1e18 : 1e18 - price;
        return move * BPS / 1e18;
    }
}
