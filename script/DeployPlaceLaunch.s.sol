// SPDX-License-Identifier: MIT
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
import {PlaceCommunityVault} from "../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../src/place/PlaceRewardsDistributor.sol";
import {XRecipientRegistry} from "../src/place/XRecipientRegistry.sol";
import {PlaceLaunchBuyAdapter} from "../src/place/PlaceLaunchBuyAdapter.sol";
import {PlaceRewardTokenRegistry} from "../src/place/PlaceRewardTokenRegistry.sol";
import {PlaceStaking} from "../src/staking/PlaceStaking.sol";

/// @notice Deploys and wires the whole Place Launch suite: Standard and Economy launches, creator and community
///         vaults, the rewards distributor, the reward-token registry and staking.
///
///   forge script script/DeployPlaceLaunch.s.sol --rpc-url base_sepolia --account <keystore> \
///     --sender <address> --broadcast --non-interactive
///
/// Settings come from the environment (no private keys: sign with --account / --ledger):
///   POOL_MANAGER            Uniswap v4 PoolManager (Base Sepolia 0x05E7…3408, Base 0x4985…2b2b)
///   PROTOCOL_FEE_RECIPIENT  platform fee + anti-snipe + launch fee + stream fee recipient (Safe on mainnet)
///   REWARDS_PUBLISHER       hot wallet that posts the daily reward roots (0 = none yet)
///   X_VERIFIER              signer of X bindings (0 = bindings paused)
///   FINAL_OWNER             optional: Safe that must acceptOwnership of factory, X registry, reward-token
///                           registry, rewards distributor and staking
///   PLACE_STAKING           existing PlaceStaking (default: deploy one, fee STAKING_FEE_BPS, default 500 = 5%)
///   STREAM_FEE_BPS          fee on funded reward streams, default 500 (5%)
///   MAX_PRICE_IMPACT_BPS    per-hop cap of reward and fund swaps in the reward-token registry, default 100 (1%)
///   DEFAULT_CAMPAIGN_DELAY  idle community fund -> default holders campaign, default 30 days
///   DEFAULT_CAMPAIGN_EPOCHS daily epochs of the default campaign, default 30
///   ETH_DEFAULT_MINIMUM     default campaign minimum in ETH, default 0.05 ether
///   ETH_START_TICK          default -200600 (~ $4k FDV)
///   ENABLE_LAUNCHES         default false
/// Reward-token routes are listed afterwards by the registry owner (`setRoute`).
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
        PlaceCommunityVault communityVaultImplementation;
        PlaceRewardsDistributor distributor;
        XRecipientRegistry xRegistry;
        PlaceLaunchBuyAdapter adapter;
        PlaceRewardTokenRegistry rewardRegistry;
        PlaceStaking staking;
    }

    function run() external returns (Deployed memory d) {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address protocolRecipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        address xVerifier = vm.envOr("X_VERIFIER", address(0));
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));
        address deployer = vm.envOr("SENDER", msg.sender); // = --sender; SENDER lets tests pick one

        // 1. Hook at a CREATE2 address whose low 14 bits are its permission flags.
        bytes memory hookInit = abi.encodePacked(type(PlaceLaunchHook).creationCode, abi.encode(pm, deployer));
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, hookInit);
        // A previous deploy from the same deployer may already sit at the first match: take the next one.
        while (hookAddress.code.length != 0) {
            (hookAddress, hookSalt) = HookMiner.findFrom(CREATE2_DEPLOYER, HOOK_FLAGS, hookInit, uint256(hookSalt) + 1);
        }
        console.log("hook (mined)", hookAddress);

        vm.startBroadcast(deployer);
        d.hook = new PlaceLaunchHook{salt: hookSalt}(pm, deployer);
        require(address(d.hook) == hookAddress, "hook address");

        // 2. Factory with its token deployer and vault templates.
        d.vaultImplementation = new PlaceCreatorVault();
        d.communityVaultImplementation = new PlaceCommunityVault();
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
                creatorVaultImplementation: address(d.vaultImplementation),
                communityVaultImplementation: address(d.communityVaultImplementation)
            })
        );

        // 3. Escrow and one-time wiring.
        d.escrow = new FeeEscrow(pm, address(d.hook));
        d.hook.initialize(address(d.factory), address(d.escrow));
        d.tokenDeployer.initializeFactory(address(d.factory));
        d.announcements = new AnnouncementRegistry(address(d.factory));
        d.factory.setAnnouncementRegistry(address(d.announcements));

        // 4. Place additions: X registry, dev-buy adapter, staking, reward-token registry, rewards distributor.
        d.xRegistry = new XRecipientRegistry(deployer, xVerifier);
        d.adapter = new PlaceLaunchBuyAdapter(address(d.factory), address(d.hook), address(pm));
        d.factory.setLaunchBuyAdapter(address(d.adapter));
        address existingStaking = vm.envOr("PLACE_STAKING", address(0));
        d.staking = existingStaking != address(0)
            ? PlaceStaking(payable(existingStaking))
            : new PlaceStaking(deployer, uint16(vm.envOr("STAKING_FEE_BPS", uint256(500))), protocolRecipient);
        d.rewardRegistry =
            new PlaceRewardTokenRegistry(deployer, uint16(vm.envOr("MAX_PRICE_IMPACT_BPS", uint256(100))));
        d.distributor = new PlaceRewardsDistributor(
            address(d.factory),
            deployer,
            vm.envOr("REWARDS_PUBLISHER", address(0)),
            uint16(vm.envOr("STREAM_FEE_BPS", uint256(500))),
            protocolRecipient
        );
        d.factory
            .setEconomySettings(
                PlaceLaunchFactoryCore.EconomySettings({
                    xRegistry: address(d.xRegistry),
                    staking: address(d.staking),
                    rewardRegistry: address(d.rewardRegistry),
                    rewardsDistributor: address(d.distributor),
                    defaultCampaignDelay: uint64(vm.envOr("DEFAULT_CAMPAIGN_DELAY", uint256(30 days))),
                    defaultCampaignEpochs: uint64(vm.envOr("DEFAULT_CAMPAIGN_EPOCHS", uint256(30)))
                })
            );
        d.factory
            .setQuoteLimits(
                address(0),
                PlaceLaunchFactoryCore.QuoteLimits({
                    defaultCampaignMinimum: uint128(vm.envOr("ETH_DEFAULT_MINIMUM", uint256(0.05 ether)))
                })
            );
        d.factory.registerQuote(address(0), int24(vm.envOr("ETH_START_TICK", int256(-200_600))));
        if (vm.envOr("ENABLE_LAUNCHES", false)) d.factory.setLaunchCreationEnabled(true);

        if (finalOwner != address(0)) {
            d.factory.transferOwnership(finalOwner);
            d.xRegistry.transferOwnership(finalOwner);
            d.rewardRegistry.transferOwnership(finalOwner);
            d.distributor.transferOwnership(finalOwner);
            if (existingStaking == address(0)) d.staking.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console.log("PlaceLaunchFactory", address(d.factory));
        console.log("PlaceLaunchHook", address(d.hook));
        console.log("FeeEscrow", address(d.escrow));
        console.log("AnnouncementRegistry", address(d.announcements));
        console.log("PlaceCreatorVault (implementation)", address(d.vaultImplementation));
        console.log("PlaceCommunityVault (implementation)", address(d.communityVaultImplementation));
        console.log("PlaceRewardsDistributor", address(d.distributor));
        console.log("XRecipientRegistry", address(d.xRegistry));
        console.log("PlaceLaunchBuyAdapter", address(d.adapter));
        console.log("PlaceLaunchTokenDeployer", address(d.tokenDeployer));
        console.log("PlaceRewardTokenRegistry", address(d.rewardRegistry));
        console.log("PlaceStaking", address(d.staking));
    }
}
