// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PlaceLaunchFactoryCore as Core} from "./PlaceLaunchFactoryCore.sol";
import {PlaceLaunchValidation} from "./PlaceLaunchValidation.sol";
import {PlaceFeeMath} from "./PlaceFeeMath.sol";

import {PlaceLaunchHook} from "./PlaceLaunchHook.sol";
import {PlaceLaunchToken} from "./PlaceLaunchToken.sol";
import {PlaceLaunchTokenDeployer} from "./PlaceLaunchTokenDeployer.sol";
import {PlaceSuiteConstants} from "./PlaceSuiteConstants.sol";
import {IB20, IB20Factory} from "./interfaces/IB20.sol";
import {PlaceCreatorVault} from "../place/PlaceCreatorVault.sol";
import {PlaceCommunityVault} from "../place/PlaceCommunityVault.sol";
import {IPlaceRewardsDistributor} from "../place/interfaces/IPlaceRewardsDistributor.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Linked library with part of the factory's launch and policy logic, split out to keep the factory under
///         the contract size limit. It runs by DELEGATECALL in the factory's context and holds no state or assets.
library PlaceLaunchOperations {
    struct PolicyState {
        PlaceFeeMath.TaxPolicy policy;
    }
    event TaxPolicyUpdated(uint64 indexed configVersion, PlaceFeeMath.TaxPolicy policy);
    event CreatorRightsTransferred(
        address indexed token,
        address indexed previousCreator,
        address indexed newCreator,
        address previousCreatorFeeRecipient,
        address newCreatorFeeRecipient
    );
    event CreatorRightsReassigned(
        address indexed token,
        address indexed previousCreator,
        address indexed newCreator,
        address previousCreatorFeeRecipient,
        address newCreatorFeeRecipient,
        address performedBy
    );

    function transferCreatorRights(
        Core.CreatorRights storage rights,
        address token,
        address newCreator,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook
    ) public {
        validation.validateFeeRecipient(newCreator, Core(address(this)));
        address previousCreator = rights.currentCreator;
        address previousRecipient = rights.creatorFeeRecipient;
        _applyCreatorRightsTransition(rights, newCreator, hook);
        emit CreatorRightsTransferred(token, previousCreator, newCreator, previousRecipient, previousRecipient);
    }

    function reassignCreatorRights(
        Core.CreatorRights storage rights,
        address token,
        address newCreator,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook
    ) public {
        validation.validateFeeRecipient(newCreator, Core(address(this)));
        address previousCreator = rights.currentCreator;
        address recipient = rights.creatorFeeRecipient;
        _applyCreatorRightsTransition(rights, newCreator, hook);
        emit CreatorRightsReassigned(token, previousCreator, newCreator, recipient, recipient, msg.sender);
    }

    /// @dev Place: the creator fee recipient (the launch's vault) stays; only the creator moves.
    function _applyCreatorRightsTransition(Core.CreatorRights storage rights, address newCreator, PlaceLaunchHook hook)
        private
    {
        rights.currentCreator = newCreator;
        rights.pendingCreator = address(0);
        hook.updateCreatorRights(rights.poolId, newCreator, rights.creatorFeeRecipient);
    }

    function applyTaxPolicy(
        PolicyState storage state,
        PlaceFeeMath.TaxPolicy memory policy,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook,
        uint256 supply
    ) public returns (bool) {
        validation.validateTaxPolicy(policy, supply, address(this), hook);
        return _storeTaxPolicy(state, policy);
    }

    function initializeTaxPolicy(
        PolicyState storage state,
        PlaceFeeMath.TaxPolicy memory policy,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook,
        uint256 supply
    ) public {
        validation.validateInitialTaxPolicy(policy, supply, address(this), hook);
        _storeTaxPolicy(state, policy);
    }

    function _storeTaxPolicy(PolicyState storage state, PlaceFeeMath.TaxPolicy memory policy) private returns (bool) {
        // Validation precedes comparison, including recipient checks for previously valid settings.
        if (keccak256(abi.encode(state.policy)) == keccak256(abi.encode(policy))) return false;
        state.policy = policy;
        return true;
    }

    function emitTaxPolicy(PolicyState storage state, uint64 configVersion) public {
        emit TaxPolicyUpdated(configVersion, state.policy);
    }

    struct Context {
        PlaceLaunchHook hook;
        PlaceLaunchTokenDeployer tokenDeployer;
        PlaceFeeMath.TaxPolicy admittedPolicy;
        address vaultImplementation;
        address communityVaultImplementation;
        Core.EconomySettings economySettings;
        Core.QuoteLimits quoteLimits;
    }

    event CreatorVaultCreated(address indexed token, address indexed vault);
    event CommunityVaultCreated(address indexed token, address indexed vault);

    error InvalidConfig();
    error TokenMismatch();
    error NotImmutable();
    error OutOfBounds();

    function create(
        Context memory context,
        Core.LaunchParams calldata params,
        Core.LaunchPreparation memory preparation,
        mapping(address => Core.TokenKind) storage launchTokenKind,
        address originalCreator
    ) public returns (address token, PoolId poolId, PoolKey memory key, address communityVault) {
        if (params.tokenKind == Core.TokenKind.B20) {
            token = _createB20(params, preparation, address(context.hook), originalCreator);
        } else {
            PlaceLaunchToken.GenesisParams memory genesis = tokenParams(params, preparation.supply, context.hook);
            token = context.tokenDeployer.deploy(preparation.scopedSalt, genesis);
            if (token != preparation.predictedToken) revert TokenMismatch();
            PlaceLaunchToken asset = PlaceLaunchToken(token);
            if (
                asset.factory() != address(this) || asset.totalSupply() != preparation.supply
                    || asset.supplyCap() != preparation.supply || asset.decimals() != 18
                    || asset.hasRole(asset.DEFAULT_ADMIN_ROLE(), originalCreator)
                    || asset.metadataAuthority() != genesis.metadataAuthority
                    || asset.hasRole(asset.METADATA_ROLE(), address(this)) != params.metadataEditable
            ) revert NotImmutable();
        }
        launchTokenKind[token] = params.tokenKind;
        Currency c0 = Currency.wrap(params.quoteToken);
        Currency c1 = Currency.wrap(token);
        if (preparation.tokenIsCurrency0) {
            c0 = Currency.wrap(token);
            c1 = Currency.wrap(params.quoteToken);
        }
        key = PoolKey(c0, c1, 0, preparation.spacing, IHooks(address(context.hook)));
        int24 initialTick = preparation.startTick;
        if (preparation.tokenIsCurrency0) initialTick -= preparation.spacing;
        if (initialTick < TickMath.MIN_TICK || initialTick > TickMath.MAX_TICK) revert OutOfBounds();
        context.hook.poolManager().initialize(key, TickMath.getSqrtPriceAtTick(initialTick));
        _createVault(context, params.economics, preparation, token, params.quoteToken);
        PlaceFeeMath.TaxConfiguration memory tax = preparation.taxConfiguration;
        if (tax.communityAllocationShare != 0) {
            communityVault = _createCommunityVault(context, params.economics, preparation, token, key);
        }
        address distributor;
        if (tax.holderAllocationShare != 0 || tax.traderAllocationShare != 0) {
            distributor = context.economySettings.rewardsDistributor;
            _registerStreams(distributor, context.economySettings.rewardRegistry, params, tax, token, key);
        }
        PlaceLaunchHook.PoolRegistration memory registration = PlaceLaunchHook.PoolRegistration({
            token: token,
            creator: originalCreator,
            creatorFeeRecipient: preparation.vault,
            rewardsDistributor: distributor,
            communityVault: communityVault,
            launchTime: uint48(block.timestamp),
            antiSnipeEnabled: params.antiSnipeEnabled,
            admittedPolicy: context.admittedPolicy,
            taxConfiguration: tax
        });
        context.hook.registerPool(key, registration);
        context.hook.seedLiquidity(key, preparation.seedPositions, preparation.tokenIsCurrency0);
        return (token, key.toId(), key, communityVault);
    }

    function predictTokenAddress(
        PlaceLaunchTokenDeployer deployer,
        Core.LaunchParams calldata params,
        bytes32 salt,
        uint256 supply,
        PlaceLaunchHook hook
    ) public view returns (address) {
        if (params.tokenKind == Core.TokenKind.B20) {
            return IB20Factory(PlaceSuiteConstants.B20_FACTORY)
                .getB20Address(PlaceSuiteConstants.B20_ASSET_VARIANT, address(this), salt);
        }
        return deployer.predictTokenAddress(salt, tokenParams(params, supply, hook));
    }

    // ---- Place: creator vault ----

    /// @notice Clones and initializes the launch's PlaceCreatorVault at the address `_prepareLaunch` predicted
    ///         (and validated as the creator fee recipient). The vault validates the economics itself.
    function _createVault(
        Context memory context,
        Core.Economics calldata economics,
        Core.LaunchPreparation memory preparation,
        address token,
        address quote
    ) private {
        address vault = Clones.cloneDeterministic(context.vaultImplementation, preparation.scopedSalt);
        if (vault != preparation.vault) revert InvalidConfig();
        PlaceCreatorVault(payable(vault))
            .initialize(
                PlaceCreatorVault.Initialization({
                    token: token,
                    quote: quote,
                    feeEscrow: context.hook.feeEscrow(),
                    xShares: economics.xShares,
                    xRegistry: context.economySettings.xRegistry
                })
            );
        emit CreatorVaultCreated(token, vault);
    }

    /// @notice Clones and initializes the launch's PlaceCommunityVault (Economy launches with a community basket).
    ///         The default campaign pays holders above the launch's own threshold, or 10,000 tokens.
    function _createCommunityVault(
        Context memory context,
        Core.Economics calldata economics,
        Core.LaunchPreparation memory preparation,
        address token,
        PoolKey memory key
    ) private returns (address vault) {
        vault = Clones.cloneDeterministic(context.communityVaultImplementation, preparation.scopedSalt);
        uint256 minHolding = economics.minHolding;
        if (minHolding == 0) minHolding = PlaceSuiteConstants.MIN_HOLDER_REWARD_HOLDING;
        PlaceCommunityVault(payable(vault))
            .initialize(
                PlaceCommunityVault.Initialization({
                    token: token,
                    poolKey: key,
                    feeEscrow: context.hook.feeEscrow(),
                    distributor: context.economySettings.rewardsDistributor,
                    staking: context.economySettings.staking,
                    rewardRegistry: context.economySettings.rewardRegistry,
                    defaultCampaignDelay: context.economySettings.defaultCampaignDelay,
                    defaultCampaignEpochs: context.economySettings.defaultCampaignEpochs,
                    defaultCampaignMinimum: context.quoteLimits.defaultCampaignMinimum,
                    defaultMinHolding: minHolding
                })
            );
        emit CommunityVaultCreated(token, vault);
    }

    /// @notice Registers the launch's holder and/or trader streams in the rewards distributor, which checks the
    ///         reward token against the registry.
    function _registerStreams(
        address distributor,
        address rewardRegistry,
        Core.LaunchParams calldata params,
        PlaceFeeMath.TaxConfiguration memory tax,
        address token,
        PoolKey memory key
    ) private {
        IPlaceRewardsDistributor(distributor)
            .registerLaunch(
                IPlaceRewardsDistributor.LaunchStreams({
                    token: token,
                    quote: params.quoteToken,
                    poolKey: key,
                    rewardToken: params.economics.rewardToken,
                    rewardRegistry: rewardRegistry,
                    holders: tax.holderAllocationShare != 0,
                    minHolding: params.economics.minHolding,
                    traders: tax.traderAllocationShare != 0,
                    minDailyVolume: params.economics.minTraderDailyVolume
                })
            );
    }

    // ---- Place: B20 genesis ----

    /// @dev Emitted by the factory for B20 launches, which have no on-token extra metadata store (the ERC-20
    ///      token emits ExtraMetadataUpdated itself).
    event B20ExtraMetadataUpdated(address indexed token, string metadataKey, string metadataValue);

    /// @notice Creates the B20 with no admin at all: the supply cap, the whole mint to the hook, the optional
    ///         contract URI and (if editable) METADATA_ROLE for this factory all run as creation-time initCalls,
    ///         which skip role checks. Nobody can ever mint, raise the cap, pause, seize, set transfer policies
    ///         or grant roles afterwards. The factory exposes no symbol update, so the ticker never changes.
    function _createB20(
        Core.LaunchParams calldata params,
        Core.LaunchPreparation memory preparation,
        address hook,
        address originalCreator
    ) private returns (address token) {
        bool withURI = bytes(params.tokenContractURI).length != 0;
        bytes[] memory initCalls = new bytes[](2 + (withURI ? 1 : 0) + (params.metadataEditable ? 1 : 0));
        initCalls[0] = abi.encodeCall(IB20.updateSupplyCap, (preparation.supply));
        initCalls[1] = abi.encodeCall(IB20.mint, (hook, preparation.supply));
        uint256 next = 2;
        if (withURI) initCalls[next++] = abi.encodeCall(IB20.updateContractURI, (params.tokenContractURI));
        if (params.metadataEditable) {
            initCalls[next] = abi.encodeCall(IB20.grantRole, (PlaceSuiteConstants.B20_METADATA_ROLE, address(this)));
        }
        bytes memory createParams = abi.encode(
            IB20Factory.B20AssetCreateParams({
                version: PlaceSuiteConstants.B20_PARAMS_VERSION,
                name: params.tokenName,
                symbol: params.tokenSymbol,
                initialAdmin: address(0), // none, ever
                decimals: PlaceSuiteConstants.TOKEN_DECIMALS
            })
        );
        token = IB20Factory(PlaceSuiteConstants.B20_FACTORY)
            .createB20(PlaceSuiteConstants.B20_ASSET_VARIANT, preparation.scopedSalt, createParams, initCalls);
        if (token != preparation.predictedToken) revert TokenMismatch();
        _requireImmutableB20(IB20(token), preparation.supply, hook, originalCreator, params.metadataEditable);
        for (uint256 i = 0; i < params.metadataKeys.length; i++) {
            emit B20ExtraMetadataUpdated(token, params.metadataKeys[i], params.metadataValues[i]);
        }
    }

    /// @notice B20 immutability check: fixed supply all held by the hook, no admin, no privileged role for the
    ///         factory, hook or creator (other than the factory's METADATA_ROLE when editable), nothing paused
    ///         and every transfer/mint/seize policy at 0 (allow all).
    function _requireImmutableB20(IB20 asset, uint256 supply, address hook, address creator, bool editable)
        private
        view
    {
        if (
            !IB20Factory(PlaceSuiteConstants.B20_FACTORY).isB20(address(asset)) || asset.totalSupply() != supply
                || asset.supplyCap() != supply || asset.balanceOf(hook) != supply
                || asset.decimals() != PlaceSuiteConstants.TOKEN_DECIMALS || asset.pausedFeatures().length != 0
                || asset.hasRole(asset.METADATA_ROLE(), address(this)) != editable
                || asset.hasRole(asset.METADATA_ROLE(), creator) || asset.hasRole(asset.METADATA_ROLE(), hook)
        ) revert NotImmutable();
        bytes32[7] memory roles = [
            asset.DEFAULT_ADMIN_ROLE(),
            asset.MINT_ROLE(),
            asset.BURN_ROLE(),
            asset.BURN_BLOCKED_ROLE(),
            asset.SEIZE_ROLE(),
            asset.PAUSE_ROLE(),
            asset.UNPAUSE_ROLE()
        ];
        for (uint256 i = 0; i < roles.length; i++) {
            if (
                asset.hasRole(roles[i], address(this)) || asset.hasRole(roles[i], hook)
                    || asset.hasRole(roles[i], creator)
            ) revert NotImmutable();
        }
        bytes32[6] memory scopes = [
            asset.TRANSFER_SENDER_POLICY(),
            asset.TRANSFER_RECEIVER_POLICY(),
            asset.TRANSFER_EXECUTOR_POLICY(),
            asset.MINT_RECEIVER_POLICY(),
            asset.SEIZE_EXEMPT_POLICY(),
            asset.SEIZE_RECEIVER_POLICY()
        ];
        for (uint256 i = 0; i < scopes.length; i++) {
            if (asset.policyId(scopes[i]) != 0) revert NotImmutable();
        }
    }

    function tokenInitCodeHash(
        PlaceLaunchTokenDeployer deployer,
        Core.LaunchParams calldata params,
        uint256 supply,
        PlaceLaunchHook hook
    ) public view returns (bytes32) {
        return deployer.tokenInitCodeHash(tokenParams(params, supply, hook));
    }

    function tokenParams(Core.LaunchParams calldata params, uint256 supply, PlaceLaunchHook hook)
        internal
        view
        returns (PlaceLaunchToken.GenesisParams memory genesis)
    {
        address metadataAuthority;
        if (params.metadataEditable) metadataAuthority = address(this);
        genesis.factory = address(this);
        genesis.tokenName = params.tokenName;
        genesis.tokenSymbol = params.tokenSymbol;
        genesis.tokenContractURI = params.tokenContractURI;
        genesis.metadataAuthority = metadataAuthority;
        genesis.initialRecipient = address(hook);
        genesis.initialSupply = supply;
        genesis.metadataKeys = params.metadataKeys;
        genesis.metadataValues = params.metadataValues;
    }
}
