// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IB20Factory {
    function createB20(uint8 variant, bytes32 salt, bytes calldata params, bytes[] calldata initCalls)
        external
        payable
        returns (address token);
    function getB20Address(uint8 variant, address sender, bytes32 salt) external view returns (address);
}

interface IB20 {
    function name() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function updateName(string calldata) external;
    function mint(address, uint256) external;
    function updateSupplyCap(uint256) external;
    function hasRole(bytes32, address) external view returns (bool);
    function grantRole(bytes32, address) external;
    function renounceLastAdmin() external;
}

/// L0 check of a fixed-supply B20 on Base Sepolia: create, mint, METADATA_ROLE to a separate address,
/// renounceLastAdmin, then rename, transfer, approve and transferFrom.
/// Needs TEST_DEPLOYER_PRIVATE_KEY and TEST_METADATA_PRIVATE_KEY in .env (testnet keys only):
///   forge script script/L0B20Sepolia.s.sol:B20Sepolia --rpc-url https://base-sepolia-rpc.publicnode.com \
///     --hardfork base:Cobalt --broadcast
contract B20Sepolia is Script {
    IB20Factory constant FACTORY = IB20Factory(0xB20f000000000000000000000000000000000000);
    uint256 constant SUPPLY = 1_000_000_000e18;
    bytes32 constant METADATA_ROLE = 0x6bd6b5318a46e5fff572d5e4258a20774aab40cc35ac7680654b9081fcc82f80;

    struct AssetParams {
        uint8 version;
        string name;
        string symbol;
        address initialAdmin;
        uint8 decimals;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        uint256 metaKey = vm.envUint("TEST_METADATA_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address meta = vm.addr(metaKey);
        bytes32 salt = keccak256(abi.encode("place-launch-l0", block.timestamp));

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IB20.updateSupplyCap, (SUPPLY));
        calls[1] = abi.encodeCall(IB20.mint, (deployer, SUPPLY));
        calls[2] = abi.encodeCall(IB20.grantRole, (METADATA_ROLE, meta));

        vm.startBroadcast(deployerKey);
        IB20 t =
            IB20(FACTORY.createB20(0, salt, abi.encode(AssetParams(1, "Place L0 Test", "PL0", deployer, 18)), calls));
        t.renounceLastAdmin();
        payable(meta).transfer(0.0002 ether);
        t.transfer(meta, 1_000e18);
        t.approve(meta, 500e18);
        vm.stopBroadcast();

        vm.startBroadcast(metaKey);
        t.updateName("Place L0 Test Renamed");
        t.transferFrom(deployer, address(0xdead), 500e18);
        vm.stopBroadcast();

        console.log("token", address(t));
        console.log("name", t.name());
        console.log("totalSupply", t.totalSupply());
        console.log("supplyCap", t.supplyCap());
        console.log("deployer is admin", t.hasRole(bytes32(0), deployer));
        console.log("meta has METADATA_ROLE", t.hasRole(METADATA_ROLE, meta));
        console.log("dead balance", t.balanceOf(address(0xdead)));
    }
}
