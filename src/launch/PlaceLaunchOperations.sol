// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;
import {PlaceLaunchFactoryCore as Core} from "./PlaceLaunchFactoryCore.sol";
import {PlaceLaunchValidation} from "./PlaceLaunchValidation.sol";
import {PlaceFeeMath} from "./PlaceFeeMath.sol";

import {PlaceLaunchHook} from "./PlaceLaunchHook.sol";
import {PlaceLaunchToken} from "./PlaceLaunchToken.sol";
import {PlaceLaunchTokenDeployer} from "./PlaceLaunchTokenDeployer.sol";
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
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousCreatorFeeRecipient, address indexed newCreatorFeeRecipient
    );
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

    function setCreatorFeeRecipient(
        Core.CreatorRights storage rights,
        address token,
        address recipient,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook
    ) public {
        validation.validateFeeRecipient(recipient, Core(address(this)));
        address previousRecipient = rights.creatorFeeRecipient;
        if (previousRecipient == recipient) return;
        rights.creatorFeeRecipient = recipient;
        hook.updateCreatorRights(rights.poolId, rights.currentCreator, recipient);
        emit CreatorFeeRecipientUpdated(token, previousRecipient, recipient);
    }

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
        _applyCreatorRightsTransition(rights, newCreator, newCreator, hook);
        emit CreatorRightsTransferred(token, previousCreator, newCreator, previousRecipient, newCreator);
    }

    function reassignCreatorRights(
        Core.CreatorRights storage rights,
        address token,
        address newCreator,
        address recipient,
        PlaceLaunchValidation validation,
        PlaceLaunchHook hook
    ) public {
        validation.validateFeeRecipient(recipient, Core(address(this)));
        address previousCreator = rights.currentCreator;
        address previousRecipient = rights.creatorFeeRecipient;
        _applyCreatorRightsTransition(rights, newCreator, recipient, hook);
        emit CreatorRightsReassigned(token, previousCreator, newCreator, previousRecipient, recipient, msg.sender);
    }

    function _applyCreatorRightsTransition(
        Core.CreatorRights storage rights,
        address newCreator,
        address recipient,
        PlaceLaunchHook hook
    ) private {
        rights.currentCreator = newCreator;
        rights.creatorFeeRecipient = recipient;
        rights.pendingCreator = address(0);
        hook.updateCreatorRights(rights.poolId, newCreator, recipient);
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
        PlaceFeeMath.TaxConfiguration taxConfiguration;
    }
    error InvalidConfig();
    error TokenMismatch();
    error NotImmutable();
    error OutOfBounds();

    function create(
        Context memory context,
        Core.LaunchParams calldata params,
        Core.LaunchPreparation memory preparation,
        mapping(address => bool) storage isFactoryToken,
        address originalCreator
    ) public returns (address token, PoolId poolId, PoolKey memory key) {
        PlaceLaunchToken.GenesisParams memory genesis = tokenParams(params, preparation.supply, context.hook);
        token = context.tokenDeployer.deploy(preparation.scopedSalt, genesis);
        if (token != preparation.predictedToken) revert TokenMismatch();
        isFactoryToken[token] = true;
        PlaceLaunchToken asset = PlaceLaunchToken(token);
        if (
            asset.factory() != address(this) || asset.totalSupply() != preparation.supply
                || asset.supplyCap() != preparation.supply || asset.decimals() != 18
                || asset.hasRole(asset.DEFAULT_ADMIN_ROLE(), originalCreator)
                || asset.metadataAuthority() != genesis.metadataAuthority
                || asset.hasRole(asset.METADATA_ROLE(), address(this)) != params.metadataEditable
        ) revert NotImmutable();
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
        PlaceLaunchHook.PoolRegistration memory registration = PlaceLaunchHook.PoolRegistration({
            token: token,
            creator: originalCreator,
            creatorFeeRecipient: params.creatorFeeRecipient,
            integratorFeeRecipient: address(0),
            launchTime: uint48(block.timestamp),
            antiSnipeEnabled: true,
            admittedPolicy: context.admittedPolicy,
            taxConfiguration: context.taxConfiguration
        });
        context.hook.registerPool(key, registration);
        context.hook.seedLiquidity(key, preparation.seedPositions, preparation.tokenIsCurrency0);
        return (token, key.toId(), key);
    }

    function predictTokenAddress(
        PlaceLaunchTokenDeployer deployer,
        Core.LaunchParams calldata params,
        bytes32 salt,
        uint256 supply,
        PlaceLaunchHook hook
    ) public view returns (address) {
        return deployer.predictTokenAddress(salt, tokenParams(params, supply, hook));
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
