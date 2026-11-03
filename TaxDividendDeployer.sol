// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TaxDividend} from "./TaxDividend.sol";

interface ITaxDividendFactory {
    function dividendDeployer() external view returns (address);
}

/// @notice Fixed-target deterministic clone creation. The factory initializes each clone in its launch transaction.
contract TaxDividendDeployer {
    address public immutable factoryInitializer;
    TaxDividend public immutable implementation;
    address public factory;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyInitialized();

    constructor(address initializer, TaxDividend dividendImplementation) {
        if (initializer == address(0) || address(dividendImplementation).code.length == 0) {
            revert InvalidConfiguration();
        }
        factoryInitializer = initializer;
        implementation = dividendImplementation;
    }

    function initializeFactory(address launchFactory) external {
        if (msg.sender != factoryInitializer) revert Unauthorized();
        if (factory != address(0)) revert AlreadyInitialized();
        if (launchFactory.code.length == 0 || ITaxDividendFactory(launchFactory).dividendDeployer() != address(this)) {
            revert InvalidConfiguration();
        }
        factory = launchFactory;
    }

    function predictDividendAddress(bytes32 scopedSalt) external view returns (address) {
        return Clones.predictDeterministicAddress(address(implementation), scopedSalt, address(this));
    }

    function deploy(bytes32 scopedSalt) external returns (address dividend) {
        if (msg.sender != factory) revert Unauthorized();
        return Clones.cloneDeterministic(address(implementation), scopedSalt);
    }
}
