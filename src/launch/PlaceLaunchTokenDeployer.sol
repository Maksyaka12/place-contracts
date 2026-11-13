// SPDX-License-Identifier: MIT
// Based on o1 (github.com/o1exchange/o1-launch-contracts, MIT, commit 3a49099); modified by Place.
pragma solidity 0.8.26;

import {PlaceLaunchToken} from "./PlaceLaunchToken.sol";

interface IPlaceLaunchTokenFactory {
    function tokenDeployer() external view returns (address);
}

/// @title PlaceLaunchTokenDeployer
/// @notice One-purpose CREATE2 deployer for tax launch tokens. It keeps the token creation bytecode out of the
///         factory, which keeps the factory under the size limit, while token addresses stay deterministic.
contract PlaceLaunchTokenDeployer {
    address public immutable factoryInitializer;
    address public factory;

    error AlreadyInitialized();
    error InvalidConfig();
    error TokenAlreadyExists(address token);
    error Unauthorized();

    constructor(address factoryInitializerAddress) {
        if (factoryInitializerAddress == address(0)) revert InvalidConfig();
        factoryInitializer = factoryInitializerAddress;
    }

    function initializeFactory(address factoryAddress) external {
        if (msg.sender != factoryInitializer) revert Unauthorized();
        if (factory != address(0)) revert AlreadyInitialized();
        if (factoryAddress == address(0) || factoryAddress.code.length == 0) revert InvalidConfig();
        if (IPlaceLaunchTokenFactory(factoryAddress).tokenDeployer() != address(this)) revert InvalidConfig();
        factory = factoryAddress;
    }

    function predictTokenAddress(bytes32 scopedSalt, PlaceLaunchToken.GenesisParams calldata genesisParams)
        external
        view
        returns (address predictedToken)
    {
        return _predictTokenAddress(scopedSalt, genesisParams);
    }

    function tokenInitCodeHash(PlaceLaunchToken.GenesisParams calldata genesisParams)
        external
        pure
        returns (bytes32 initCodeHash)
    {
        return _tokenInitCodeHash(genesisParams);
    }

    function deploy(bytes32 scopedSalt, PlaceLaunchToken.GenesisParams calldata genesisParams)
        external
        returns (address token)
    {
        address factoryAddress = factory;
        if (msg.sender != factoryAddress) revert Unauthorized();
        if (genesisParams.factory != factoryAddress) revert InvalidConfig();
        token = _predictTokenAddress(scopedSalt, genesisParams);
        if (token.code.length != 0) revert TokenAlreadyExists(token);
        return address(new PlaceLaunchToken{salt: scopedSalt}(genesisParams));
    }

    function _predictTokenAddress(bytes32 scopedSalt, PlaceLaunchToken.GenesisParams calldata genesisParams)
        internal
        view
        returns (address predictedToken)
    {
        bytes32 initCodeHash = _tokenInitCodeHash(genesisParams);
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), scopedSalt, initCodeHash))))
            );
    }

    function _tokenInitCodeHash(PlaceLaunchToken.GenesisParams calldata genesisParams)
        internal
        pure
        returns (bytes32 initCodeHash)
    {
        return keccak256(abi.encodePacked(type(PlaceLaunchToken).creationCode, abi.encode(genesisParams)));
    }
}
