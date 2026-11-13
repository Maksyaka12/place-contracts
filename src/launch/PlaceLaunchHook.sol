// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;
import {PlaceSuiteConstants} from "./PlaceSuiteConstants.sol";

import {BaseHook} from "../base/BaseHook.sol";
import {FeeEscrow} from "../FeeEscrow.sol";
import {PlaceFeeMath} from "./PlaceFeeMath.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

import {ILaunchBuyAdapter} from "../interfaces/ILaunchBuyAdapter.sol";

interface IWiredFactory {
    function hook() external view returns (address launchHook);
    function poolManager() external view returns (address manager);
    function isFactoryToken(address token) external view returns (bool);
}

/// @title PlaceLaunchHook
/// @notice The single shared Uniswap v4 hook for every launch in one deployment suite. It:
///         - gates pool creation to the launchpad factory (`beforeInitialize`),
///         - blocks all third-party liquidity adds/removes, and owns the permanently locked
///           single-sided genesis-band positions (no code path ever passes a negative liquidityDelta),
///         - on every swap takes a fee on the quote currency as an ERC-6909 claim minted to the
///           FeeEscrow, split into inclusive protocol and remainder allocations; temporary anti-sniping
///           surcharge goes to the frozen protocol recipient. Burn credits redeem later to the fixed sink.
/// @dev    One deployment, reused by all launches; per-pool economics are frozen at launch in `poolConfig`.
///         Deployed at a CREATE2-mined address whose low 14 bits equal `getHookPermissions()` (BaseHook
///         validates this in the constructor). Fee custody lives in the FeeEscrow, not here.
contract PlaceLaunchHook is BaseHook, Initializable {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @notice Inclusive ordinary tax plus temporary surcharge stays strictly below 100%.
    uint32 public constant MAX_TOTAL_FEE_RATE = PlaceSuiteConstants.MAX_TOTAL_FEE_RATE;
    uint256 public constant RATE_SCALE = PlaceSuiteConstants.RATE_SCALE;
    address public constant BURN_SINK = PlaceSuiteConstants.BURN_SINK;
    uint256 public constant MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH = PlaceSuiteConstants.MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH;

    /// @notice Per-pool economics, frozen at launch. Only the creator and creator fee recipient can change
    ///         later, through the factory's creator rights functions.
    struct PoolConfig {
        bool initialized;
        bool tokenIsCurrency0;
        address token;
        address quoteToken;
        address currentCreator;
        address creatorFeeRecipient;
        PlaceFeeMath.ProtocolFeeConfiguration protocolFeeConfiguration;
        PlaceFeeMath.AntiSnipeConfiguration antiSnipeConfiguration;
        uint48 launchTime;
        bool antiSnipeEnabled;
        address integratorFeeRecipient;
        PlaceFeeMath.TaxConfiguration taxConfiguration;
    }

    struct PoolRegistration {
        address token;
        address creator;
        address creatorFeeRecipient;
        address integratorFeeRecipient;
        uint48 launchTime;
        bool antiSnipeEnabled;
        PlaceFeeMath.TaxPolicy admittedPolicy;
        PlaceFeeMath.TaxConfiguration taxConfiguration;
    }

    enum LaunchBuyContextState {
        NONE,
        ARMED,
        EXECUTING,
        CONSUMED
    }

    struct LaunchBuyContext {
        LaunchBuyContextState state;
        PoolId poolId;
        address swapCaller;
    }

    /// @notice A resolved single-sided liquidity band, computed by the factory and seeded here.
    struct SeedPosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The address allowed to wire `factory`/`feeEscrow` exactly once (the deployer/deploy script).
    address public immutable deployer;

    address public factory;
    address public feeEscrow;
    address public launchBuyAdapter;
    bool public wired;

    mapping(PoolId poolId => PoolConfig configuration) public poolConfig;
    LaunchBuyContext internal _launchBuyContext;

    error NotDeployer();
    error NotFactory();
    error NotWired();
    error ZeroAddress();
    error BadWiring();
    error AlreadyRegistered();
    error LiquidityLocked();
    error NotSingleSided();
    error InvalidFeeConfig();
    error AntiSnipeUnavailable();
    error ExactOutputDisabledDuringAntiSnipe();
    error PartialFillUnsupported();
    error LaunchBuyContextActive();
    error LaunchBuyContextMissing();
    error LaunchBuyContextMismatch(
        PoolId expectedPoolId, PoolId actualPoolId, address expectedSwapCaller, address actualSwapCaller
    );
    error LaunchBuyContextNotConsumed();
    error LaunchBuyMultipleSwaps();
    error InvalidLaunchBuyDirection();
    error LaunchBuyExactOutputUnsupported();
    error ZeroLaunchBuyOutput();
    error LaunchBuyAdapterNotConfigured();
    error InvalidLaunchBuyAdapter(address adapter);
    error InvalidLaunchBuyRequest();

    event BurnTaxCredited(PoolId indexed poolId, address indexed token, address indexed sink, uint256 amount);
    event CreatorTaxCredited(PoolId indexed poolId, address indexed recipient, address currency, uint256 amount);
    event IntegratorAttributed(PoolId indexed poolId, address indexed integratorFeeRecipient);
    event ProtocolFeeCredited(PoolId indexed poolId, address indexed recipient, address currency, uint256 amount);
    event IntegratorTaxCredited(PoolId indexed poolId, address indexed recipient, address currency, uint256 amount);
    event AntiSnipeFeeCredited(PoolId indexed poolId, address indexed recipient, address currency, uint256 amount);
    event Wired(address indexed factory, address indexed feeEscrow);
    event PoolRegistered(PoolId indexed poolId, address indexed originalCreator, address indexed creatorFeeRecipient);
    event CreatorRightsUpdated(
        PoolId indexed poolId,
        address indexed previousCreator,
        address indexed newCreator,
        address previousCreatorFeeRecipient,
        address newCreatorFeeRecipient
    );
    event Seeded(PoolId indexed poolId, uint256 tokenAmountSeeded);
    /// @notice One record per successful registered-pool swap, including zero rounded quote fees.
    /// @dev quoteCurrency/quoteFeeAmount cover quote fees only; BurnTaxCredited records launched-token allocation.
    ///      `referrer` is always zero and remains for event compatibility.
    event Trade(
        PoolId indexed poolId,
        address indexed executor,
        address indexed referrer,
        address quoteCurrency,
        uint256 quoteFeeAmount,
        bytes32 comment
    );

    constructor(IPoolManager poolManagerAddress, address hookDeployer) BaseHook(poolManagerAddress) {
        address manager = address(poolManagerAddress);
        if (
            manager == address(0) || manager.code.length == 0 || hookDeployer == address(0)
                || hookDeployer == address(this) || hookDeployer == manager
        ) revert BadWiring();
        deployer = hookDeployer;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice One-time wiring of the factory + fee escrow (breaks the deploy cycle: hook is deployed first).
    /// @dev    Guarded by OpenZeppelin's `initializer` modifier (set-once, the standard initialization pattern)
    ///         on top of the deployer-only authorization check, so it can never be re-run. To also close the
    ///         deploy-time window, only the designated initializer can complete wiring. Launch creation
    ///         stays disabled until the owner enables it.
    function initialize(address factoryAddress, address feeEscrowAddress) external initializer {
        if (msg.sender != deployer) revert NotDeployer();
        if (factoryAddress == address(0) || feeEscrowAddress == address(0)) revert ZeroAddress();
        // The hook is the single shared, un-re-wireable instance, so a mis-wire bricks every launch with no
        // recovery. Bind both sides: the factory and escrow must already point back at this exact hook (and
        // the escrow at the same PoolManager) or wiring fails closed instead of silently.
        if (factoryAddress.code.length == 0 || feeEscrowAddress.code.length == 0) revert BadWiring();
        if (IWiredFactory(factoryAddress).hook() != address(this)) revert BadWiring();
        if (IWiredFactory(factoryAddress).poolManager() != address(poolManager)) revert BadWiring();
        if (FeeEscrow(feeEscrowAddress).hook() != address(this)) revert BadWiring();
        if (address(FeeEscrow(feeEscrowAddress).poolManager()) != address(poolManager)) revert BadWiring();
        factory = factoryAddress;
        feeEscrow = feeEscrowAddress;
        wired = true;
        emit Wired(factoryAddress, feeEscrowAddress);
    }

    // ---- factory-only setup ----

    function registerPool(PoolKey calldata key, PoolRegistration calldata registration) external {
        if (msg.sender != factory) revert NotFactory();
        if (address(key.hooks) != address(this) || key.fee != 0 || registration.token == address(0)) {
            revert BadWiring();
        }
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == registration.token;
        if (!tokenIsCurrency0 && Currency.unwrap(key.currency1) != registration.token) revert BadWiring();
        address quoteToken = Currency.unwrap(tokenIsCurrency0 ? key.currency1 : key.currency0);
        _validateRegistration(registration);
        // Place: B20 tokens have no `factory()` getter, so the factory's own registry vouches for the token.
        if (!IWiredFactory(factory).isFactoryToken(registration.token)) revert BadWiring();
        PoolId poolId = key.toId();
        if (poolConfig[poolId].initialized) revert AlreadyRegistered();
        poolConfig[poolId] = PoolConfig({
            initialized: true,
            tokenIsCurrency0: tokenIsCurrency0,
            token: registration.token,
            quoteToken: quoteToken,
            currentCreator: registration.creator,
            creatorFeeRecipient: registration.creatorFeeRecipient,
            protocolFeeConfiguration: registration.admittedPolicy.protocolFeeConfiguration,
            antiSnipeConfiguration: registration.admittedPolicy.antiSnipeConfiguration,
            launchTime: registration.launchTime,
            antiSnipeEnabled: registration.antiSnipeEnabled,
            integratorFeeRecipient: registration.integratorFeeRecipient,
            taxConfiguration: registration.taxConfiguration
        });
        emit IntegratorAttributed(poolId, registration.integratorFeeRecipient);
        emit PoolRegistered(poolId, registration.creator, registration.creatorFeeRecipient);
    }

    function updateCreatorRights(PoolId poolId, address newCreator, address newCreatorFeeRecipient) external {
        if (msg.sender != factory) revert NotFactory();
        PoolConfig storage configuration = poolConfig[poolId];
        if (!configuration.initialized) revert InvalidFeeConfig();
        if (newCreator == address(0) || newCreatorFeeRecipient == address(0)) revert InvalidFeeConfig();
        // Place: the creator fee recipient (the launch's PlaceCreatorVault) is fixed at registration.
        if (newCreatorFeeRecipient != configuration.creatorFeeRecipient) revert InvalidFeeConfig();
        address previousCreator = configuration.currentCreator;
        address previousCreatorFeeRecipient = configuration.creatorFeeRecipient;
        configuration.currentCreator = newCreator;
        configuration.creatorFeeRecipient = newCreatorFeeRecipient;
        emit CreatorRightsUpdated(
            poolId, previousCreator, newCreator, previousCreatorFeeRecipient, newCreatorFeeRecipient
        );
    }

    function setLaunchBuyAdapter(address newLaunchBuyAdapter) external {
        if (msg.sender != factory) revert NotFactory();
        if (_launchBuyContext.state != LaunchBuyContextState.NONE) revert LaunchBuyContextActive();
        if (newLaunchBuyAdapter != address(0)) _validateLaunchBuyAdapter(newLaunchBuyAdapter);
        launchBuyAdapter = newLaunchBuyAdapter;
    }

    function executeLaunchBuy(PoolId poolId, ILaunchBuyAdapter.LaunchBuyRequest calldata request)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.sender != factory) revert NotFactory();
        address adapter = launchBuyAdapter;
        if (adapter == address(0)) revert LaunchBuyAdapterNotConfigured();
        if (
            PoolId.unwrap(request.poolKey.toId()) != PoolId.unwrap(poolId) || request.launchToken == address(0)
                || request.originalCreator == address(0) || request.amountIn == 0 || request.minAmountOut == 0
                || request.routeData.length == 0 || request.routeData.length > MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH
        ) revert InvalidLaunchBuyRequest();

        PoolConfig storage configuration = poolConfig[poolId];
        if (!configuration.initialized || configuration.currentCreator != request.originalCreator) {
            revert InvalidLaunchBuyRequest();
        }
        if (_launchBuyContext.state != LaunchBuyContextState.NONE) revert LaunchBuyContextActive();

        address swapCaller = ILaunchBuyAdapter(adapter).swapCaller();
        _launchBuyContext =
            LaunchBuyContext({state: LaunchBuyContextState.ARMED, poolId: poolId, swapCaller: swapCaller});
        uint256 creatorBalanceBefore = IERC20(request.launchToken).balanceOf(request.originalCreator);
        amountOut = ILaunchBuyAdapter(adapter).executeLaunchBuy{value: msg.value}(request);
        LaunchBuyContext memory context = _launchBuyContext;
        if (context.state != LaunchBuyContextState.CONSUMED) revert LaunchBuyContextNotConsumed();

        uint256 creatorBalanceAfter = IERC20(request.launchToken).balanceOf(request.originalCreator);
        if (
            amountOut < request.minAmountOut || creatorBalanceAfter < creatorBalanceBefore
                || creatorBalanceAfter - creatorBalanceBefore != amountOut
        ) revert InvalidLaunchBuyRequest();
        delete _launchBuyContext;
    }

    function _validateLaunchBuyAdapter(address adapter) internal view {
        if (
            adapter.code.length == 0 || _isReservedLaunchBuyDependency(adapter)
                || ILaunchBuyAdapter(adapter).factory() != factory
                || ILaunchBuyAdapter(adapter).launchHook() != address(this)
                || ILaunchBuyAdapter(adapter).poolManager() != address(poolManager)
        ) revert InvalidLaunchBuyAdapter(adapter);

        address reportedRouter = ILaunchBuyAdapter(adapter).router();
        address reportedSwapCaller = ILaunchBuyAdapter(adapter).swapCaller();
        if (
            reportedRouter.code.length == 0 || reportedSwapCaller.code.length == 0
                || _isReservedLaunchBuyDependency(reportedRouter) || _isReservedLaunchBuyDependency(reportedSwapCaller)
        ) revert InvalidLaunchBuyAdapter(adapter);
    }

    function _isReservedLaunchBuyDependency(address account) internal view returns (bool) {
        return account == factory || account == address(this) || account == address(poolManager) || account == feeEscrow;
    }

    /// @notice Seed the launch token as single-sided liquidity owned by this hook (permanent: there is no
    ///         path that ever removes it). Each band's quote-side delta is asserted zero, the on-chain
    ///         guarantee that the seed is token-only.
    function seedLiquidity(PoolKey calldata key, SeedPosition[] calldata positions, bool tokenIsCurrency0) external {
        if (msg.sender != factory) revert NotFactory();
        poolManager.unlock(abi.encode(key, positions, tokenIsCurrency0));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Only ever reached as the callback to this hook's own `seedLiquidity` unlock (the PoolManager calls
        // back the unlock caller), so this guard fully gates it.
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, SeedPosition[] memory positions, bool tokenIsCurrency0) =
            abi.decode(data, (PoolKey, SeedPosition[], bool));

        Currency tokenCurrency = tokenIsCurrency0 ? key.currency0 : key.currency1;
        uint256 tokenOwed;
        for (uint256 i = 0; i < positions.length; i++) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: positions[i].tickLower,
                    tickUpper: positions[i].tickUpper,
                    liquidityDelta: int256(uint256(positions[i].liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            int128 quoteDelta = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
            if (quoteDelta != 0) revert NotSingleSided();
            int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
            // adding liquidity owes the token (negative delta from the caller's perspective)
            if (tokenDelta > 0) revert NotSingleSided();
            // forge-lint: disable-next-line(unsafe-typecast) tokenDelta is checked < 0, so -tokenDelta fits uint128
            tokenOwed += uint256(uint128(-tokenDelta));
        }
        tokenCurrency.settle(poolManager, address(this), tokenOwed, false);
        emit Seeded(key.toId(), tokenOwed);
        return "";
    }

    // ---- hook callbacks ----

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (!wired) revert NotWired();
        if (sender != factory) revert NotFactory();
        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        // The hook's own genesis seed is a self-call and skips this callback; everyone else is blocked.
        revert LiquidityLocked();
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert LiquidityLocked();
    }

    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        (, bool quoteIsSpecified) = _quoteCurrencyAndSpecified(key, params, cfg);
        bool activeLaunchBuy = _launchBuyContext.state != LaunchBuyContextState.NONE;
        if (activeLaunchBuy) {
            _matchLaunchBuyContextBeforeSwap(poolId, sender, params, quoteIsSpecified, cfg.initialized);
        } else {
            if (!cfg.initialized) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            if (params.amountSpecified > 0 && _isSurchargeWindowActive(cfg, params.zeroForOne != cfg.tokenIsCurrency0))
            {
                revert ExactOutputDisabledDuringAntiSnipe();
            }
        }
        PlaceFeeMath.Rates memory rate = _rates(cfg, params.zeroForOne != cfg.tokenIsCurrency0, activeLaunchBuy);
        uint256 specifiedRate = rate.burnRate;
        uint256 otherRate = rate.quoteRate;
        if (quoteIsSpecified) {
            specifiedRate = rate.quoteRate;
            otherRate = rate.burnRate;
        }
        uint256 amount = PlaceFeeMath.specifiedFee(
            _specifiedMagnitude(params.amountSpecified), specifiedRate, otherRate, params.amountSpecified > 0
        );
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(amount.toInt128(), 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        (Currency quoteCurrency, bool quoteIsSpecified) = _quoteCurrencyAndSpecified(key, params, cfg);
        bool activeLaunchBuy = _launchBuyContext.state != LaunchBuyContextState.NONE;
        bool isBuy = params.zeroForOne != cfg.tokenIsCurrency0;
        if (activeLaunchBuy) {
            _matchLaunchBuyContextAfterSwap(poolId, sender, params, quoteIsSpecified, cfg.initialized);
        } else {
            if (!cfg.initialized) return (IHooks.afterSwap.selector, 0);
            if (params.amountSpecified > 0 && _isSurchargeWindowActive(cfg, isBuy)) {
                revert ExactOutputDisabledDuringAntiSnipe();
            }
        }
        PlaceFeeMath.Rates memory rate = _rates(cfg, isBuy, activeLaunchBuy);
        uint256 specifiedRate = rate.burnRate;
        uint256 otherRate = rate.quoteRate;
        if (quoteIsSpecified) {
            specifiedRate = rate.quoteRate;
            otherRate = rate.burnRate;
        }
        bool exactOutput = params.amountSpecified > 0;
        uint256 specifiedFee = PlaceFeeMath.specifiedFee(
            _specifiedMagnitude(params.amountSpecified), specifiedRate, otherRate, exactOutput
        );
        if (specifiedFee != 0 || exactOutput || activeLaunchBuy) {
            _requireFullSpecifiedFill(params, delta, specifiedFee);
        }
        uint256 poolUnspecified = _unspecifiedMagnitude(params, delta);
        uint256 unspecifiedFee = PlaceFeeMath.unspecifiedFee(poolUnspecified, specifiedRate, otherRate, exactOutput);
        uint256 quoteFee = unspecifiedFee;
        uint256 burnFee = specifiedFee;
        if (quoteIsSpecified) {
            quoteFee = specifiedFee;
            burnFee = unspecifiedFee;
        }
        if (quoteFee != 0) {
            poolManager.mint(feeEscrow, quoteCurrency.toId(), quoteFee);
        }
        _creditTax(cfg, quoteCurrency, quoteFee, rate, hookData, poolId, sender);
        if (burnFee != 0) {
            Currency tokenCurrency = key.currency1;
            if (cfg.tokenIsCurrency0) tokenCurrency = key.currency0;
            // Reserve claims without requiring physical seller input before the router settles.
            poolManager.mint(feeEscrow, tokenCurrency.toId(), burnFee);
            FeeEscrow(feeEscrow).credit(BURN_SINK, Currency.unwrap(tokenCurrency), burnFee);
            emit BurnTaxCredited(poolId, Currency.unwrap(tokenCurrency), BURN_SINK, burnFee);
        }
        if (activeLaunchBuy) _consumeLaunchBuyContextAfterSwap(cfg, delta);
        return (IHooks.afterSwap.selector, unspecifiedFee.toInt128());
    }

    // ---- fee internals ----

    function _creditTax(
        PoolConfig memory cfg,
        Currency currency,
        uint256 amount,
        PlaceFeeMath.Rates memory rate,
        bytes calldata hookData,
        PoolId poolId,
        address sender
    ) internal {
        emit Trade(poolId, sender, address(0), Currency.unwrap(currency), amount, _parseComment(hookData));
        if (amount == 0) return;
        (
            uint256 protocolAmount,
            uint256 surchargeAmount,
            uint256 creatorAmount,
            uint256 dividendAmount,
            uint256 integratorAmount
        ) = PlaceFeeMath.splitQuoteFee(amount, rate);
        FeeEscrow escrow = FeeEscrow(feeEscrow);
        address asset = Currency.unwrap(currency);
        address protocolRecipient = cfg.protocolFeeConfiguration.protocolFeeRecipient;
        if (protocolAmount != 0) {
            escrow.credit(protocolRecipient, asset, protocolAmount);
            emit ProtocolFeeCredited(poolId, protocolRecipient, asset, protocolAmount);
        }
        if (surchargeAmount != 0) {
            escrow.credit(protocolRecipient, asset, surchargeAmount);
            emit AntiSnipeFeeCredited(poolId, protocolRecipient, asset, surchargeAmount);
        }
        if (creatorAmount != 0) {
            escrow.credit(cfg.creatorFeeRecipient, asset, creatorAmount);
            emit CreatorTaxCredited(poolId, cfg.creatorFeeRecipient, asset, creatorAmount);
        }
        // Place: no dividends. Registration rejects a nonzero dividend share, so this amount is always zero.
        if (dividendAmount != 0) revert BadWiring();
        if (integratorAmount != 0) {
            escrow.credit(cfg.integratorFeeRecipient, asset, integratorAmount);
            emit IntegratorTaxCredited(poolId, cfg.integratorFeeRecipient, asset, integratorAmount);
        }
    }

    function _quoteCurrencyAndSpecified(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        PoolConfig memory cfg
    ) internal pure returns (Currency quoteCurrency, bool quoteIsSpecified) {
        quoteCurrency = cfg.tokenIsCurrency0 ? key.currency1 : key.currency0;
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn ? params.zeroForOne : !params.zeroForOne;
        Currency specifiedCurrency = specifiedIsCurrency0 ? key.currency0 : key.currency1;
        quoteIsSpecified = Currency.unwrap(specifiedCurrency) == Currency.unwrap(quoteCurrency);
    }

    function _specifiedMagnitude(int256 amountSpecified) internal pure returns (uint256) {
        if (amountSpecified < 0) return uint256(-(amountSpecified + 1)) + 1;
        // forge-lint: disable-next-line(unsafe-typecast) non-negative int256 always fits in uint256
        return uint256(amountSpecified);
    }

    function _requireFullSpecifiedFill(
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        uint256 specifiedFee
    ) internal pure {
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn ? params.zeroForOne : !params.zeroForOne;
        int128 actualSpecified = specifiedIsCurrency0 ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast) beforeSwap already requires this fee to fit int128
        int256 expectedSpecified = params.amountSpecified + int256(specifiedFee);
        if (int256(actualSpecified) != expectedSpecified) revert PartialFillUnsupported();
    }

    /// @notice Quote and burn rates scaled by 1e24, including the decaying surcharge when applicable.
    /// @dev Configuration validates the combined ceiling; the calculation does not clip excess fees.
    function _rates(PoolConfig memory cfg, bool isBuy, bool exempt) internal view returns (PlaceFeeMath.Rates memory) {
        uint256 sideTax = cfg.taxConfiguration.sellTaxRate;
        if (isBuy) sideTax = cfg.taxConfiguration.buyTaxRate;
        uint256 extra = PlaceFeeMath.surcharge(
            sideTax,
            cfg.antiSnipeConfiguration.startTotalFeeRate,
            cfg.launchTime,
            cfg.antiSnipeConfiguration.windowSeconds,
            block.timestamp,
            cfg.antiSnipeEnabled && !exempt
        );
        return PlaceFeeMath.rates(sideTax, cfg.protocolFeeConfiguration, cfg.taxConfiguration, extra);
    }

    function effectiveFeeRates(PoolId poolId, bool isBuy)
        external
        view
        returns (PlaceFeeMath.Rates memory rate, bool exactOutputRestricted)
    {
        PoolConfig memory cfg = poolConfig[poolId];
        if (!cfg.initialized) revert InvalidFeeConfig();
        return (_rates(cfg, isBuy, false), _isSurchargeWindowActive(cfg, isBuy));
    }

    function _isSurchargeWindowActive(PoolConfig memory cfg, bool isBuy) internal view returns (bool) {
        if (!cfg.antiSnipeEnabled || cfg.antiSnipeConfiguration.windowSeconds == 0) return false;
        uint256 sideTax = cfg.taxConfiguration.sellTaxRate;
        if (isBuy) sideTax = cfg.taxConfiguration.buyTaxRate;
        if (cfg.antiSnipeConfiguration.startTotalFeeRate == sideTax) return false;
        // forge-lint: disable-next-line(block-timestamp) the anti-snipe window is measured in seconds by design
        if (block.timestamp <= cfg.launchTime) return true;
        // forge-lint: disable-next-line(block-timestamp) the anti-snipe window is measured in seconds by design
        return block.timestamp - cfg.launchTime < cfg.antiSnipeConfiguration.windowSeconds;
    }

    /// @notice The absolute amount that moved in the swap's unspecified currency.
    function _unspecifiedMagnitude(IPoolManager.SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (uint256)
    {
        // exact-in: unspecified = output; exact-out: unspecified = input.
        bool unspecifiedIsCurrency1 = params.zeroForOne;
        if (params.amountSpecified >= 0) unspecifiedIsCurrency1 = !unspecifiedIsCurrency1;
        int128 deltaAmount = delta.amount0();
        if (unspecifiedIsCurrency1) deltaAmount = delta.amount1();
        // Widen before negation so int128.min is handled without overflowing.
        // forge-lint: disable-next-line(unsafe-typecast) the negated int128 value is positive and fits uint256
        if (deltaAmount < 0) return uint256(-int256(deltaAmount));
        // forge-lint: disable-next-line(unsafe-typecast) deltaAmount is non-negative here
        return uint256(int256(deltaAmount));
    }

    /// @dev Optional trade comment. The first 32-byte word of `hookData` is reserved and ignored; the second
    ///      word is emitted as `comment` in `Trade`.
    function _parseComment(bytes calldata hookData) internal pure returns (bytes32 comment) {
        if (hookData.length >= 64) comment = bytes32(hookData[32:64]);
    }

    function _matchLaunchBuyContextBeforeSwap(
        PoolId poolId,
        address sender,
        IPoolManager.SwapParams calldata params,
        bool quoteIsSpecified,
        bool poolInitialized
    ) internal {
        LaunchBuyContext storage context = _launchBuyContext;
        if (context.state != LaunchBuyContextState.ARMED) revert LaunchBuyMultipleSwaps();
        if (PoolId.unwrap(context.poolId) != PoolId.unwrap(poolId) || context.swapCaller != sender) {
            revert LaunchBuyContextMismatch(context.poolId, poolId, context.swapCaller, sender);
        }
        if (params.amountSpecified >= 0) revert LaunchBuyExactOutputUnsupported();
        if (!poolInitialized || !quoteIsSpecified) revert InvalidLaunchBuyDirection();
        context.state = LaunchBuyContextState.EXECUTING;
    }

    function _matchLaunchBuyContextAfterSwap(
        PoolId poolId,
        address sender,
        IPoolManager.SwapParams calldata params,
        bool quoteIsSpecified,
        bool poolInitialized
    ) internal view {
        LaunchBuyContext storage context = _launchBuyContext;
        if (context.state != LaunchBuyContextState.EXECUTING) revert LaunchBuyContextMissing();
        if (PoolId.unwrap(context.poolId) != PoolId.unwrap(poolId) || context.swapCaller != sender) {
            revert LaunchBuyContextMismatch(context.poolId, poolId, context.swapCaller, sender);
        }
        if (params.amountSpecified >= 0) revert LaunchBuyExactOutputUnsupported();
        if (!poolInitialized || !quoteIsSpecified) revert InvalidLaunchBuyDirection();
    }

    function _consumeLaunchBuyContextAfterSwap(PoolConfig memory cfg, BalanceDelta delta) internal {
        int128 tokenOutput = cfg.tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        if (tokenOutput <= 0) revert ZeroLaunchBuyOutput();
        _launchBuyContext.state = LaunchBuyContextState.CONSUMED;
    }

    function _validateRegistration(PoolRegistration calldata registration) internal view {
        bool enabled = PlaceFeeMath.validateTax(
            registration.taxConfiguration, registration.admittedPolicy, IERC20(registration.token).totalSupply()
        );
        if (registration.antiSnipeEnabled && registration.admittedPolicy.antiSnipeConfiguration.windowSeconds == 0) {
            revert AntiSnipeUnavailable();
        }
        // Place: `enabled` means a dividend share, which Place never admits.
        if (enabled || registration.creator == address(0)) revert InvalidFeeConfig();
        _validateConfiguredFeeRecipient(registration.creatorFeeRecipient);
        _validateConfiguredFeeRecipient(registration.admittedPolicy.protocolFeeConfiguration.protocolFeeRecipient);
        if (registration.integratorFeeRecipient != address(0)) {
            _validateConfiguredFeeRecipient(registration.integratorFeeRecipient);
        } else if (registration.taxConfiguration.integratorAllocationShare != 0) {
            revert InvalidFeeConfig();
        }
    }

    function _validateConfiguredFeeRecipient(address configuredRecipient) internal view {
        if (
            configuredRecipient == address(0) || configuredRecipient == address(this) || configuredRecipient == factory
                || configuredRecipient == feeEscrow || configuredRecipient == address(poolManager)
        ) revert InvalidFeeConfig();
    }
}
