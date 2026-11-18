// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {PlaceNftCollection} from "../src/nft/PlaceNftCollection.sol";
import {PlaceNftFactory} from "../src/nft/PlaceNftFactory.sol";

/// @notice Deploys a new PlaceNftCollection template to Base Sepolia and makes it the template of new collections
///         (`PlaceNftFactory.setImplementation`). Existing collections are EIP-1167 clones of the previous template
///         and keep it. This template: the holders share of the very first mint joins the 30-day holders pool.
///
///   forge script script/NftCollectionTemplate.s.sol --rpc-url base_sepolia --account <keystore> \
///     --sender <factory owner> --broadcast --slow --non-interactive --verify
///
/// Signs with the Foundry keystore (`--account`); reads no private key. `--sender` must be the factory owner (the
/// platform wallet). Without `--broadcast` it only simulates and writes nothing. On broadcast it records the new
/// template in `deployments/base-sepolia-0.3.1.json` (`nftCollectionImplementation`) and its history in
/// `deployments/base-sepolia-0.3.1-nft-template.json`.
contract NftCollectionTemplate is Script {
    PlaceNftFactory internal constant FACTORY = PlaceNftFactory(0xE5A54D2984F10EC21257C9C2491a54567C376322);
    string internal constant SUITE_FILE = "deployments/base-sepolia-0.3.1.json";
    string internal constant OUT_FILE = "deployments/base-sepolia-0.3.1-nft-template.json";

    function run() external returns (PlaceNftCollection template) {
        require(block.chainid == 84_532, "Base Sepolia only");
        address owner = msg.sender; // --sender, signing with --account
        require(FACTORY.owner() == owner, "sender is not the factory owner");
        address previous = FACTORY.implementation();
        uint256 startBlock = block.number;

        vm.startBroadcast(owner);
        template = new PlaceNftCollection();
        FACTORY.setImplementation(address(template));
        vm.stopBroadcast();

        require(FACTORY.implementation() == address(template), "template not set");
        require(template.owner() == owner, "template owner");
        console.log("previous template", previous);
        console.log("new template     ", address(template));

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            console.log("simulation: deployments not written");
            return template;
        }
        string memory o = "nftTemplate";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "nftFactory", address(FACTORY));
        vm.serializeAddress(o, "previousNftCollectionImplementation", previous);
        vm.serializeUint(o, "startBlock", startBlock);
        vm.serializeString(o, "change", "holders share of the first mint joins the holders pool");
        string memory json = vm.serializeAddress(o, "nftCollectionImplementation", address(template));
        vm.writeJson(json, OUT_FILE);
        vm.writeJson(vm.toString(address(template)), SUITE_FILE, ".nftCollectionImplementation");
    }
}
