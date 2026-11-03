// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TaxFeeMath} from "./TaxFeeMath.sol";
import {ILaunchConsent} from "./interfaces/ILaunchConsent.sol";

/// @notice Lets an integrator contract refuse a launch that names it, and records a launch that it accepted.
/// @dev The question is a gas-limited static call, so an integrator cannot change state, cannot make a
///      launch expensive, and cannot return more than one word to the caller. Only the exact reject word
///      blocks, so an integrator can block only the launches that chose to name it. Only the exact accept
///      word is recorded. No answer, for any reason, lets the launch proceed without a record.
library LaunchConsent {
    using PoolIdLibrary for PoolKey;

    // forge-lint: disable-next-line(unsafe-typecast) a tag is the leading four bytes of its hash by definition
    bytes4 internal constant REJECTED = bytes4(keccak256("LAUNCH_REJECTED"));
    bytes4 internal constant ACCEPTED = ILaunchConsent.launchConsent.selector;
    uint256 internal constant GAS = 50_000;
    /// @dev EIP-150 forwards at most 63/64 of the remaining gas. The margin covers the call itself.
    uint256 private constant MINIMUM_GAS_BEFORE_CALL = GAS + GAS / 63 + 3_000;

    error IntegratorRejectedLaunch(address integrator);
    error InsufficientGasForLaunchConsent();

    event LaunchConsented(PoolId indexed poolId, address indexed integrator);

    /// @param consented The caller's record of pools whose named integrator accepted the launch.
    function requireConsent(
        mapping(PoolId poolId => bool accepted) storage consented,
        PoolKey calldata poolKey,
        bool tokenIsCurrency0,
        address integrator,
        address creator,
        bool antiSnipeEnabled,
        TaxFeeMath.TaxConfiguration calldata taxConfiguration
    ) internal {
        if (integrator.code.length == 0) return;
        address token = Currency.unwrap(poolKey.currency1);
        address quoteToken = Currency.unwrap(poolKey.currency0);
        if (tokenIsCurrency0) (token, quoteToken) = (quoteToken, token);
        bool accepted = requireConsentFor(
            integrator, ILaunchConsent.LaunchContext(token, quoteToken, creator, antiSnipeEnabled, taxConfiguration)
        );
        if (!accepted) return;
        PoolId poolId = poolKey.toId();
        consented[poolId] = true;
        emit LaunchConsented(poolId, integrator);
    }

    /// @return accepted True only when the integrator answered with the exact accept word.
    function requireConsentFor(address integrator, ILaunchConsent.LaunchContext memory context)
        internal
        view
        returns (bool accepted)
    {
        if (integrator.code.length == 0) return false;
        bytes memory payload = abi.encodeCall(ILaunchConsent.launchConsent, (context));
        // A caller must not be able to starve a rejecting integrator of gas and launch anyway.
        if (gasleft() < MINIMUM_GAS_BEFORE_CALL) revert InsufficientGasForLaunchConsent();
        bool answered;
        bytes32 word;
        assembly ("memory-safe") {
            let ok := staticcall(GAS, integrator, add(payload, 0x20), mload(payload), 0x00, 0x20)
            answered := and(ok, eq(returndatasize(), 0x20))
            word := mload(0x00)
        }
        if (!answered) return false;
        if (word == bytes32(REJECTED)) revert IntegratorRejectedLaunch(integrator);
        return word == bytes32(ACCEPTED);
    }
}
