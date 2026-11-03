// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";
import {ITaxFeeAdmin} from "./interfaces/ITaxFeeAdmin.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TaxLaunchValidation} from "./TaxLaunchValidation.sol";

import {TaxLaunchOperations} from "./TaxLaunchOperations.sol";

import {TaxFeeMath} from "./TaxFeeMath.sol";
import {TaxDividend} from "./TaxDividend.sol";
import {TaxLaunchToken} from "./TaxLaunchToken.sol";

import {TaxLaunchHook} from "./TaxLaunchHook.sol";
import {AnnouncementRegistry} from "../AnnouncementRegistry.sol";
import {ICreatorRightsReceiver} from "../interfaces/ICreatorRightsReceiver.sol";
import {ILaunchTokenMetadata} from "../interfaces/ILaunchTokenMetadata.sol";
import {ILaunchBuyAdapter} from "../interfaces/ILaunchBuyAdapter.sol";

/// @title TaxLaunchpadFactoryCore
/// @notice Shared genesis + governance for single-sided Uniswap v4 launchpads. Concrete factories provide the
///         token creation primitive while this core keeps quote registry, creator rights, pool creation, seed math,
///         locked-liquidity invariants, fee configuration, and event emission consistent across chains.
abstract contract TaxLaunchpadFactoryCore is Ownable2Step, ReentrancyGuard, ITaxFeeAdmin {
    /// @notice Sentinel `upperOffset` meaning "extend to the furthest usable tick on the token side".
    int24 internal constant TAIL = type(int24).max;

    uint256 public constant MIN_SUPPLY = TaxSuiteConstants.MIN_SUPPLY;
    uint256 public constant MAX_SUPPLY = TaxSuiteConstants.MAX_SUPPLY;
    uint256 public constant PERCENTAGE_SCALE = TaxSuiteConstants.PERCENTAGE_SCALE;
    uint256 internal constant MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH = TaxSuiteConstants.MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH;

    IPoolManager public immutable poolManager;
    TaxLaunchHook public immutable hook;
    TaxLaunchValidation public immutable launchValidation;

    /// @notice A registered quote. `startTickToken0Frame` is the opening tick assuming the launch token sorts
    ///         as currency0; it is negated at launch when the token is currency1. This single per-quote dial
    ///         folds in the quote's decimals + USD price, so each quote can open at a consistent market cap.
    struct QuoteConfig {
        bool registered;
        uint8 quoteDecimals;
        int24 startTickToken0Frame;
    }

    mapping(address quoteToken => QuoteConfig config) internal _quoteConfig;

    /// @notice A band of the single-sided seed, as tick offsets from the start tick on the token side
    ///         (`lowerOffset` nearer spot, `upperOffset` farther; `TAIL` = to the usable edge) plus a share
    ///         of supply in bps. Reused across every quote; each launch freezes the template it used.
    struct Band {
        int24 lowerOffset;
        int24 upperOffset;
        uint16 supplyShareBps;
    }

    Band[] internal _bandTemplate;

    address[] internal _defaultDividendExclusions;
    mapping(address => uint256) private _defaultExclusionIndex;
    uint256 public constant MAX_DIVIDEND_BATCH_SIZE = TaxSuiteConstants.MAX_BATCH_SIZE;
    event DefaultDividendExclusionUpdated(address indexed account, bool excluded, uint64 configVersion);
    event LaunchTaxConfigured(
        PoolId indexed poolId,
        address indexed token,
        uint64 indexed configVersion,
        TaxFeeMath.TaxPolicy admittedPolicy,
        TaxFeeMath.TaxConfiguration taxConfiguration,
        address integratorFeeRecipient,
        bool antiSnipeEnabled
    );
    error DividendsDisabled();
    error AntiSnipeUnavailable();
    // Raised by TaxLaunchValidation and redeclared here so they appear in the factory ABI.
    error InvalidTaxBounds();
    error InvalidTaxConfiguration();

    error InvalidProtocolFeeConfiguration();
    error InvalidMinimumDividendHoldingRequirement();
    error InvalidFeeSchedule();
    TaxLaunchOperations.PolicyState internal _policyState;

    function taxPolicy() public view override returns (TaxFeeMath.TaxPolicy memory) {
        return _policyState.policy;
    }

    function previewTaxConfiguration(TaxFeeMath.TaxConfiguration calldata configuration)
        external
        view
        override
        returns (TaxFeeMath.TaxConfigurationPreview memory)
    {
        return launchValidation.previewTaxConfiguration(configuration, _policyState.policy, launchSupply, configVersion);
    }

    struct CreatorRights {
        address originalCreator;
        address currentCreator;
        address pendingCreator;
        address creatorFeeRecipient;
        PoolId poolId;
        bool metadataEditable;
    }

    mapping(address token => CreatorRights rights) internal _creatorRights;
    address public creatorAdmin;
    address public pendingCreatorAdmin;

    uint256 public launchSupply;
    int24 public tickSpacing;
    uint256 public nativeLaunchFee;
    address public announcementRegistry;
    uint64 public configVersion = 1;
    mapping(bytes32 scopedSalt => bool used) public isLaunchSaltUsed;

    struct LaunchParams {
        string tokenName;
        string tokenSymbol;
        string tokenContractURI;
        bytes32 creatorSalt;
        address quoteToken;
        uint64 expectedConfigVersion;
        uint64 deadline;
        bool metadataEditable;
        string[] metadataKeys;
        string[] metadataValues;
        TaxFeeMath.TaxConfiguration taxConfiguration;
        address creatorFeeRecipient;
        address integratorFeeRecipient;
        bool antiSnipeEnabled;
    }

    struct LaunchBuyParams {
        address fundingToken;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes routeData;
    }

    struct LaunchPreparation {
        uint256 supply;
        bytes32 scopedSalt;
        address predictedToken;
        bool tokenIsCurrency0;
        int24 spacing;
        int24 startTick;
        TaxLaunchHook.SeedPosition[] seedPositions;
    }

    event QuoteRegistered(address indexed quoteToken, uint8 quoteDecimals, int24 startTickToken0Frame, uint64 revision);
    event QuoteStartTickUpdated(
        address indexed quoteToken, int24 previousStartTickToken0Frame, int24 newStartTickToken0Frame, uint64 revision
    );
    event QuoteUnregistered(address indexed quoteToken, uint64 revision);
    event BandTemplateUpdated(uint256 bandCount);
    event LaunchSupplyUpdated(uint256 previousLaunchSupply, uint256 newLaunchSupply);
    event TickSpacingUpdated(int24 previousTickSpacing, int24 newTickSpacing);
    event AnnouncementRegistrySet(address indexed announcementRegistry);
    event LaunchBuyAdapterUpdated(address indexed previousLaunchBuyAdapter, address indexed newLaunchBuyAdapter);
    event ConfigVersionUpdated(uint64 newConfigVersion);
    event Launched(
        address indexed token,
        PoolId indexed poolId,
        address indexed originalCreator,
        address quoteToken,
        uint256 launchSupply,
        int24 tickSpacing
    );
    event NativeLaunchFeePaid(address indexed payer, address indexed recipient, uint256 amount);
    event NativeLaunchFeeUpdated(uint256 previousNativeLaunchFee, uint256 newNativeLaunchFee);
    event LaunchBuyExecuted(
        address indexed token,
        PoolId indexed poolId,
        address indexed originalCreator,
        address fundingToken,
        uint256 amountIn,
        uint256 amountOut,
        address launchBuyAdapter
    );
    event CreatorRightsTransferProposed(
        address indexed token, address indexed currentCreator, address indexed pendingCreator
    );
    event CreatorRightsTransferCancelled(
        address indexed token, address indexed currentCreator, address indexed cancelledPendingCreator
    );
    event CreatorRightsTransferred(
        address indexed token,
        address indexed previousCreator,
        address indexed newCreator,
        address previousCreatorFeeRecipient,
        address newCreatorFeeRecipient
    );
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousCreatorFeeRecipient, address indexed newCreatorFeeRecipient
    );
    event CreatorAdminTransferStarted(address indexed currentCreatorAdmin, address indexed pendingCreatorAdmin);
    event CreatorAdminTransferCancelled(
        address indexed currentCreatorAdmin, address indexed cancelledPendingCreatorAdmin
    );
    event CreatorAdminTransferred(address indexed previousCreatorAdmin, address indexed newCreatorAdmin);
    event CreatorAdminRevoked(address indexed previousCreatorAdmin);
    event CreatorRightsReassigned(
        address indexed token,
        address indexed previousCreator,
        address indexed newCreator,
        address previousCreatorFeeRecipient,
        address newCreatorFeeRecipient,
        address performedBy
    );

    error InvalidConfig();
    error EmptyTokenNameOrSymbol();
    error QuoteNotRegistered();
    error QuoteAlreadyRegistered();
    error OutOfBounds();
    error TokenMismatch();
    error MisalignedOffset();
    error NotImmutable();
    error LaunchSaltUsed(bytes32 scopedSalt);
    error StaleConfig(uint64 expectedConfigVersion, uint64 actualConfigVersion);
    error LaunchExpired(uint64 deadline);
    error InvalidNativeLaunchFeePayment();
    error NativeLaunchFeeTransferFailed();
    error UnknownLaunchToken();
    error NotCurrentCreator();
    error NotPendingCreator();
    error NotOwnerOrCreatorAdmin();
    error NotPendingCreatorAdmin();
    error UnsafeOwnershipRenunciation();
    error InvalidCreatorRightsReceiver();
    error MetadataNotEditable();
    error LaunchBuyAdapterNotConfigured();
    error InvalidLaunchBuyParams();
    error InvalidLaunchBuyPayment(uint256 expectedValue, uint256 actualValue);

    /// @notice Genesis economics supplied explicitly at deploy. Each field is validated with the same logic as
    ///         its governance setter and stays tunable for future launches.
    struct FactoryInitialization {
        uint256 launchSupply;
        int24 tickSpacing;
        TaxFeeMath.TaxPolicy taxPolicy;
        Band[] bandTemplate;
    }

    constructor(
        IPoolManager poolManagerAddress,
        TaxLaunchHook launchHook,
        FactoryInitialization memory initialFactoryConfiguration
    ) Ownable(msg.sender) {
        if (
            address(poolManagerAddress) == address(0) || address(poolManagerAddress).code.length == 0
                || address(launchHook) == address(0) || address(launchHook).code.length == 0
                || address(launchHook.poolManager()) != address(poolManagerAddress)
        ) revert InvalidConfig();
        poolManager = poolManagerAddress;
        hook = launchHook;
        launchValidation = new TaxLaunchValidation();
        _setLaunchSupply(initialFactoryConfiguration.launchSupply);
        _applyTickSpacing(initialFactoryConfiguration.tickSpacing);
        TaxLaunchOperations.initializeTaxPolicy(
            _policyState, initialFactoryConfiguration.taxPolicy, launchValidation, hook, launchSupply
        );
        _applyBandTemplate(initialFactoryConfiguration.bandTemplate);
        TaxLaunchOperations.emitTaxPolicy(_policyState, configVersion);
    }

    // ============================================================
    //                          CREATE
    // ============================================================

    function createLaunch(LaunchParams calldata launchParams)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId)
    {
        if (msg.value != nativeLaunchFee) revert InvalidNativeLaunchFeePayment();
        LaunchPreparation memory preparation = _prepareLaunch(launchParams, msg.sender);
        _payNativeLaunchFee(msg.sender);
        (token, poolId,) = _createLaunch(launchParams, msg.sender, preparation);
    }

    function createLaunchAndBuy(LaunchParams calldata launchParams, LaunchBuyParams calldata launchBuyParams)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId, uint256 amountOut)
    {
        address adapter = hook.launchBuyAdapter();
        if (adapter == address(0)) revert LaunchBuyAdapterNotConfigured();
        if (
            launchBuyParams.amountIn == 0 || launchBuyParams.minAmountOut == 0 || launchBuyParams.routeData.length == 0
                || launchBuyParams.routeData.length > MAX_LAUNCH_BUY_ROUTE_DATA_LENGTH
        ) revert InvalidLaunchBuyParams();

        address fundingToken = launchBuyParams.fundingToken;
        uint256 expectedValue = nativeLaunchFee;
        if (fundingToken == address(0)) {
            expectedValue += launchBuyParams.amountIn;
        } else if (fundingToken.code.length == 0) {
            revert InvalidLaunchBuyParams();
        }
        if (msg.value != expectedValue) revert InvalidLaunchBuyPayment(expectedValue, msg.value);

        LaunchPreparation memory preparation = _prepareLaunch(launchParams, msg.sender);
        PoolKey memory poolKey;
        (token, poolId, poolKey) = _createLaunch(launchParams, msg.sender, preparation);
        if (fundingToken == token) revert InvalidLaunchBuyParams();

        ILaunchBuyAdapter.LaunchBuyRequest memory request = ILaunchBuyAdapter.LaunchBuyRequest({
            originalCreator: msg.sender,
            launchToken: token,
            quoteToken: launchParams.quoteToken,
            poolKey: poolKey,
            fundingToken: fundingToken,
            amountIn: launchBuyParams.amountIn,
            minAmountOut: launchBuyParams.minAmountOut,
            deadline: launchParams.deadline,
            routeData: launchBuyParams.routeData
        });
        uint256 valueForAdapter = fundingToken == address(0) ? launchBuyParams.amountIn : 0;
        amountOut = hook.executeLaunchBuy{value: valueForAdapter}(poolId, request);
        _payNativeLaunchFee(msg.sender);

        emit LaunchBuyExecuted(token, poolId, msg.sender, fundingToken, launchBuyParams.amountIn, amountOut, adapter);
    }

    function _createLaunch(
        LaunchParams calldata launchParams,
        address originalCreator,
        LaunchPreparation memory preparation
    ) internal returns (address token, PoolId poolId, PoolKey memory poolKey) {
        (token, poolId, poolKey) = _createLaunchPool(launchParams, originalCreator, preparation);

        _creatorRights[token] = CreatorRights({
            originalCreator: originalCreator,
            currentCreator: originalCreator,
            pendingCreator: address(0),
            creatorFeeRecipient: launchParams.creatorFeeRecipient,
            poolId: poolId,
            metadataEditable: launchParams.metadataEditable
        });

        AnnouncementRegistry(announcementRegistry).registerToken(token);
        emit LaunchTaxConfigured(
            poolId,
            token,
            configVersion,
            _policyState.policy,
            launchParams.taxConfiguration,
            launchParams.integratorFeeRecipient,
            launchParams.antiSnipeEnabled
        );
        emit Launched(token, poolId, originalCreator, launchParams.quoteToken, preparation.supply, preparation.spacing);
    }

    function _prepareLaunch(LaunchParams calldata launchParams, address originalCreator)
        internal
        returns (LaunchPreparation memory preparation)
    {
        if (launchParams.expectedConfigVersion != configVersion) {
            revert StaleConfig(launchParams.expectedConfigVersion, configVersion);
        }
        // forge-lint: disable-next-line(block-timestamp) user-supplied transaction expiry, not economic timing
        if (block.timestamp > launchParams.deadline) revert LaunchExpired(launchParams.deadline);
        if (bytes(launchParams.tokenName).length == 0 || bytes(launchParams.tokenSymbol).length == 0) {
            revert EmptyTokenNameOrSymbol();
        }
        if (!_quoteConfig[launchParams.quoteToken].registered) revert QuoteNotRegistered();
        if (launchParams.metadataKeys.length != launchParams.metadataValues.length) revert InvalidConfig();
        for (uint256 i = 0; i < launchParams.metadataKeys.length; i++) {
            if (bytes(launchParams.metadataKeys[i]).length == 0) revert InvalidConfig();
        }

        launchValidation.validateLaunchTax(
            launchParams.taxConfiguration, _policyState.policy, launchSupply, launchParams.antiSnipeEnabled
        );
        if (
            launchParams.taxConfiguration.integratorAllocationShare != 0
                && launchParams.integratorFeeRecipient == address(0)
        ) revert InvalidConfig();
        _beforeCreateLaunch(launchParams);

        preparation.supply = launchSupply;
        preparation.scopedSalt = keccak256(abi.encode(originalCreator, launchParams.creatorSalt));
        if (isLaunchSaltUsed[preparation.scopedSalt]) revert LaunchSaltUsed(preparation.scopedSalt);
        isLaunchSaltUsed[preparation.scopedSalt] = true;
        preparation.predictedToken = _predictTokenAddress(launchParams, preparation.scopedSalt, preparation.supply);
        _validatePredictedToken(preparation.predictedToken);
        launchValidation.validateLaunchRecipients(
            this,
            launchParams.creatorFeeRecipient,
            launchParams.integratorFeeRecipient,
            preparation.predictedToken,
            preparation.scopedSalt,
            launchParams.taxConfiguration.dividendAllocationShare != 0
        );
        preparation.tokenIsCurrency0 = uint160(preparation.predictedToken) < uint160(launchParams.quoteToken);
        preparation.spacing = tickSpacing;
        preparation.startTick =
            _resolveAlignedStartTick(launchParams.quoteToken, preparation.tokenIsCurrency0, preparation.spacing);
        preparation.seedPositions = _resolveSeedPositions(
            preparation.startTick, preparation.spacing, preparation.tokenIsCurrency0, preparation.supply
        );
    }

    function _payNativeLaunchFee(address payer) internal {
        uint256 amount = nativeLaunchFee;
        if (amount == 0) return;
        (bool success,) =
            payable(_policyState.policy.protocolFeeConfiguration.protocolFeeRecipient).call{value: amount}("");
        if (!success) revert NativeLaunchFeeTransferFailed();
        emit NativeLaunchFeePaid(payer, _policyState.policy.protocolFeeConfiguration.protocolFeeRecipient, amount);
    }

    function _beforeCreateLaunch(LaunchParams calldata launchParams) internal view virtual;

    function _predictTokenAddress(LaunchParams calldata launchParams, bytes32 scopedSalt, uint256 currentLaunchSupply)
        internal
        view
        virtual
        returns (address predictedToken);

    function _createLaunchPool(LaunchParams calldata params, address creator, LaunchPreparation memory preparation)
        internal
        virtual
        returns (address token, PoolId poolId, PoolKey memory poolKey);

    function _validatePredictedToken(address) internal view virtual {}

    function _resolveAlignedStartTick(address quoteToken, bool tokenIsCurrency0, int24 spacing)
        internal
        view
        returns (int24)
    {
        int24 frame = _quoteConfig[quoteToken].startTickToken0Frame;
        int24 startTick = tokenIsCurrency0 ? frame : -frame;
        // forge-lint: disable-next-line(divide-before-multiply) the truncation IS the alignment
        return (startTick / spacing) * spacing;
    }

    /// @notice Resolve the band template into absolute positions for this launch's ordering and supply.
    function _resolveSeedPositions(int24 startTick, int24 spacing, bool tokenIsCurrency0, uint256 supply)
        internal
        view
        returns (TaxLaunchHook.SeedPosition[] memory)
    {
        return launchValidation.resolveSeedPositions(_bandTemplate, startTick, spacing, tokenIsCurrency0, supply);
    }

    // ============================================================
    //                       GOVERNANCE (future launches only)
    // ============================================================

    function setBandTemplate(Band[] calldata newBandTemplate) external onlyOwner nonReentrant {
        _applyBandTemplate(newBandTemplate);
        _bumpConfigVersion();
    }

    /// @dev Validate + store the seed band template. Shared by the constructor and the governance setter.
    function _applyBandTemplate(Band[] memory newBands) internal {
        launchValidation.validateBandTemplate(newBands, tickSpacing);
        delete _bandTemplate;
        for (uint256 i; i < newBands.length; ++i) {
            _bandTemplate.push(newBands[i]);
        }
        emit BandTemplateUpdated(newBands.length);
    }

    // ============================================================
    //                       CREATOR RIGHTS
    // ============================================================

    function creatorRights(address token) external view returns (CreatorRights memory rights) {
        rights = _requireCreatorRights(token);
    }

    /// @notice Whether this factory has recorded a completed launch; not a registry of external tokens.
    function isLaunchToken(address token) external view returns (bool) {
        return _creatorRights[token].originalCreator != address(0);
    }

    function currentCreatorOf(address token) external view returns (address currentCreator) {
        currentCreator = _creatorRights[token].currentCreator;
        if (currentCreator == address(0)) revert UnknownLaunchToken();
    }

    function transferCreatorAdmin(address newCreatorAdmin) external onlyOwner nonReentrant {
        _validateCreatorAdminAddress(newCreatorAdmin);
        if (newCreatorAdmin == pendingCreatorAdmin) return;
        pendingCreatorAdmin = newCreatorAdmin;
        emit CreatorAdminTransferStarted(creatorAdmin, newCreatorAdmin);
    }

    function acceptCreatorAdmin() external nonReentrant {
        address pending = pendingCreatorAdmin;
        if (msg.sender != pending || pending == address(0)) revert NotPendingCreatorAdmin();
        address previous = creatorAdmin;
        creatorAdmin = pending;
        pendingCreatorAdmin = address(0);
        emit CreatorAdminTransferred(previous, pending);
    }

    function cancelCreatorAdminTransfer() external onlyOwner nonReentrant {
        address pending = pendingCreatorAdmin;
        if (pending == address(0)) return;
        pendingCreatorAdmin = address(0);
        emit CreatorAdminTransferCancelled(creatorAdmin, pending);
    }

    function revokeCreatorAdmin() external onlyOwner nonReentrant {
        address previousCreatorAdmin = creatorAdmin;
        address cancelledPendingCreatorAdmin = pendingCreatorAdmin;
        if (previousCreatorAdmin == address(0) && cancelledPendingCreatorAdmin == address(0)) return;
        creatorAdmin = address(0);
        pendingCreatorAdmin = address(0);
        if (cancelledPendingCreatorAdmin != address(0)) {
            emit CreatorAdminTransferCancelled(previousCreatorAdmin, cancelledPendingCreatorAdmin);
        }
        if (previousCreatorAdmin != address(0)) emit CreatorAdminRevoked(previousCreatorAdmin);
    }

    function adminReassignCreatorRights(address token, address newCreator, address newCreatorFeeRecipient)
        external
        nonReentrant
    {
        _requireOwnerOrCreatorAdmin();
        CreatorRights storage rights = _requireCreatorRights(token);
        _validateCreatorRightsAddress(token, newCreator);
        if (newCreator == rights.currentCreator) revert InvalidConfig();
        TaxLaunchOperations.reassignCreatorRights(
            rights, token, newCreator, newCreatorFeeRecipient, launchValidation, hook
        );
    }

    function proposeCreatorRightsTransfer(address token, address newCreator) external nonReentrant {
        CreatorRights storage rights = _requireCurrentCreator(token);
        _validateCreatorRightsAddress(token, newCreator);
        if (newCreator == rights.currentCreator) revert InvalidConfig();
        if (newCreator == rights.pendingCreator) return;
        rights.pendingCreator = newCreator;
        emit CreatorRightsTransferProposed(token, rights.currentCreator, newCreator);
    }

    function cancelCreatorRightsTransfer(address token) external nonReentrant {
        CreatorRights storage rights = _requireCurrentCreator(token);
        address pending = rights.pendingCreator;
        if (pending == address(0)) return;
        rights.pendingCreator = address(0);
        emit CreatorRightsTransferCancelled(token, rights.currentCreator, pending);
    }

    function acceptCreatorRightsTransfer(address token) external nonReentrant {
        CreatorRights storage rights = _requireCreatorRights(token);
        if (msg.sender != rights.pendingCreator || msg.sender == address(0)) revert NotPendingCreator();
        TaxLaunchOperations.transferCreatorRights(rights, token, msg.sender, launchValidation, hook);
    }

    function setCreatorFeeRecipient(address token, address newCreatorFeeRecipient) external nonReentrant {
        TaxLaunchOperations.setCreatorFeeRecipient(
            _requireCurrentCreator(token), token, newCreatorFeeRecipient, launchValidation, hook
        );
    }

    function safeTransferCreatorRights(address token, address rightsReceiver, bytes calldata callbackData)
        external
        payable
        nonReentrant
    {
        CreatorRights storage rights = _requireCurrentCreator(token);
        _validateCreatorRightsAddress(token, rightsReceiver);
        if (rightsReceiver == rights.currentCreator || rightsReceiver.code.length == 0) {
            revert InvalidCreatorRightsReceiver();
        }
        address previousCreator = rights.currentCreator;
        TaxLaunchOperations.transferCreatorRights(rights, token, rightsReceiver, launchValidation, hook);
        bytes4 selector = ICreatorRightsReceiver(rightsReceiver).onCreatorRightsReceived{value: msg.value}(
            previousCreator, token, callbackData
        );
        if (selector != ICreatorRightsReceiver.onCreatorRightsReceived.selector) {
            revert InvalidCreatorRightsReceiver();
        }
    }

    function updateTokenName(address token, string calldata newName) external nonReentrant {
        _requireMetadataEditor(token);
        ILaunchTokenMetadata(token).updateName(newName);
    }

    function updateTokenSymbol(address token, string calldata newSymbol) external nonReentrant {
        _requireMetadataEditor(token);
        ILaunchTokenMetadata(token).updateSymbol(newSymbol);
    }

    function updateTokenContractURI(address token, string calldata newContractURI) external nonReentrant {
        _requireMetadataEditor(token);
        ILaunchTokenMetadata(token).updateContractURI(newContractURI);
    }

    function updateTokenExtraMetadata(address token, string calldata metadataKey, string calldata metadataValue)
        external
        nonReentrant
    {
        _requireMetadataEditor(token);
        ILaunchTokenMetadata(token).updateExtraMetadata(metadataKey, metadataValue);
    }

    function _requireCreatorRights(address token) internal view returns (CreatorRights storage rights) {
        rights = _creatorRights[token];
        if (rights.originalCreator == address(0)) revert UnknownLaunchToken();
    }

    function _requireCurrentCreator(address token) internal view returns (CreatorRights storage rights) {
        rights = _requireCreatorRights(token);
        if (msg.sender != rights.currentCreator) revert NotCurrentCreator();
    }

    function _requireMetadataEditor(address token) internal view {
        CreatorRights storage rights = _requireCurrentCreator(token);
        if (!rights.metadataEditable) revert MetadataNotEditable();
    }

    function _validateCreatorRightsAddress(address token, address account) internal view {
        if (
            account == address(0) || account == token || account == address(this) || account == address(hook)
                || account == address(poolManager) || account == hook.feeEscrow() || account == announcementRegistry
                || hook.isDividendContract(account)
        ) revert InvalidConfig();
    }

    function _validateCreatorAdminAddress(address newCreatorAdmin) internal view {
        if (newCreatorAdmin == creatorAdmin || _creatorRights[newCreatorAdmin].originalCreator != address(0)) {
            revert InvalidConfig();
        }
        _validateCreatorRightsAddress(address(0), newCreatorAdmin);
    }

    function setTaxPolicy(TaxFeeMath.TaxPolicy calldata policy) external override onlyOwner {
        _applyTaxPolicy(policy);
    }

    function setTaxFeeBounds(TaxFeeMath.TaxFeeBounds calldata bounds) external override onlyOwner {
        TaxFeeMath.TaxPolicy memory policy = _policyState.policy;
        policy.taxFeeBounds = bounds;
        _applyTaxPolicy(policy);
    }

    function setProtocolFeeConfiguration(TaxFeeMath.ProtocolFeeConfiguration calldata configuration)
        external
        override
        onlyOwner
    {
        TaxFeeMath.TaxPolicy memory policy = _policyState.policy;
        policy.protocolFeeConfiguration = configuration;
        _applyTaxPolicy(policy);
    }

    function setAntiSnipeConfiguration(TaxFeeMath.AntiSnipeConfiguration calldata configuration)
        external
        override
        onlyOwner
    {
        TaxFeeMath.TaxPolicy memory policy = _policyState.policy;
        policy.antiSnipeConfiguration = configuration;
        _applyTaxPolicy(policy);
    }

    function setMinimumDividendHoldingRequirement(uint256 minimumHolding) external override onlyOwner {
        TaxFeeMath.TaxPolicy memory policy = _policyState.policy;
        policy.minimumDividendHoldingRequirement = minimumHolding;
        _applyTaxPolicy(policy);
    }

    function _applyTaxPolicy(TaxFeeMath.TaxPolicy memory policy) internal {
        // Policy validation makes only static external calls. Keep no-ops write-free while rejecting
        // policy mutation from an active launch, payout or other guarded factory operation.
        if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
        if (!TaxLaunchOperations.applyTaxPolicy(_policyState, policy, launchValidation, hook, launchSupply)) return;
        _bumpConfigVersion();
        TaxLaunchOperations.emitTaxPolicy(_policyState, configVersion);
    }

    function defaultDividendExclusions() external view returns (address[] memory) {
        return _defaultDividendExclusions;
    }

    function setDefaultDividendExclusion(address account, bool excluded) external onlyOwner nonReentrant {
        if (!TaxLaunchOperations.setDefaultExclusion(
                _defaultDividendExclusions, _defaultExclusionIndex, account, excluded
            )) return;
        _bumpConfigVersion();
        emit DefaultDividendExclusionUpdated(account, excluded, configVersion);
    }

    function dividendOf(address token) public view returns (address) {
        _requireCreatorRights(token);
        return TaxLaunchToken(token).dividend();
    }

    function setLaunchDividendExclusions(address token, address[] calldata accounts, bool excluded)
        external
        nonReentrant
    {
        TaxDividend dividend = _requireDividendAdmin(token);
        if (accounts.length == 0 || accounts.length > MAX_DIVIDEND_BATCH_SIZE) revert OutOfBounds();
        for (uint256 i; i < accounts.length; ++i) {
            if (excluded) dividend.excludeAddress(accounts[i]);
            else dividend.unexcludeAddress(accounts[i]);
        }
    }

    function setLaunchDividendReceiver(address token, address holder, address receiver) external nonReentrant {
        _requireDividendAdmin(token).setDividendReceiver(holder, receiver);
    }

    function refreshLaunchDividendShares(address token, address[] calldata holders) external nonReentrant {
        _requireDividendAdmin(token).refreshShares(holders);
    }

    function emergencyWithdrawDividendAssets(address token, address asset, uint256 amount, address recipient)
        external
        nonReentrant
    {
        _requireDividendAdmin(token).emergencyWithdraw(asset, amount, recipient);
    }

    function _requireDividendAdmin(address token) internal view returns (TaxDividend) {
        _requireOwnerOrCreatorAdmin();
        address dividend = dividendOf(token);
        if (dividend == address(0)) revert DividendsDisabled();
        return TaxDividend(payable(dividend));
    }

    function adminSetCreatorFeeRecipient(address token, address recipient) external nonReentrant {
        _requireOwnerOrCreatorAdmin();
        TaxLaunchOperations.setCreatorFeeRecipient(
            _requireCreatorRights(token), token, recipient, launchValidation, hook
        );
    }

    function _requireOwnerOrCreatorAdmin() internal view {
        if (msg.sender == address(0) || (msg.sender != owner() && msg.sender != creatorAdmin)) {
            revert NotOwnerOrCreatorAdmin();
        }
    }

    function quoteConfig(address quoteToken)
        external
        view
        returns (bool registered, uint8 quoteDecimals, int24 startTickToken0Frame)
    {
        QuoteConfig storage configuration = _quoteConfig[quoteToken];
        return (configuration.registered, configuration.quoteDecimals, configuration.startTickToken0Frame);
    }

    function setLaunchSupply(uint256 newLaunchSupply) external onlyOwner nonReentrant {
        if (newLaunchSupply == launchSupply) return;
        _setLaunchSupply(newLaunchSupply);
        _bumpConfigVersion();
    }

    function setTickSpacing(int24 newTickSpacing) external onlyOwner nonReentrant {
        if (newTickSpacing == tickSpacing) return;
        _applyTickSpacing(newTickSpacing);
        _bumpConfigVersion();
    }

    /// @dev Validate + store the tick spacing. Shared by the constructor and the governance setter.
    function _applyTickSpacing(int24 spacing) internal {
        if (spacing <= 0 || spacing > 16_384) revert OutOfBounds();
        for (uint256 i = 0; i < _bandTemplate.length; i++) {
            if (
                _bandTemplate[i].lowerOffset % spacing != 0
                    || (_bandTemplate[i].upperOffset != TAIL && _bandTemplate[i].upperOffset % spacing != 0)
            ) revert MisalignedOffset();
        }
        emit TickSpacingUpdated(tickSpacing, spacing);
        tickSpacing = spacing;
    }

    function setAnnouncementRegistry(address newAnnouncementRegistry) external onlyOwner nonReentrant {
        if (announcementRegistry != address(0)) revert InvalidConfig();
        if (
            newAnnouncementRegistry == address(0) || newAnnouncementRegistry.code.length == 0
                || AnnouncementRegistry(newAnnouncementRegistry).factory() != address(this)
        ) {
            revert InvalidConfig();
        }
        announcementRegistry = newAnnouncementRegistry;
        _bumpConfigVersion();
        emit AnnouncementRegistrySet(newAnnouncementRegistry);
    }

    function launchBuyAdapter() external view returns (address adapter) {
        return hook.launchBuyAdapter();
    }

    function setLaunchBuyAdapter(address newLaunchBuyAdapter) external onlyOwner nonReentrant {
        address previousAdapter = hook.launchBuyAdapter();
        if (newLaunchBuyAdapter == previousAdapter) return;
        hook.setLaunchBuyAdapter(newLaunchBuyAdapter);
        _bumpConfigVersion();
        emit LaunchBuyAdapterUpdated(previousAdapter, newLaunchBuyAdapter);
    }

    function setNativeLaunchFee(uint256 newNativeLaunchFee) external onlyOwner nonReentrant {
        uint256 previousNativeLaunchFee = nativeLaunchFee;
        if (newNativeLaunchFee == previousNativeLaunchFee) return;
        nativeLaunchFee = newNativeLaunchFee;
        _bumpConfigVersion();
        emit NativeLaunchFeeUpdated(previousNativeLaunchFee, newNativeLaunchFee);
    }

    function bandTemplate() external view returns (Band[] memory bands) {
        return _bandTemplate;
    }

    function _setLaunchSupply(uint256 supply) internal {
        if (supply < MIN_SUPPLY || supply > MAX_SUPPLY) revert OutOfBounds();
        if (_policyState.policy.minimumDividendHoldingRequirement > supply) {
            revert InvalidMinimumDividendHoldingRequirement();
        }
        emit LaunchSupplyUpdated(launchSupply, supply);
        launchSupply = supply;
    }

    /// @dev Reserve one `tickSpacing` of headroom from both tick extremes.
    function _validateStartTickFrame(int24 frame) internal view {
        int24 spacing = tickSpacing;
        if (frame < TickMath.MIN_TICK + spacing || frame > TickMath.MAX_TICK - spacing) revert OutOfBounds();
    }

    function _bumpConfigVersion() internal {
        configVersion++;
        emit ConfigVersionUpdated(configVersion);
    }

    function _requireLaunchCreationWiring() internal view virtual {
        launchValidation.validateFactoryWiring(this);
    }

    function renounceOwnership() public virtual override onlyOwner {
        if (creatorAdmin != address(0) || pendingCreatorAdmin != address(0) || hook.launchBuyAdapter() != address(0)) {
            revert UnsafeOwnershipRenunciation();
        }
        super.renounceOwnership();
    }
}
