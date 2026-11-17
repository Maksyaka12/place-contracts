// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceRouteSwapper} from "./PlaceRouteSwapper.sol";
import {IPlaceRewardsDistributor} from "./interfaces/IPlaceRewardsDistributor.sol";
import {IPlaceStaking} from "./interfaces/IPlaceStaking.sol";
import {IPlaceRewardTokenRegistry} from "./interfaces/IPlaceRewardTokenRegistry.sol";
import {IFeeEscrowClaims, ICreatorOf} from "./interfaces/IPlaceLaunchViews.sol";
import {IPlaceNftFactory, IPlaceNftCollection, IPlacePriceGuard} from "../nft/interfaces/IPlaceNft.sol";

interface ICommunityHookWiring {
    function poolManager() external view returns (address);
}

/// @title PlaceCommunityVault
/// @notice The Community Pool of one Economy launch (a clone per launch). It receives the launch's community
///         basket of every trade. **Nobody can withdraw it**: the funds leave only into reward programs for this
///         token, which the creator (current holder of the creator rights) starts:
///         - `fundCampaign`: a daily holders or traders stream in the PlaceRewardsDistributor for this token, funded
///           for N epochs;
///         - `fundStaking`: a PlaceStaking program for stakers of this token;
///         - `fundNftCampaign`: a daily NFT holders stream for an official, paid PlaceNftCollection of this token
///           (at most `MAX_NFT_CAMPAIGN_BPS` of the fund's balance, once per `NFT_CAMPAIGN_COOLDOWN`);
///         - `buybackAndBurn`: buys this token with the fund and sends it to 0x…dEaD, within the registry's
///           per-hop price impact cap and the PlacePriceGuard reference price.
///         The reward can be any token of the PlaceRewardTokenRegistry white list (or this token through its own
///         pool): the vault swaps the fund along the listed route, with the creator's `minOut` and the registry's
///         per-hop price impact cap, in the same transaction. If the fund is not spent for `defaultCampaignDelay`
///         (30 days), anyone starts the default campaign: the whole fund in the quote becomes a holders stream.
/// @dev    Everything the vault holds belongs to the fund: the community basket, refunds of unallocated stream
///         budgets, staking leftovers, swap outputs and donations.
contract PlaceCommunityVault is Initializable, ReentrancyGuard, PlaceRouteSwapper {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice An NFT campaign may spend at most 25% of the fund's balance in the spent asset.
    uint256 public constant MAX_NFT_CAMPAIGN_BPS = 2_500;
    uint64 public constant NFT_CAMPAIGN_COOLDOWN = 30 days;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice Place NFT factory whose official collections of this token can get campaigns (zero: none).
    IPlaceNftFactory public immutable nftFactory;
    /// @notice Reference prices for buybacks (zero: buybacks only burn tokens the fund already holds).
    IPlacePriceGuard public immutable priceGuard;

    struct Initialization {
        address token;
        PoolKey poolKey;
        address feeEscrow;
        address distributor;
        address staking; // zero: no staking programs
        address rewardRegistry; // zero: the fund cannot swap
        uint64 defaultCampaignDelay;
        uint64 defaultCampaignEpochs;
        uint128 defaultCampaignMinimum; // quote units
        uint256 defaultMinHolding; // holders threshold of the default campaign
    }

    /// @notice A holders or traders stream for this token, paid from the fund (creator only).
    struct CampaignRequest {
        IPlaceRewardsDistributor.Kind kind;
        address fundAsset; // what the fund spends: the quote or another asset the fund holds
        uint256 amountIn; // how much of it, stream fee included
        address rewardToken; // == fundAsset: no swap; else a listed route (or this token through its own pool)
        uint256 minOut; // minimum reward tokens out of the swap
        uint64 startEpoch;
        uint64 epochCount;
        uint256 criterion; // minimum holding (holders) or minimum daily volume (traders)
        string metadataURI;
    }

    /// @notice A daily NFT holders stream for a PlaceNftCollection of this token, paid from the fund (creator only).
    struct NftCampaignRequest {
        address collection;
        address fundAsset;
        uint256 amountIn; // stream fee included; at most MAX_NFT_CAMPAIGN_BPS of the fund in fundAsset
        address rewardToken;
        uint256 minOut;
        uint64 startEpoch;
        uint64 epochCount;
        uint256 minNfts; // NFTs a wallet must hold
        string metadataURI;
    }

    /// @notice Buy back this token with the fund and burn it (creator only).
    struct BuybackRequest {
        address fundAsset; // this token: burned as is; the quote: through the launch pool; else a listed route
        uint256 amountIn;
        uint256 minOut; // the creator's own floor, on top of the guard's
    }

    /// @notice A PlaceStaking program for this token, paid from the fund (creator only).
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
    IPlaceRewardsDistributor public distributor;
    address public token;
    address public quote;
    PoolKey internal _poolKey;
    Initialization internal _settings;

    uint64 public lastFundSpendAt;
    uint64 public lastNftCampaignAt;
    /// @notice Tokens of this launch the vault has burned.
    uint256 public totalBurned;

    event Collected(uint256 amount);
    event FundSwapped(address indexed fundAsset, address indexed rewardToken, uint256 amountIn, uint256 amountOut);
    event FundCampaignCreated(
        bytes32 indexed streamId,
        IPlaceRewardsDistributor.Kind indexed kind,
        address indexed rewardToken,
        uint256 rewardPerEpoch,
        uint64 epochCount,
        uint256 paid,
        bool isDefault
    );
    event FundNftCampaignCreated(bytes32 indexed streamId, address indexed collection);
    event FundBurned(address indexed fundAsset, uint256 amountIn, uint256 tokensBurned);
    event FundStakingCreated(
        bytes32 indexed stakingVaultId,
        address indexed rewardToken,
        uint256 rewardPerEpoch,
        uint64 epochCount,
        uint256 paid
    );

    error NotCreator();
    error InvalidConfig();
    error StakingDisabled();
    error DefaultCampaignTooSoon(uint64 nextAt);
    error FundTooSmall(uint256 available, uint256 needed);
    error RouteNotListed(address fundAsset, address rewardToken);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    error InvalidCollection();
    error NftCampaignTooSoon(uint64 nextAt);
    error NftCampaignTooLarge(uint256 amountIn, uint256 maxIn);
    error BuybackDisabled();

    /// @param placeNftFactory Place NFT factory (zero: no NFT campaigns).
    /// @param guard           PlacePriceGuard (zero: buybacks only burn tokens the fund already holds).
    constructor(address placeNftFactory, address guard) {
        nftFactory = IPlaceNftFactory(placeNftFactory);
        priceGuard = IPlacePriceGuard(guard);
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Called once by the factory in the launch transaction, before the hook registers the pool.
    function initialize(Initialization calldata init) external initializer {
        if (
            init.distributor == address(0) || init.defaultCampaignDelay == 0 || init.defaultCampaignEpochs == 0
                || init.defaultCampaignEpochs > 365
        ) revert InvalidConfig();
        factory = msg.sender;
        token = init.token;
        _poolKey = init.poolKey;
        bool tokenIsCurrency0 = Currency.unwrap(init.poolKey.currency0) == init.token;
        quote = Currency.unwrap(tokenIsCurrency0 ? init.poolKey.currency1 : init.poolKey.currency0);
        poolManager = IPoolManager(ICommunityHookWiring(address(init.poolKey.hooks)).poolManager());
        feeEscrow = IFeeEscrowClaims(init.feeEscrow);
        distributor = IPlaceRewardsDistributor(init.distributor);
        _settings = init;
        lastFundSpendAt = uint64(block.timestamp);
    }

    // ───────────────────────────── Anyone ─────────────────────────────

    /// @notice Pulls the community basket from the FeeEscrow. Permissionless; moves no tokens out of the vault.
    function collect() external nonReentrant returns (uint256 amount) {
        return _collect();
    }

    /// @notice If the creator has not spent the fund for `defaultCampaignDelay`, anyone turns the whole fund (in
    ///         the quote) into a holders stream for this token: reward in the quote, starting tomorrow, for
    ///         `defaultCampaignEpochs` days, threshold `defaultMinHolding`.
    function startDefaultCampaign() external nonReentrant returns (bytes32 streamId) {
        uint64 nextAt = lastFundSpendAt + _settings.defaultCampaignDelay;
        // forge-lint: disable-next-line(block-timestamp) measured in days
        if (block.timestamp < nextAt) revert DefaultCampaignTooSoon(nextAt);
        _collect();
        uint256 available = fundBalance(quote);
        uint256 minimum = _settings.defaultCampaignMinimum == 0 ? 1 : _settings.defaultCampaignMinimum;
        if (available < minimum) revert FundTooSmall(available, minimum);
        lastFundSpendAt = uint64(block.timestamp);
        streamId = _createStream(
            token,
            IPlaceRewardsDistributor.Kind.Holders,
            quote,
            available,
            distributor.currentEpoch() + 1,
            _settings.defaultCampaignEpochs,
            _settings.defaultMinHolding,
            "",
            true
        );
    }

    // ───────────────────────────── Creator ─────────────────────────────

    /// @notice A daily holders or traders stream for this token from the fund. The target (this token) is fixed;
    ///         the creator picks the amount, the reward token from the white list, the start, the number of daily
    ///         epochs and the threshold. The stream fee comes out of `amountIn`.
    function fundCampaign(CampaignRequest calldata r) external nonReentrant returns (bytes32 streamId) {
        _requireCreator();
        uint256 budget = _spendFund(r.fundAsset, r.amountIn, r.rewardToken, r.minOut);
        streamId = _createStream(
            token, r.kind, r.rewardToken, budget, r.startEpoch, r.epochCount, r.criterion, r.metadataURI, false
        );
    }

    /// @notice A daily NFT holders stream for `r.collection` from the fund. The collection must be made by the Place
    ///         NFT factory for this token, be official (made by the token's creator), have a non-zero mint price
    ///         (with a free mint the creator could mint the whole collection to own wallets at no cost) and at
    ///         least one NFT. Limits: `MAX_NFT_CAMPAIGN_BPS` of the fund in `fundAsset`, one campaign per
    ///         `NFT_CAMPAIGN_COOLDOWN`.
    function fundNftCampaign(NftCampaignRequest calldata r) external nonReentrant returns (bytes32 streamId) {
        _requireCreator();
        IPlaceNftCollection c = IPlaceNftCollection(r.collection);
        if (
            address(nftFactory) == address(0) || !nftFactory.isCollection(r.collection) || c.token() != token
                || !c.official() || c.mintPrice() == 0 || c.totalMinted() == 0
        ) revert InvalidCollection();
        uint64 nextAt = lastNftCampaignAt == 0 ? 0 : lastNftCampaignAt + NFT_CAMPAIGN_COOLDOWN;
        // forge-lint: disable-next-line(block-timestamp) measured in days
        if (block.timestamp < nextAt) revert NftCampaignTooSoon(nextAt);
        _collect();
        uint256 maxIn = fundBalance(r.fundAsset) * MAX_NFT_CAMPAIGN_BPS / BPS;
        if (r.amountIn > maxIn) revert NftCampaignTooLarge(r.amountIn, maxIn);
        lastNftCampaignAt = uint64(block.timestamp);
        uint256 budget = _spendFund(r.fundAsset, r.amountIn, r.rewardToken, r.minOut);
        streamId = _createStream(
            r.collection,
            IPlaceRewardsDistributor.Kind.Holders,
            r.rewardToken,
            budget,
            r.startEpoch,
            r.epochCount,
            r.minNfts,
            r.metadataURI,
            false
        );
        emit FundNftCampaignCreated(streamId, r.collection);
    }

    /// @notice Buys this token with `amountIn` of `fundAsset` and burns it (0x…dEaD); tokens of this launch the
    ///         fund holds are burned as they are. A swap goes through this launch's pool (from the quote) or a listed
    ///         registry route; each hop may move its pool by at most the registry's `maxPriceImpactBps`, and the
    ///         output must reach the PlacePriceGuard reference output minus (max deviation + impact per hop) and
    ///         `minOut`, so a sandwich around the call makes it revert.
    function buybackAndBurn(BuybackRequest calldata r) external nonReentrant returns (uint256 burned) {
        _requireCreator();
        _collect();
        uint256 available = fundBalance(r.fundAsset);
        if (r.amountIn == 0 || r.amountIn > available) revert FundTooSmall(available, r.amountIn);
        lastFundSpendAt = uint64(block.timestamp);
        if (r.fundAsset == token) {
            burned = r.amountIn;
        } else {
            address registry = _settings.rewardRegistry;
            if (address(priceGuard) == address(0) || registry == address(0)) revert BuybackDisabled();
            PoolKey[] memory hops;
            if (r.fundAsset == quote) {
                hops = new PoolKey[](1);
                hops[0] = _poolKey;
            } else {
                hops = IPlaceRewardTokenRegistry(registry).routeOf(r.fundAsset, token);
                if (hops.length == 0) revert RouteNotListed(r.fundAsset, token);
            }
            (uint256 referenceOut,) = priceGuard.quote(hops, r.fundAsset, r.amountIn);
            priceGuard.observeRoute(hops);
            uint16 impact = IPlaceRewardTokenRegistry(registry).maxPriceImpactBps();
            uint256 tolerance = uint256(priceGuard.config().maxDeviationBps) + uint256(impact) * hops.length;
            uint256 floor = tolerance >= BPS ? 0 : referenceOut * (BPS - tolerance) / BPS;
            if (r.minOut > floor) floor = r.minOut;
            (, burned) = _swapRoute(r.fundAsset, hops, r.amountIn, impact);
            if (burned < floor) revert SlippageExceeded(burned, floor);
        }
        totalBurned += burned;
        IERC20(token).safeTransfer(BURN_SINK, burned);
        emit FundBurned(r.fundAsset, r.amountIn, burned);
    }

    /// @notice A PlaceStaking program for stakers of this token from the fund: the whole swap output, minus the
    ///         staking fee, becomes the program's budget (`rewardPerEpoch` x `epochCount`); rounding dust stays.
    function fundStaking(StakingRequest calldata r) external nonReentrant returns (bytes32 stakingVaultId) {
        _requireCreator();
        IPlaceStaking staking = IPlaceStaking(_settings.staking);
        if (address(staking) == address(0)) revert StakingDisabled();
        if (r.epochCount == 0) revert InvalidConfig();
        uint256 budget = _spendFund(r.fundAsset, r.amountIn, r.rewardToken, r.minOut);
        (uint16 feeBps,, uint64 version) = staking.feeConfig();
        uint256 perEpoch = _perEpoch(budget, r.epochCount, feeBps);
        if (perEpoch > type(uint192).max) perEpoch = type(uint192).max;
        uint256 total = _withFee(perEpoch, r.epochCount, feeBps);
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

    // ───────────────────────────── Views ─────────────────────────────

    function currentCreator() public view returns (address) {
        return ICreatorOf(factory).currentCreatorOf(token);
    }

    /// @notice The fund held in `asset` (not counting the community basket still in the FeeEscrow).
    function fundBalance(address asset) public view returns (uint256) {
        return asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
    }

    /// @notice Community basket waiting in the FeeEscrow (not yet collected).
    function pendingFees() external view returns (uint256) {
        return feeEscrow.owed(address(this), quote);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function settings() external view returns (Initialization memory) {
        return _settings;
    }

    // ───────────────────────────── Internals ─────────────────────────────

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    function _collect() internal returns (uint256 amount) {
        amount = feeEscrow.owed(address(this), quote);
        if (amount == 0) return 0;
        feeEscrow.claimFor(address(this), quote);
        emit Collected(amount);
    }

    /// @dev Takes `amountIn` of `fundAsset` from the fund and, if needed, swaps it into `rewardToken` along the
    ///      listed route. Returns the reward tokens now set aside for the program (held by the vault).
    function _spendFund(address fundAsset, uint256 amountIn, address rewardToken, uint256 minOut)
        internal
        returns (uint256 out)
    {
        _collect();
        uint256 available = fundBalance(fundAsset);
        if (amountIn == 0 || amountIn > available) revert FundTooSmall(available, amountIn);
        lastFundSpendAt = uint64(block.timestamp);
        if (rewardToken == fundAsset) return amountIn;
        address registry = _settings.rewardRegistry;
        PoolKey[] memory hops;
        if (fundAsset == quote && rewardToken == token) {
            hops = new PoolKey[](1);
            hops[0] = _poolKey;
        } else if (registry != address(0)) {
            hops = IPlaceRewardTokenRegistry(registry).routeOf(fundAsset, rewardToken);
        }
        if (hops.length == 0 || registry == address(0)) revert RouteNotListed(fundAsset, rewardToken);
        uint256 paid;
        (paid, out) = _swapRoute(fundAsset, hops, amountIn, IPlaceRewardTokenRegistry(registry).maxPriceImpactBps());
        if (out < minOut) revert SlippageExceeded(out, minOut);
        emit FundSwapped(fundAsset, rewardToken, paid, out);
    }

    function _createStream(
        address target,
        IPlaceRewardsDistributor.Kind kind,
        address rewardToken,
        uint256 budget,
        uint64 startEpoch,
        uint64 epochCount,
        uint256 criterion,
        string memory metadataURI,
        bool isDefault
    ) internal returns (bytes32 streamId) {
        if (epochCount == 0) revert InvalidConfig();
        uint16 feeBps = distributor.streamFeeBps();
        uint256 perEpoch = _perEpoch(budget, epochCount, feeBps);
        uint256 total = _withFee(perEpoch, epochCount, feeBps);
        IPlaceRewardsDistributor.CreateParams memory p = IPlaceRewardsDistributor.CreateParams({
            token: target,
            kind: kind,
            rewardToken: rewardToken,
            startEpoch: startEpoch,
            epochCount: epochCount,
            rewardPerEpoch: perEpoch,
            criterion: criterion,
            metadataURI: metadataURI
        });
        if (rewardToken == address(0)) {
            streamId = distributor.createStream{value: total}(p);
        } else {
            IERC20(rewardToken).forceApprove(address(distributor), total);
            streamId = distributor.createStream(p);
            IERC20(rewardToken).forceApprove(address(distributor), 0);
        }
        emit FundCampaignCreated(streamId, kind, rewardToken, perEpoch, epochCount, total, isDefault);
    }

    /// @dev The largest per-epoch reward whose total with the (rounded-up) fee fits in `budget`.
    function _perEpoch(uint256 budget, uint64 epochCount, uint16 feeBps) internal pure returns (uint256 perEpoch) {
        perEpoch = budget * BPS / (BPS + uint256(feeBps)) / epochCount;
        while (perEpoch != 0 && _withFee(perEpoch, epochCount, feeBps) > budget) perEpoch--;
        if (perEpoch == 0) revert FundTooSmall(budget, epochCount);
    }

    function _withFee(uint256 perEpoch, uint64 epochCount, uint16 feeBps) internal pure returns (uint256) {
        uint256 reward = perEpoch * epochCount;
        return reward + Math.mulDiv(reward, feeBps, BPS, Math.Rounding.Ceil);
    }

    function _requireCreator() internal view {
        if (msg.sender != currentCreator()) revert NotCreator();
    }
}
