// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DeployPlaceLaunch} from "./DeployPlaceLaunch.s.sol";

/// @notice Stage L2: deploys Place Launch to Base Sepolia with the testnet deployer key, registers the testnet
///         pairs (ETH by the deploy script, USDC here) and starts the two-step ownership transfer to the platform
///         wallet, which then calls `acceptOwnership` on the factory and the X registry with its own keystore.
///
///   forge script script/L2Sepolia.s.sol --rpc-url base_sepolia --broadcast --slow --non-interactive
///
/// Reads TEST_DEPLOYER_PRIVATE_KEY from .env inside forge (testnet key only). Testnet settings:
///   - platform fees, anti-snipe and launch fee go to the platform wallet 0x9F68…6fC4;
///   - holder campaigns go to PlaceHub 1.0.0 on Base Sepolia with the rules template rules/launch-holders-v1.json;
///   - rewards minimum is low on purpose (0.0001 ETH, 0.1 USDC) so the live run can start a campaign;
///   - start ticks as in the launch policy: ETH -200 600, USDC -400 600 (o1, token0 frame, ~ $4k FDV).
contract L2DeploySepolia is Script {
    address internal constant PLATFORM = 0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant PLACE_HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    int24 internal constant USDC_START_TICK = -400_600;
    uint256 internal constant USDC_REWARDS_MINIMUM = 100_000; // 0.1 USDC
    bytes32 internal constant RULES_HASH = 0x3c661671f7061b99611a69edfdfc832a18d327d0dfe34fd997808954768fa015;
    string internal constant RULES_URI =
        "https://raw.githubusercontent.com/Maksyaka12/place-contracts/dev/rules/launch-holders-v1.json";

    function run() external returns (DeployPlaceLaunch.Deployed memory d) {
        require(block.chainid == 84_532, "Base Sepolia only");
        address deployer = vm.rememberKey(vm.envUint("TEST_DEPLOYER_PRIVATE_KEY"));
        vm.setEnv("SENDER", vm.toString(deployer));
        vm.setEnv("POOL_MANAGER", vm.toString(POOL_MANAGER));
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(PLATFORM));
        vm.setEnv("PLACE_HUB", vm.toString(PLACE_HUB));
        vm.setEnv("RULES_HASH", vm.toString(RULES_HASH));
        vm.setEnv("RULES_URI", RULES_URI);
        vm.setEnv("ETH_REWARDS_MINIMUM", "100000000000000"); // 0.0001 ETH
        vm.setEnv("ENABLE_LAUNCHES", "true");
        vm.setEnv("FINAL_OWNER", vm.toString(PLATFORM)); // pending until the platform wallet accepts

        d = new DeployPlaceLaunch().run();

        // The deployer stays owner until the platform wallet accepts, so it can finish the testnet setup.
        vm.startBroadcast(deployer);
        d.factory.registerQuote(USDC, USDC_START_TICK);
        d.factory.setRewardsMinimum(USDC, USDC_REWARDS_MINIMUM);
        vm.stopBroadcast();

        console.log("deployer", deployer);
        console.log("pending owner", d.factory.pendingOwner());
    }
}
