// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {HookMiner} from "./HookMiner.sol";
import {PlaceLaunchHook} from "../src/launch/PlaceLaunchHook.sol";
import {PlaceLaunchFactory} from "../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchTokenDeployer} from "../src/launch/PlaceLaunchTokenDeployer.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {AnnouncementRegistry} from "../src/AnnouncementRegistry.sol";
import {PlaceCreatorVault} from "../src/place/PlaceCreatorVault.sol";
import {XRecipientRegistry} from "../src/place/XRecipientRegistry.sol";
import {PlaceLaunchBuyAdapter} from "../src/place/PlaceLaunchBuyAdapter.sol";

/// @notice Deploys and wires the whole Place Launch suite (the deploy itself is stage L2).
///
///   forge script script/DeployPlaceLaunch.s.sol --rpc-url base_sepolia --account <keystore> \
///     --sender <address> --broadcast --non-interactive
///
/// Settings come from the environment (no private keys: sign with --account / --ledger):
///   POOL_MANAGER            Uniswap v4 PoolManager (Base Sepolia 0x05E7…3408, Base 0x4985…2b2b)
///   PROTOCOL_FEE_RECIPIENT  platform fee + anti-snipe + launch fee recipient (Safe on mainnet)
///   PLACE_HUB               PlaceHub for holder reward campaigns (0 = rewards off for new launches)
///   X_VERIFIER              signer of X bindings (0 = bindings paused)
///   FINAL_OWNER             optional: Safe that must acceptOwnership of factory and X registry
///   RULES_URI, RULES_HASH   holder campaign rules (required when PLACE_HUB is set)
///   ETH_START_TICK          default -200600 (o1's current ETH tick, ~ $4k FDV)
///   ETH_REWARDS_MINIMUM     default 0.05 ether
///   ENABLE_LAUNCHES         default false
/// Other quotes are registered afterwards with script/RegisterQuotes.s.sol.
contract DeployPlaceLaunch is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant TICK_SPACING = 200;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    struct Deployed {
        PlaceLaunchHook hook;
        PlaceLaunchFactory factory;
        PlaceLaunchTokenDeployer tokenDeployer;
        FeeEscrow escrow;
        AnnouncementRegistry announcements;
        PlaceCreatorVault vaultImplementation;
        XRecipientRegistry xRegistry;
        PlaceLaunchBuyAdapter adapter;
    }

    function run() external returns (Deployed memory d) {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address protocolRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address hub = vm.envOr("PLACE_HUB", address(0));
        address xVerifier = vm.envOr("X_VERIFIER", address(0));
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));
        address deployer = vm.envOr("SENDER", msg.sender); // = --sender; SENDER lets tests pick one

        // 1. Hook at a CREATE2 address whose low 14 bits are its permission flags.
        bytes memory hookInit = abi.encodePacked(type(PlaceLaunchHook).creationCode, abi.encode(pm, deployer));
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, hookInit);
        console.log("hook (mined)", hookAddress);

        vm.startBroadcast(deployer);
        d.hook = new PlaceLaunchHook{salt: hookSalt}(pm, deployer);
        require(address(d.hook) == hookAddress, "hook address");

        // 2. Factory with its token deployer and vault template.
        d.vaultImplementation = new PlaceCreatorVault();
        d.tokenDeployer = new PlaceLaunchTokenDeployer(deployer);
        PlaceLaunchFactoryCore.Band[] memory bands = new PlaceLaunchFactoryCore.Band[](1);
        bands[0] = PlaceLaunchFactoryCore.Band({lowerOffset: 0, upperOffset: type(int24).max, supplyShareBps: 10_000});
        d.factory = new PlaceLaunchFactory(
            pm,
            d.hook,
            d.tokenDeployer,
            PlaceLaunchFactoryCore.FactoryInitialization({
                launchSupply: SUPPLY,
                tickSpacing: TICK_SPACING,
                protocolFeeRecipient: protocolRecipient,
                bandTemplate: bands,
                creatorVaultImplementation: address(d.vaultImplementation)
            })
        );

        // 3. Escrow and one-time wiring.
        d.escrow = new FeeEscrow(pm, address(d.hook));
        d.hook.initialize(address(d.factory), address(d.escrow));
        d.tokenDeployer.initializeFactory(address(d.factory));
        d.announcements = new AnnouncementRegistry(address(d.factory));
        d.factory.setAnnouncementRegistry(address(d.announcements));

        // 4. Place additions: X registry, dev-buy adapter, vault settings, ETH quote.
        d.xRegistry = new XRecipientRegistry(deployer, xVerifier);
        d.adapter = new PlaceLaunchBuyAdapter(address(d.factory), address(d.hook), address(pm));
        d.factory.setLaunchBuyAdapter(address(d.adapter));
        d.factory
            .setVaultSettings(
                PlaceLaunchFactoryCore.VaultSettings({
                    hub: hub,
                    xRegistry: address(d.xRegistry),
                    campaignInterval: 7 days,
                    rulesHash: hub == address(0) ? bytes32(0) : vm.envBytes32("RULES_HASH"),
                    rulesURI: hub == address(0) ? "" : vm.envString("RULES_URI")
                })
            );
        d.factory.setRewardsMinimum(address(0), vm.envOr("ETH_REWARDS_MINIMUM", uint256(0.05 ether)));
        d.factory.registerQuote(address(0), int24(vm.envOr("ETH_START_TICK", int256(-200_600))));
        if (vm.envOr("ENABLE_LAUNCHES", false)) d.factory.setLaunchCreationEnabled(true);

        if (finalOwner != address(0)) {
            d.factory.transferOwnership(finalOwner);
            d.xRegistry.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console.log("PlaceLaunchFactory", address(d.factory));
        console.log("PlaceLaunchHook", address(d.hook));
        console.log("FeeEscrow", address(d.escrow));
        console.log("AnnouncementRegistry", address(d.announcements));
        console.log("PlaceCreatorVault (implementation)", address(d.vaultImplementation));
        console.log("XRecipientRegistry", address(d.xRegistry));
        console.log("PlaceLaunchBuyAdapter", address(d.adapter));
        console.log("PlaceLaunchTokenDeployer", address(d.tokenDeployer));
    }
}
