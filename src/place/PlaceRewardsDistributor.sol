// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PlaceRouteSwapper} from "./PlaceRouteSwapper.sol";
import {IPlaceRewardsDistributor} from "./interfaces/IPlaceRewardsDistributor.sol";
import {IPlaceRewardTokenRegistry} from "./interfaces/IPlaceRewardTokenRegistry.sol";
import {IFeeEscrowClaims} from "./interfaces/IPlaceLaunchViews.sol";
import {PlaceSuiteConstants} from "../launch/PlaceSuiteConstants.sol";

interface IDistributorFactoryWiring {
    function hook() external view returns (address);
}

interface IDistributorHookWiring {
    function poolManager() external view returns (address);
    function feeEscrow() external view returns (address);
}

/// @title PlaceRewardsDistributor
/// @notice Daily reward streams for holders and traders of a token, paid in a reward token.
///         - **Economy streams**: one per enabled basket of an Economy launch (registered by the factory). The hook
///           keeps the basket's share of every trade in the FeeEscrow under the stream's account.
///         - **Funded streams**: anyone funds a stream for any token up front, `rewardPerEpoch` x `epochCount`
///           (rewards hub, community vaults). A stream fee goes to the platform.
///         Each day (epoch = UTC day) anyone calls `closeEpoch`: an Economy stream pulls its account from the
///         FeeEscrow and, when the reward token differs from the launch quote, swaps it along the route the
///         PlaceRewardTokenRegistry lists (or the launch's own pool, for the launch token) with the registry's per-hop
///         price impact cap; a funded stream releases its epochs' budget. The Place publisher then posts a
///         cumulative Merkle root per stream (every account's total over all days, tables on IPFS). The contract
///         only accepts a root whose total stays within what the stream has funded, so it can never owe more
///         than it holds. Accounts claim the difference "cumulative - already claimed" whenever they like, for
///         many streams in one call (`claimMany`). Budget not allocated on a day (nobody eligible) stays funded and
///         is allocated on later days. Rewards never expire.
/// @dev    Leaves: keccak256(bytes.concat(keccak256(abi.encode(streamId, account, cumulativeAmount)))).
///         `liabilities[asset]` is everything the contract owes in `asset`; its balance always covers it.
contract PlaceRewardsDistributor is IPlaceRewardsDistributor, Ownable2Step, ReentrancyGuard, PlaceRouteSwapper {
    using SafeERC20 for IERC20;

    uint64 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_STREAM_FEE_BPS = 1_000;
    uint64 public constant MAX_EPOCHS = 365;
    uint64 public constant MAX_START_DELAY_EPOCHS = 90;
    /// @notice A funded stream's unallocated budget returns to its funder this long after its last epoch.
    uint64 public constant RECLAIM_DELAY = 30 days;

    struct Stream {
        address token;
        Kind kind;
        bool economy;
        address rewardToken;
        address source; // asset the stream is fed in: the launch quote (Economy) or the reward token (funded)
        address funder; // funded streams: receives the unallocated budget back
        address rewardRegistry; // Economy: frozen at launch; zero when no swap is needed
        uint64 startEpoch;
        uint64 epochCount; // funded: number of epochs; Economy: 0 (open-ended)
        uint64 lastClosedEpoch; // startEpoch - 1 until the first close
        uint64 rootEpoch;
        uint256 criterion; // Holders: minimum balance (token units); Traders: minimum daily volume (quote units)
        uint256 rewardPerEpoch; // funded streams
        uint256 pendingInput; // Economy: collected `source` not yet swapped into the reward token
        uint256 reserved; // funded streams: deposited, not yet released
        uint256 funded; // reward units released to closed epochs, cumulative
        uint256 allocated; // total of the current root
        uint256 claimed;
        bytes32 root;
    }

    struct RootUpdate {
        bytes32 streamId;
        uint64 epoch;
        bytes32 root;
        uint256 cumulativeTotal;
        string uri;
    }

    struct ClaimRequest {
        bytes32 streamId;
        address account;
        uint256 cumulativeAmount;
        bytes32[] proof;
    }

    address public immutable factory;
    address public immutable hook;
    IPoolManager public immutable poolManager;

    address public publisher;
    uint16 public streamFeeBps;
    address public feeRecipient;
    uint256 public streamNonce;

    mapping(bytes32 streamId => Stream stream) internal _streams;
    mapping(bytes32 streamId => PoolKey poolKey) internal _launchPool;
    mapping(bytes32 streamId => mapping(address account => uint256 cumulativeClaimed)) public claimedBy;
    mapping(address asset => uint256 amount) public liabilities;

    event LaunchStreamRegistered(
        bytes32 indexed streamId,
        address indexed token,
        Kind indexed kind,
        address quote,
        address rewardToken,
        uint256 criterion,
        uint64 startEpoch
    );
    event StreamCreated(
        bytes32 indexed streamId,
        address indexed token,
        Kind indexed kind,
        address rewardToken,
        address funder,
        uint64 startEpoch,
        uint64 epochCount,
        uint256 rewardPerEpoch,
        uint256 criterion,
        uint256 fee,
        string metadataURI
    );
    event EpochClosed(bytes32 indexed streamId, uint64 indexed epoch, uint256 collected, uint256 totalFunded);
    event Converted(bytes32 indexed streamId, uint256 amountIn, uint256 amountOut);
    event ConversionDeferred(bytes32 indexed streamId, uint256 pendingInput, bytes reason);
    event RootPublished(
        bytes32 indexed streamId, uint64 indexed epoch, bytes32 root, uint256 cumulativeTotal, string uri
    );
    event RewardClaimed(bytes32 indexed streamId, address indexed account, uint256 amount, uint256 cumulativeAmount);
    event UnallocatedReclaimed(bytes32 indexed streamId, address indexed funder, uint256 amount);
    event PublisherSet(address indexed publisher);
    event StreamFeeSet(uint16 bps, address indexed recipient);

    error NotFactory();
    error NotPublisher();
    error NotSelf();
    error InvalidConfig();
    error UnknownStream();
    error StreamExists();
    error RouteNotListed(address from, address to);
    error NothingToClose();
    error InvalidEpoch();
    error InvalidAllocation();
    error NoRoot();
    error InvalidProof();
    error ExceedsAllocation();
    error NothingToClaim();
    error InvalidPayment();
    error NotReclaimable();
    error NativeTransferFailed();

    constructor(address launchFactory, address initialOwner, address initialPublisher, uint16 feeBps, address fees)
        Ownable(initialOwner)
    {
        if (launchFactory.code.length == 0) revert InvalidConfig();
        factory = launchFactory;
        hook = IDistributorFactoryWiring(launchFactory).hook();
        poolManager = IPoolManager(IDistributorHookWiring(hook).poolManager());
        _setPublisher(initialPublisher);
        _setStreamFee(feeBps, fees);
    }

    receive() external payable {}

    // ───────────────────────────── Factory ─────────────────────────────

    /// @notice Registers the holder and/or trader stream of an Economy launch. Factory only, in the launch
    ///         transaction. The reward token must be the quote, the launch token or a registry-listed route target.
    function registerLaunch(LaunchStreams calldata p) external {
        if (msg.sender != factory) revert NotFactory();
        if (!p.holders && !p.traders) revert InvalidConfig();
        if (p.rewardToken != p.quote) {
            if (p.rewardRegistry == address(0)) revert RouteNotListed(p.quote, p.rewardToken);
            if (
                p.rewardToken != p.token
                    && IPlaceRewardTokenRegistry(p.rewardRegistry).routeOf(p.quote, p.rewardToken).length == 0
            ) revert RouteNotListed(p.quote, p.rewardToken);
        }
        if (p.holders) _registerLaunchStream(p, Kind.Holders, p.minHolding);
        if (p.traders) _registerLaunchStream(p, Kind.Traders, p.minDailyVolume);
    }

    function _registerLaunchStream(LaunchStreams calldata p, Kind kind, uint256 criterion) internal {
        bytes32 id = economyStreamId(p.token, kind);
        Stream storage s = _streams[id];
        if (s.token != address(0)) revert StreamExists();
        uint64 start = currentEpoch();
        s.token = p.token;
        s.kind = kind;
        s.economy = true;
        s.rewardToken = p.rewardToken;
        s.source = p.quote;
        s.rewardRegistry = p.rewardToken == p.quote ? address(0) : p.rewardRegistry;
        s.startEpoch = start;
        s.lastClosedEpoch = start - 1;
        s.criterion = criterion;
        if (p.rewardToken == p.token) _launchPool[id] = p.poolKey;
        emit LaunchStreamRegistered(id, p.token, kind, p.quote, p.rewardToken, criterion, start);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Funds a stream for any token up front: `rewardPerEpoch` x `epochCount` plus the stream fee, paid by
    ///         the caller (native currency as `msg.value`, tokens by allowance). The caller is the funder.
    function createStream(CreateParams calldata p) external payable nonReentrant returns (bytes32 id) {
        uint64 current = currentEpoch();
        if (
            p.token.code.length == 0 || p.epochCount == 0 || p.epochCount > MAX_EPOCHS || p.rewardPerEpoch == 0
                || p.startEpoch < current || p.startEpoch > current + MAX_START_DELAY_EPOCHS
        ) revert InvalidConfig();
        uint256 total = p.rewardPerEpoch * p.epochCount;
        uint256 fee = Math.mulDiv(total, streamFeeBps, BPS, Math.Rounding.Ceil);
        _pull(p.rewardToken, total + fee);
        if (fee != 0) _send(p.rewardToken, feeRecipient, fee);

        id = keccak256(abi.encode(address(this), ++streamNonce));
        Stream storage s = _streams[id];
        s.token = p.token;
        s.kind = p.kind;
        s.rewardToken = p.rewardToken;
        s.source = p.rewardToken;
        s.funder = msg.sender;
        s.startEpoch = p.startEpoch;
        s.epochCount = p.epochCount;
        s.lastClosedEpoch = p.startEpoch - 1;
        s.criterion = p.criterion;
        s.rewardPerEpoch = p.rewardPerEpoch;
        s.reserved = total;
        liabilities[p.rewardToken] += total;
        emit StreamCreated(
            id,
            p.token,
            p.kind,
            p.rewardToken,
            msg.sender,
            p.startEpoch,
            p.epochCount,
            p.rewardPerEpoch,
            p.criterion,
            fee,
            p.metadataURI
        );
    }

    /// @notice Closes the finished epochs of a launch's own streams (holders and traders). Anyone, once a day.
    function closeEpoch(address token) external nonReentrant {
        bool closed = _close(economyStreamId(token, Kind.Holders));
        if (_close(economyStreamId(token, Kind.Traders))) closed = true;
        if (!closed) revert NothingToClose();
    }

    /// @notice Closes the finished epochs of one stream. Anyone.
    function closeStream(bytes32 id) external nonReentrant {
        if (_streams[id].token == address(0)) revert UnknownStream();
        if (!_close(id)) revert NothingToClose();
    }

    /// @notice Keeper batch: closes every listed stream that has a finished epoch; skips the rest.
    function closeStreams(bytes32[] calldata ids) external nonReentrant returns (uint256 closedCount) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (_close(ids[i])) closedCount++;
        }
    }

    /// @notice Swaps up to `maxAmountIn` (0 = all) of an Economy stream's pending input into the reward token.
    ///         Anyone; used when the daily swap was deferred (price impact cap) to convert in smaller slices.
    function convert(bytes32 id, uint256 maxAmountIn) external nonReentrant returns (uint256 amountOut) {
        Stream storage s = _streams[id];
        if (!s.economy || s.rewardToken == s.source) revert InvalidConfig();
        uint256 amountIn = s.pendingInput;
        if (maxAmountIn != 0 && maxAmountIn < amountIn) amountIn = maxAmountIn;
        if (amountIn == 0) revert NothingToClose();
        amountOut = _convert(id, amountIn);
    }

    /// @dev External so `_close` can try it and keep the epoch closed if the swap fails.
    function convertFromClose(bytes32 id, uint256 amountIn) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        return _convert(id, amountIn);
    }

    /// @notice Pays `account` the difference between its cumulative amount in the stream's root and what it has
    ///         already claimed. Anyone may submit it; the reward always goes to `account`.
    function claim(bytes32 id, address account, uint256 cumulativeAmount, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = _claim(id, account, cumulativeAmount, proof);
        if (amount == 0) revert NothingToClaim();
    }

    /// @notice Claims many streams (e.g. every token in a profile) in one call. Fully claimed entries pay zero.
    function claimMany(ClaimRequest[] calldata requests) external nonReentrant returns (uint256[] memory amounts) {
        amounts = new uint256[](requests.length);
        for (uint256 i = 0; i < requests.length; i++) {
            ClaimRequest calldata r = requests[i];
            amounts[i] = _claim(r.streamId, r.account, r.cumulativeAmount, r.proof);
        }
    }

    /// @notice Returns a funded stream's unallocated budget to its funder, `RECLAIM_DELAY` after its last epoch.
    ///         Allocations already in the root stay claimable.
    function reclaimUnallocated(bytes32 id) external nonReentrant returns (uint256 amount) {
        Stream storage s = _streams[id];
        if (s.token == address(0) || s.economy) revert NotReclaimable();
        _close(id);
        uint64 lastEpoch = s.startEpoch + s.epochCount - 1;
        uint256 reclaimAt = uint256(lastEpoch + 1) * EPOCH_LENGTH + RECLAIM_DELAY;
        // forge-lint: disable-next-line(block-timestamp) measured in days
        if (s.lastClosedEpoch != lastEpoch || block.timestamp < reclaimAt) revert NotReclaimable();
        amount = s.funded - s.allocated;
        if (amount == 0) revert NothingToClaim();
        s.funded = s.allocated;
        liabilities[s.rewardToken] -= amount;
        _send(s.rewardToken, s.funder, amount);
        emit UnallocatedReclaimed(id, s.funder, amount);
    }

    // ───────────────────────────── Publisher ─────────────────────────────

    /// @notice Posts a stream's cumulative root for the closed epochs up to `epoch`. The total may only grow and
    ///         never above what the stream has funded.
    function publishRoot(RootUpdate calldata update) external {
        if (msg.sender != publisher) revert NotPublisher();
        _publish(update);
    }

    function publishRoots(RootUpdate[] calldata updates) external {
        if (msg.sender != publisher) revert NotPublisher();
        for (uint256 i = 0; i < updates.length; i++) {
            _publish(updates[i]);
        }
    }

    // ───────────────────────────── Owner ─────────────────────────────

    function setPublisher(address newPublisher) external onlyOwner {
        _setPublisher(newPublisher);
    }

    /// @notice Fee on funded streams (capped at 10%). Economy streams pay none: the platform already takes its cut
    ///         of the tax.
    function setStreamFee(uint16 bps, address recipient) external onlyOwner {
        _setStreamFee(bps, recipient);
    }

    // ───────────────────────────── Views ─────────────────────────────

    function currentEpoch() public view returns (uint64) {
        return uint64(block.timestamp / EPOCH_LENGTH);
    }

    function economyStreamId(address token, Kind kind) public pure returns (bytes32) {
        return PlaceSuiteConstants.economyStreamId(token, uint8(kind));
    }

    function stream(bytes32 id) external view returns (Stream memory) {
        return _streams[id];
    }

    function launchPool(bytes32 id) external view returns (PoolKey memory) {
        return _launchPool[id];
    }

    /// @notice Tax waiting in the FeeEscrow for an Economy stream (not yet collected).
    function pendingCollection(bytes32 id) external view returns (uint256) {
        Stream storage s = _streams[id];
        if (!s.economy) return 0;
        return IFeeEscrowClaims(IDistributorHookWiring(hook).feeEscrow()).accountOwed(address(this), id, s.source);
    }

    /// @notice Whether `closeStream(id)` would close an epoch now.
    function closable(bytes32 id) external view returns (bool) {
        Stream storage s = _streams[id];
        return s.token != address(0) && _closeTarget(s) > s.lastClosedEpoch;
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    /// @dev The last epoch that can be closed now: yesterday, capped at a funded stream's last epoch.
    function _closeTarget(Stream storage s) internal view returns (uint64 target) {
        target = currentEpoch() - 1;
        if (s.epochCount != 0) {
            uint64 last = s.startEpoch + s.epochCount - 1;
            if (target > last) target = last;
        }
    }

    function _close(bytes32 id) internal returns (bool) {
        Stream storage s = _streams[id];
        if (s.token == address(0)) return false;
        uint64 target = _closeTarget(s);
        uint64 previous = s.lastClosedEpoch;
        if (target <= previous) return false;
        s.lastClosedEpoch = target;
        uint256 collected;
        if (s.economy) {
            collected = _collectEscrow(id, s.source);
            if (collected != 0) {
                liabilities[s.source] += collected;
                if (s.rewardToken == s.source) s.funded += collected;
                else s.pendingInput += collected;
            }
            uint256 pending = s.pendingInput;
            if (pending != 0) {
                try this.convertFromClose(id, pending) {}
                catch (bytes memory reason) {
                    emit ConversionDeferred(id, pending, reason);
                }
            }
        } else {
            uint256 release = s.rewardPerEpoch * (target - previous);
            if (release > s.reserved) release = s.reserved;
            s.reserved -= release;
            s.funded += release;
        }
        emit EpochClosed(id, target, collected, s.funded);
        return true;
    }

    function _collectEscrow(bytes32 id, address asset) internal returns (uint256) {
        IFeeEscrowClaims escrow = IFeeEscrowClaims(IDistributorHookWiring(hook).feeEscrow());
        if (escrow.accountOwed(address(this), id, asset) == 0) return 0;
        uint256 before = _balanceOf(asset);
        escrow.claimAccount(id, asset);
        return _balanceOf(asset) - before;
    }

    function _convert(bytes32 id, uint256 amountIn) internal returns (uint256 out) {
        Stream storage s = _streams[id];
        PoolKey[] memory hops;
        if (s.rewardToken == s.token) {
            hops = new PoolKey[](1);
            hops[0] = _launchPool[id];
        } else {
            hops = IPlaceRewardTokenRegistry(s.rewardRegistry).routeOf(s.source, s.rewardToken);
            if (hops.length == 0) revert RouteNotListed(s.source, s.rewardToken);
        }
        uint256 maxImpact = IPlaceRewardTokenRegistry(s.rewardRegistry).maxPriceImpactBps();
        uint256 paid;
        (paid, out) = _swapRoute(s.source, hops, amountIn, maxImpact);
        s.pendingInput -= paid;
        liabilities[s.source] -= paid;
        s.funded += out;
        liabilities[s.rewardToken] += out;
        emit Converted(id, paid, out);
    }

    function _publish(RootUpdate calldata u) internal {
        Stream storage s = _streams[u.streamId];
        if (s.token == address(0)) revert UnknownStream();
        if (u.epoch < s.startEpoch || u.epoch > s.lastClosedEpoch || u.epoch < s.rootEpoch) revert InvalidEpoch();
        if (u.root == bytes32(0) || u.cumulativeTotal < s.allocated || u.cumulativeTotal > s.funded) {
            revert InvalidAllocation();
        }
        s.root = u.root;
        s.rootEpoch = u.epoch;
        s.allocated = u.cumulativeTotal;
        emit RootPublished(u.streamId, u.epoch, u.root, u.cumulativeTotal, u.uri);
    }

    function _claim(bytes32 id, address account, uint256 cumulativeAmount, bytes32[] calldata proof)
        internal
        returns (uint256 due)
    {
        Stream storage s = _streams[id];
        if (s.root == bytes32(0)) revert NoRoot();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(id, account, cumulativeAmount))));
        if (!MerkleProof.verifyCalldata(proof, s.root, leaf)) revert InvalidProof();
        uint256 already = claimedBy[id][account];
        if (cumulativeAmount <= already) return 0;
        due = cumulativeAmount - already;
        if (s.claimed + due > s.allocated) revert ExceedsAllocation();
        claimedBy[id][account] = cumulativeAmount;
        s.claimed += due;
        liabilities[s.rewardToken] -= due;
        _send(s.rewardToken, account, due);
        emit RewardClaimed(id, account, due, cumulativeAmount);
    }

    function _pull(address asset, uint256 amount) internal {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidPayment();
            return;
        }
        if (msg.value != 0) revert InvalidPayment();
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert InvalidPayment();
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _balanceOf(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    function _setPublisher(address newPublisher) internal {
        publisher = newPublisher;
        emit PublisherSet(newPublisher);
    }

    function _setStreamFee(uint16 bps, address recipient) internal {
        if (bps > MAX_STREAM_FEE_BPS || (bps != 0 && recipient == address(0))) revert InvalidConfig();
        streamFeeBps = bps;
        feeRecipient = recipient;
        emit StreamFeeSet(bps, recipient);
    }
}
