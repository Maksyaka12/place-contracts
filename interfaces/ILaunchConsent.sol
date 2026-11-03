// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaxFeeMath} from "../TaxFeeMath.sol";

/// @notice Optional interface for an integrator contract that wants a say in launches that name it.
/// @dev The hook asks once, when it registers the pool. Wallet integrators are never asked.
interface ILaunchConsent {
    struct LaunchContext {
        address token;
        address quoteToken;
        address creator;
        bool antiSnipeEnabled;
        TaxFeeMath.TaxConfiguration taxConfiguration;
    }

    /// @return verdict `LaunchConsent.REJECTED` blocks the launch. Every other outcome allows it:
    ///         another value, a revert, no code for this selector, or no answer within the gas limit.
    function launchConsent(LaunchContext calldata context) external view returns (bytes4 verdict);
}
