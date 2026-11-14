// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
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

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
