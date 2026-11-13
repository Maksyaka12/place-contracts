// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IXRecipientRegistry} from "./interfaces/IXRecipientRegistry.sol";

/// @title XRecipientRegistry
/// @notice X account id -> payout wallet, for the X shares of creator vaults (LAUNCH.md decision #6).
///         A binding is made once, by anyone who submits a signature from the Place verifier (issued after the
///         person signs in to Place with that X account through Privy). After that only the bound wallet can move
///         the binding to another wallet. The owner can rotate the verifier, but can never write or overwrite a
///         binding, and a vault pays only the wallet this registry returns.
contract XRecipientRegistry is IXRecipientRegistry, Ownable2Step, EIP712 {
    bytes32 public constant BIND_TYPEHASH = keccak256("Bind(uint256 xId,address wallet,uint256 deadline)");

    /// @notice Signs bindings. address(0) pauses new bindings (existing ones keep working).
    address public verifier;

    mapping(uint256 xId => address wallet) public recipientOf;

    event VerifierUpdated(address indexed previousVerifier, address indexed newVerifier);
    event Bound(uint256 indexed xId, address indexed wallet);
    event Moved(uint256 indexed xId, address indexed previousWallet, address indexed newWallet);

    error InvalidWallet();
    error AlreadyBound(uint256 xId, address wallet);
    error NotBoundWallet(uint256 xId);
    error SignatureExpired(uint256 deadline);
    error InvalidSignature();
    error NoVerifier();

    constructor(address owner_, address verifier_) Ownable(owner_) EIP712("Place XRecipientRegistry", "1") {
        verifier = verifier_;
        emit VerifierUpdated(address(0), verifier_);
    }

    function setVerifier(address newVerifier) external onlyOwner {
        emit VerifierUpdated(verifier, newVerifier);
        verifier = newVerifier;
    }

    /// @notice Binds `xId` to `wallet` with the verifier's EIP-712 signature over Bind(xId, wallet, deadline).
    ///         Only possible while `xId` is unbound.
    function bind(uint256 xId, address wallet, uint256 deadline, bytes calldata signature) external {
        if (wallet == address(0) || xId == 0) revert InvalidWallet();
        address current = recipientOf[xId];
        if (current != address(0)) revert AlreadyBound(xId, current);
        // forge-lint: disable-next-line(block-timestamp) signature expiry
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
        address signer = verifier;
        if (signer == address(0)) revert NoVerifier();
        bytes32 digest = bindDigest(xId, wallet, deadline);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) revert InvalidSignature();
        recipientOf[xId] = wallet;
        emit Bound(xId, wallet);
    }

    /// @notice The bound wallet moves its own binding (lost key rotation is not possible by design).
    function move(uint256 xId, address newWallet) external {
        address current = recipientOf[xId];
        if (current == address(0) || msg.sender != current) revert NotBoundWallet(xId);
        if (newWallet == address(0) || newWallet == current) revert InvalidWallet();
        recipientOf[xId] = newWallet;
        emit Moved(xId, current, newWallet);
    }

    function bindDigest(uint256 xId, address wallet, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(BIND_TYPEHASH, xId, wallet, deadline)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
