// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {DeployPlaceLaunch} from "./DeployPlaceLaunch.s.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";

/// @notice Stage L5: deploys Place Launch 0.2.0-testnet (70/30 split, three-basket vaults, process(), community
///         fund, reward-token registry, PlaceStaking) to Base Sepolia with the testnet deployer key, registers the
///         testnet pairs and fund routes, and starts the two-step ownership transfer to the platform wallet, which
///         then calls `acceptOwnership` on the factory, X registry, reward-token registry and staking.
///
///   forge script script/L5Sepolia.s.sol --rpc-url base_sepolia --broadcast --slow --non-interactive --verify
///
/// Reads TEST_DEPLOYER_PRIVATE_KEY from .env inside forge (testnet key only). Testnet settings (low on purpose so
/// the live run can exercise everything with testnet volumes):
///   - platform 30%, anti-snipe surplus, launch fee and the 5% staking fee go to the platform wallet 0x9F68…6fC4;
///   - fund campaigns go to PlaceHub 1.0.0 (5% fee, like every campaign) with rules/launch-holders-v2.json;
///   - process(): every 1 hour, at most 0.0001 ETH / 0.1 USDC per call; default campaign after 30 days idle,
///     minimum 0.0001 ETH / 0.1 USDC; fund swaps: at most 5% price impact per hop;
///   - routes: ETH <-> USDC through the Uniswap v4 ETH/USDC 1% pool on Base Sepolia;
///   - start ticks as in the launch policy: ETH -200 600, USDC -400 600 (o1, token0 frame, ~ $4k FDV).
contract L5DeploySepolia is Script {
    address internal constant PLATFORM = 0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant PLACE_HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    int24 internal constant USDC_START_TICK = -400_600;
    bytes32 internal constant RULES_HASH = 0x43ea5fcc1dd629a01af4ab607cdbc11057b81cae85e82893b432cfd29c4ce8c4;
    string internal constant RULES_URI =
        "https://raw.githubusercontent.com/Maksyaka12/place-contracts/dev/rules/launch-holders-v2.json";
    string internal constant OUT_FILE = "deployments/base-sepolia-0.2.0.json";

    function run() external returns (DeployPlaceLaunch.Deployed memory d) {
        require(block.chainid == 84_532, "Base Sepolia only");
        address deployer = vm.rememberKey(vm.envUint("TEST_DEPLOYER_PRIVATE_KEY"));
        vm.setEnv("SENDER", vm.toString(deployer));
        vm.setEnv("POOL_MANAGER", vm.toString(POOL_MANAGER));
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(PLATFORM));
        vm.setEnv("PLACE_HUB", vm.toString(PLACE_HUB));
        vm.setEnv("RULES_HASH", vm.toString(RULES_HASH));
        vm.setEnv("RULES_URI", RULES_URI);
        vm.setEnv("MAX_PRICE_IMPACT_BPS", "500");
        vm.setEnv("PROCESS_INTERVAL", "3600");
        vm.setEnv("DEFAULT_CAMPAIGN_DELAY", "2592000");
        vm.setEnv("ETH_MAX_BURN", "100000000000000"); // 0.0001 ETH
        vm.setEnv("ETH_DEFAULT_MINIMUM", "100000000000000"); // 0.0001 ETH
        vm.setEnv("ENABLE_LAUNCHES", "true");
        vm.setEnv("FINAL_OWNER", vm.toString(PLATFORM)); // pending until the platform wallet accepts

        d = new DeployPlaceLaunch().run();

        // The deployer stays owner until the platform wallet accepts, so it finishes the testnet setup.
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 10_000, 200, IHooks(address(0)));
        vm.startBroadcast(deployer);
        d.factory.registerQuote(USDC, USDC_START_TICK);
        d.factory
            .setQuoteLimits(
                USDC, PlaceLaunchFactoryCore.QuoteLimits({maxBurnPerProcess: 100_000, defaultCampaignMinimum: 100_000})
            );
        d.rewardRegistry.setRoute(address(0), USDC, route);
        d.rewardRegistry.setRoute(USDC, address(0), route);
        vm.stopBroadcast();

        string memory o = "deploy";
        vm.serializeString(o, "version", "0.2.0-testnet");
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "factory", address(d.factory));
        vm.serializeAddress(o, "hook", address(d.hook));
        vm.serializeAddress(o, "feeEscrow", address(d.escrow));
        vm.serializeAddress(o, "creatorVaultImplementation", address(d.vaultImplementation));
        vm.serializeAddress(o, "xRecipientRegistry", address(d.xRegistry));
        vm.serializeAddress(o, "launchBuyAdapter", address(d.adapter));
        vm.serializeAddress(o, "announcementRegistry", address(d.announcements));
        vm.serializeAddress(o, "tokenDeployer", address(d.tokenDeployer));
        vm.serializeAddress(o, "rewardTokenRegistry", address(d.rewardRegistry));
        vm.serializeAddress(o, "staking", address(d.staking));
        vm.serializeAddress(o, "launchValidation", address(d.factory.launchValidation()));
        string memory json = vm.serializeAddress(o, "hub", PLACE_HUB);
        vm.writeJson(json, OUT_FILE);

        console.log("deployer", deployer);
        console.log("pending owner", d.factory.pendingOwner());
    }
}
