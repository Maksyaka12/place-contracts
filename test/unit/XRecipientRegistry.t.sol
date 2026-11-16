// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {XRecipientRegistry} from "../../src/place/XRecipientRegistry.sol";

contract XRecipientRegistryTest is Test {
    XRecipientRegistry internal reg;
    uint256 internal verifierKey = 0xA11CE;
    address internal verifier;
    address internal constant OWNER = address(0x0123);
    address internal constant WALLET = address(0xBEEF);

    function setUp() public {
        verifier = vm.addr(verifierKey);
        reg = new XRecipientRegistry(OWNER, verifier);
    }

    function _sign(uint256 key, uint256 xId, address wallet, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, reg.bindDigest(xId, wallet, deadline));
        return abi.encodePacked(r, s, v);
    }

    function test_bind_once_withVerifierSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        reg.bind(42, WALLET, deadline, _sign(verifierKey, 42, WALLET, deadline));
        assertEq(reg.recipientOf(42), WALLET);
        bytes memory sig = _sign(verifierKey, 42, address(0xBAD), deadline);
        vm.expectRevert(abi.encodeWithSelector(XRecipientRegistry.AlreadyBound.selector, 42, WALLET));
        reg.bind(42, address(0xBAD), deadline, sig);
    }

    function test_bind_rejectsWrongSigner_expired_wrongWallet() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory bad = _sign(0xB0B, 42, WALLET, deadline);
        vm.expectRevert(XRecipientRegistry.InvalidSignature.selector);
        reg.bind(42, WALLET, deadline, bad);
        bytes memory forOther = _sign(verifierKey, 42, address(0x1), deadline);
        vm.expectRevert(XRecipientRegistry.InvalidSignature.selector);
        reg.bind(42, WALLET, deadline, forOther);
        bytes memory ok = _sign(verifierKey, 42, WALLET, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(XRecipientRegistry.SignatureExpired.selector, deadline));
        reg.bind(42, WALLET, deadline, ok);
    }

    function test_ownerCannotOverwrite_onlyWalletMoves() public {
        uint256 deadline = block.timestamp + 1 hours;
        reg.bind(7, WALLET, deadline, _sign(verifierKey, 7, WALLET, deadline));
        // owner rotates the verifier, but the new verifier cannot rebind a bound id
        uint256 newKey = 0xC0DE;
        vm.prank(OWNER);
        reg.setVerifier(vm.addr(newKey));
        bytes memory sig = _sign(newKey, 7, OWNER, deadline);
        vm.expectRevert(abi.encodeWithSelector(XRecipientRegistry.AlreadyBound.selector, 7, WALLET));
        reg.bind(7, OWNER, deadline, sig);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(XRecipientRegistry.NotBoundWallet.selector, 7));
        reg.move(7, OWNER);
        vm.prank(WALLET);
        reg.move(7, address(0xCAFE));
        assertEq(reg.recipientOf(7), address(0xCAFE));
    }

    function test_setVerifier_onlyOwner_andPause() public {
        vm.expectRevert();
        reg.setVerifier(address(1));
        vm.prank(OWNER);
        reg.setVerifier(address(0));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(verifierKey, 9, WALLET, deadline);
        vm.expectRevert(XRecipientRegistry.NoVerifier.selector);
        reg.bind(9, WALLET, deadline, sig);
    }

    function testFuzz_bind_anyIdAndWallet(uint256 xId, address wallet) public {
        vm.assume(xId != 0 && wallet != address(0));
        uint256 deadline = block.timestamp + 1;
        reg.bind(xId, wallet, deadline, _sign(verifierKey, xId, wallet, deadline));
        assertEq(reg.recipientOf(xId), wallet);
    }
}
