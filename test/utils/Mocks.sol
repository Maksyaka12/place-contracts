// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockXRegistry {
    mapping(uint256 => address) public recipientOf;

    function bind(uint256 xId, address wallet) external {
        recipientOf[xId] = wallet;
    }
}

/// @notice Builds Merkle trees with the distributor's leaf format (sorted pairs, OpenZeppelin MerkleProof).
library MerkleHelper {
    function leaf(bytes32 streamId, address account, uint256 cumulativeAmount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(streamId, account, cumulativeAmount))));
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Root and per-leaf proofs of a tree over `leaves` (odd nodes are carried up unchanged).
    function build(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = leaves.length;
        proofs = new bytes32[][](n);
        uint256[] memory position = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            position[i] = i;
            proofs[i] = new bytes32[](0);
        }
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 m = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](m);
            for (uint256 j = 0; j < m; j++) {
                uint256 left = 2 * j;
                next[j] = left + 1 < level.length ? hashPair(level[left], level[left + 1]) : level[left];
            }
            for (uint256 i = 0; i < n; i++) {
                uint256 p = position[i];
                uint256 sibling = p ^ 1;
                if (sibling < level.length) proofs[i] = _push(proofs[i], level[sibling]);
                position[i] = p / 2;
            }
            level = next;
        }
        root = level[0];
    }

    function _push(bytes32[] memory arr, bytes32 value) private pure returns (bytes32[] memory out) {
        out = new bytes32[](arr.length + 1);
        for (uint256 i = 0; i < arr.length; i++) {
            out[i] = arr[i];
        }
        out[arr.length] = value;
    }
}
