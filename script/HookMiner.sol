// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Finds a CREATE2 salt whose address has exactly `flags` in its low 14 bits (Uniswap v4 hook permissions).
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF;
    uint256 internal constant MAX_LOOP = 500_000;

    function find(address deployer, uint160 flags, bytes memory initCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        return findFrom(deployer, flags, initCode, 0);
    }

    /// @dev Same, starting at salt `start` (to skip an address that is already deployed).
    function findFrom(address deployer, uint160 flags, bytes memory initCode, uint256 start)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = start; i < start + MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt found");
    }

    /// @dev Hashes in scratch space past the free memory pointer without moving it. `abi.encodePacked` here
    ///      allocated 85 bytes per salt that were never freed: after a long search the caller's memory was
    ///      megabytes long and every later allocation (e.g. contract creation code) paid quadratic expansion gas.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address hookAddress)
    {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, and(deployer, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore8(add(ptr, 11), 0xff)
            mstore(add(ptr, 32), salt)
            mstore(add(ptr, 64), initCodeHash)
            hookAddress := and(keccak256(add(ptr, 11), 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
