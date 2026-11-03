// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";
import {TaxLaunchpadFactoryCore as Core} from "./TaxLaunchpadFactoryCore.sol";
import {TaxLaunchValidation} from "./TaxLaunchValidation.sol";
import {TaxFeeMath} from "./TaxFeeMath.sol";

import {TaxLaunchHook} from "./TaxLaunchHook.sol";
import {TaxLaunchToken} from "./TaxLaunchToken.sol";
import {TaxLaunchTokenDeployer} from "./TaxLaunchTokenDeployer.sol";
import {TaxDividendDeployer} from "./TaxDividendDeployer.sol";
import {TaxDividend} from "./TaxDividend.sol";
import {FeeEscrow} from "../FeeEscrow.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Linked library with part of the factory's launch and policy logic, split out to keep the factory under
///         the contract size limit. It runs by DELEGATECALL in the factory's context and holds no state or assets.
library TaxLaunchOperations {
    struct PolicyState {
        TaxFeeMath.TaxPolicy policy;
    }
    event TaxPolicyUpdated(uint64 indexed configVersion, TaxFeeMath.TaxPolicy policy);
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
        TaxLaunchValidation validation,
        TaxLaunchHook hook
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
        TaxLaunchValidation validation,
        TaxLaunchHook hook
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
        TaxLaunchValidation validation,
        TaxLaunchHook hook
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
        TaxLaunchHook hook
    ) private {
        rights.currentCreator = newCreator;
        rights.creatorFeeRecipient = recipient;
        rights.pendingCreator = address(0);
        hook.updateCreatorRights(rights.poolId, newCreator, recipient);
    }

    function applyTaxPolicy(
        PolicyState storage state,
        TaxFeeMath.TaxPolicy memory policy,
        TaxLaunchValidation validation,
        TaxLaunchHook hook,
        uint256 supply
    ) public returns (bool) {
        validation.validateTaxPolicy(policy, supply, address(this), hook);
        return _storeTaxPolicy(state, policy);
    }

    function initializeTaxPolicy(
        PolicyState storage state,
        TaxFeeMath.TaxPolicy memory policy,
        TaxLaunchValidation validation,
        TaxLaunchHook hook,
        uint256 supply
    ) public {
        validation.validateInitialTaxPolicy(policy, supply, address(this), hook);
        _storeTaxPolicy(state, policy);
    }

    function _storeTaxPolicy(PolicyState storage state, TaxFeeMath.TaxPolicy memory policy) private returns (bool) {
        // Validation precedes comparison, including recipient checks for previously valid settings.
        if (keccak256(abi.encode(state.policy)) == keccak256(abi.encode(policy))) return false;
        state.policy = policy;
        return true;
    }

    function emitTaxPolicy(PolicyState storage state, uint64 configVersion) public {
        emit TaxPolicyUpdated(configVersion, state.policy);
    }

    function setDefaultExclusion(
        address[] storage accounts,
        mapping(address => uint256) storage indices,
        address account,
        bool excluded
    ) public returns (bool) {
        if (account == address(0)) revert InvalidConfig();
        uint256 index = indices[account];
        if (excluded) {
            if (index != 0) return false;
            if (accounts.length == TaxSuiteConstants.MAX_BATCH_SIZE) revert OutOfBounds();
            accounts.push(account);
            indices[account] = accounts.length;
        } else {
            if (index == 0) return false;
            address last = accounts[accounts.length - 1];
            accounts[index - 1] = last;
            indices[last] = index;
            accounts.pop();
            delete indices[account];
        }
        return true;
    }

    struct Context {
        TaxLaunchHook hook;
        TaxLaunchTokenDeployer tokenDeployer;
        TaxDividendDeployer dividendDeployer;
        TaxFeeMath.TaxPolicy admittedPolicy;
    }
    error InvalidConfig();
    error TokenMismatch();
    error NotImmutable();
    error OutOfBounds();

    function create(
        Context memory context,
        Core.LaunchParams calldata params,
        Core.LaunchPreparation memory preparation,
        address[] storage defaultExclusions,
        address originalCreator
    ) public returns (address token, PoolId poolId, PoolKey memory key) {
        TaxLaunchToken.GenesisParams memory genesis = tokenParams(params, preparation.supply, context.hook);
        token = context.tokenDeployer.deploy(preparation.scopedSalt, genesis);
        if (token != preparation.predictedToken) revert TokenMismatch();
        address dividend;
        if (params.taxConfiguration.dividendAllocationShare != 0) {
            dividend = context.dividendDeployer.deploy(preparation.scopedSalt);
            if (dividend == params.creatorFeeRecipient || dividend == params.integratorFeeRecipient) {
                revert InvalidConfig();
            }
            if (dividend == context.admittedPolicy.protocolFeeConfiguration.protocolFeeRecipient) {
                revert InvalidConfig();
            }
            TaxDividend(payable(dividend))
                .initialize(
                    TaxDividend.Initialization({
                    factory: address(this),
                    taxToken: token,
                    quoteToken: params.quoteToken,
                    hook: address(context.hook),
                    feeEscrow: FeeEscrow(payable(context.hook.feeEscrow())),
                    minimumDividendHolding: params.taxConfiguration.minimumDividendHolding,
                    defaultExclusions: defaultExclusions
                })
                );
            TaxLaunchToken(token).initializeDividend(dividend);
        }
        TaxLaunchToken asset = TaxLaunchToken(token);
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
        TaxLaunchHook.PoolRegistration memory registration = TaxLaunchHook.PoolRegistration({
            token: token,
            creator: originalCreator,
            creatorFeeRecipient: params.creatorFeeRecipient,
            integratorFeeRecipient: params.integratorFeeRecipient,
            dividend: dividend,
            launchTime: uint48(block.timestamp),
            antiSnipeEnabled: params.antiSnipeEnabled,
            admittedPolicy: context.admittedPolicy,
            taxConfiguration: params.taxConfiguration
        });
        context.hook.registerPool(key, registration);
        context.hook.seedLiquidity(key, preparation.seedPositions, preparation.tokenIsCurrency0);
        return (token, key.toId(), key);
    }

    function predictTokenAddress(
        TaxLaunchTokenDeployer deployer,
        Core.LaunchParams calldata params,
        bytes32 salt,
        uint256 supply,
        TaxLaunchHook hook
    ) public view returns (address) {
        return deployer.predictTokenAddress(salt, tokenParams(params, supply, hook));
    }

    function tokenInitCodeHash(
        TaxLaunchTokenDeployer deployer,
        Core.LaunchParams calldata params,
        uint256 supply,
        TaxLaunchHook hook
    ) public view returns (bytes32) {
        return deployer.tokenInitCodeHash(tokenParams(params, supply, hook));
    }

    function tokenParams(Core.LaunchParams calldata params, uint256 supply, TaxLaunchHook hook)
        internal
        view
        returns (TaxLaunchToken.GenesisParams memory genesis)
    {
        address metadataAuthority;
        if (params.metadataEditable) metadataAuthority = address(this);
        genesis.factory = address(this);
        genesis.dividendsEnabled = params.taxConfiguration.dividendAllocationShare != 0;
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
