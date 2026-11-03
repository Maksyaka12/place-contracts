// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {TaxLaunchOperations} from "./TaxLaunchOperations.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {TaxDividendDeployer} from "./TaxDividendDeployer.sol";

import {TaxLaunchHook} from "./TaxLaunchHook.sol";
import {TaxLaunchTokenDeployer} from "./TaxLaunchTokenDeployer.sol";
import {TaxLaunchpadFactoryCore} from "./TaxLaunchpadFactoryCore.sol";

/// @title TaxERC20FactoryBase
/// @notice Abstract token/deployer binding layer; only TaxRWAERC20LaunchpadFactory is deployed.
/// @dev Keeps deterministic ERC20 creation separate from managed quote policy without adding a deployed factory.
abstract contract TaxERC20FactoryBase is TaxLaunchpadFactoryCore {
    TaxLaunchTokenDeployer public immutable tokenDeployer;
    TaxDividendDeployer public immutable dividendDeployer;

    constructor(
        IPoolManager poolManagerAddress,
        TaxLaunchHook launchHook,
        TaxLaunchTokenDeployer launchTokenDeployer,
        TaxDividendDeployer launchDividendDeployer,
        FactoryInitialization memory initialFactoryConfiguration
    ) TaxLaunchpadFactoryCore(poolManagerAddress, launchHook, initialFactoryConfiguration) {
        if (
            address(launchTokenDeployer) == address(0) || address(launchTokenDeployer).code.length == 0
                || launchTokenDeployer.factory() != address(0)
        ) revert InvalidConfig();
        tokenDeployer = launchTokenDeployer;
        if (address(launchDividendDeployer).code.length == 0 || launchDividendDeployer.factory() != address(0)) {
            revert InvalidConfig();
        }
        dividendDeployer = launchDividendDeployer;
        launchValidation.validateInitialDeploymentRecipients(
            initialFactoryConfiguration.taxPolicy.protocolFeeConfiguration.protocolFeeRecipient,
            address(this),
            launchHook,
            address(launchTokenDeployer),
            launchDividendDeployer
        );
    }

    function _beforeCreateLaunch(LaunchParams calldata) internal view virtual override {}

    function _predictTokenAddress(LaunchParams calldata launchParams, bytes32 scopedSalt, uint256 currentLaunchSupply)
        internal
        view
        override
        returns (address)
    {
        return
            TaxLaunchOperations.predictTokenAddress(tokenDeployer, launchParams, scopedSalt, currentLaunchSupply, hook);
    }

    function _createLaunchPool(LaunchParams calldata params, address creator, LaunchPreparation memory preparation)
        internal
        override
        returns (address token, PoolId poolId, PoolKey memory key)
    {
        return TaxLaunchOperations.create(
            TaxLaunchOperations.Context(hook, tokenDeployer, dividendDeployer, _policyState.policy),
            params,
            preparation,
            _defaultDividendExclusions,
            creator
        );
    }
}
