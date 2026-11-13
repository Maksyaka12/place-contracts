// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PlaceLaunchOperations} from "./PlaceLaunchOperations.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {PlaceLaunchHook} from "./PlaceLaunchHook.sol";
import {PlaceLaunchTokenDeployer} from "./PlaceLaunchTokenDeployer.sol";
import {PlaceLaunchFactoryCore} from "./PlaceLaunchFactoryCore.sol";

/// @title PlaceTokenFactoryBase
/// @notice Abstract token/deployer binding layer; only PlaceLaunchFactory is deployed.
/// @dev Keeps deterministic ERC20 creation separate from managed quote policy without adding a deployed factory.
abstract contract PlaceTokenFactoryBase is PlaceLaunchFactoryCore {
    PlaceLaunchTokenDeployer public immutable tokenDeployer;

    constructor(
        IPoolManager poolManagerAddress,
        PlaceLaunchHook launchHook,
        PlaceLaunchTokenDeployer launchTokenDeployer,
        FactoryInitialization memory initialFactoryConfiguration
    ) PlaceLaunchFactoryCore(poolManagerAddress, launchHook, initialFactoryConfiguration) {
        if (
            address(launchTokenDeployer) == address(0) || address(launchTokenDeployer).code.length == 0
                || launchTokenDeployer.factory() != address(0)
        ) revert InvalidConfig();
        tokenDeployer = launchTokenDeployer;
        launchValidation.validateInitialDeploymentRecipients(
            initialFactoryConfiguration.protocolFeeRecipient, address(this), launchHook, address(launchTokenDeployer)
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
            PlaceLaunchOperations.predictTokenAddress(
                tokenDeployer, launchParams, scopedSalt, currentLaunchSupply, hook
            );
    }

    function _createLaunchPool(LaunchParams calldata params, address creator, LaunchPreparation memory preparation)
        internal
        override
        returns (address token, PoolId poolId, PoolKey memory key)
    {
        return PlaceLaunchOperations.create(
            PlaceLaunchOperations.Context(hook, tokenDeployer, _policyState.policy, placeTaxConfiguration()),
            params,
            preparation,
            launchTokenKind,
            creator
        );
    }
}
