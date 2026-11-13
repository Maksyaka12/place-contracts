// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPlaceLaunch} from "../../script/DeployPlaceLaunch.s.sol";
import {RegisterQuotes} from "../../script/RegisterQuotes.s.sol";

/// @notice Runs the deploy and quote-registration scripts on a Base mainnet fork and checks the result.
contract DeployScriptForkTest is Test {
    function test_deployAndRegisterAllLaunchPairs() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));
        vm.setEnv("POOL_MANAGER", "0x498581fF718922c3f8e6A244956aF099B2652b2b");
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", "0x0000000000000000000000000000000000009A7F");
        vm.setEnv("PLACE_HUB", "0x0000000000000000000000000000000000000000");
        vm.setEnv("ENABLE_LAUNCHES", "true");
        vm.setEnv("SENDER", "0x00000000000000000000000000000000000D3910");
        DeployPlaceLaunch deploy = new DeployPlaceLaunch();
        DeployPlaceLaunch.Deployed memory d = deploy.run();

        assertTrue(d.factory.launchCreationEnabled());
        assertEq(d.hook.factory(), address(d.factory));
        assertEq(d.factory.launchBuyAdapter(), address(d.adapter));
        assertEq(d.factory.nativeLaunchFee(), 0.0005 ether);
        assertEq(d.factory.taxPolicy().protocolFeeConfiguration.protocolTaxShare, 25_000_000);

        vm.setEnv("FACTORY", vm.toString(address(d.factory)));
        vm.setEnv("QUOTES_FILE", "script/quotes/base.json");
        assertEq(d.factory.owner(), address(0xD3910));
        new RegisterQuotes().run();

        (bool usdc,,) = d.factory.quoteConfig(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        (bool nvda, uint8 nvdaDecimals, int24 nvdaTick) =
            d.factory.quoteConfig(0xb20000000000000000000078ee7ce2fE4908108C);
        assertTrue(usdc);
        assertTrue(nvda);
        assertEq(nvdaDecimals, 8);
        assertEq(nvdaTick, -405_600);
    }
}
