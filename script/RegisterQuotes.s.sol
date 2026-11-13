// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IRWAQuoteRegistry} from "../src/interfaces/IRWAQuoteRegistry.sol";

/// @notice Registers launch pairs in batches of 64, sorted by address (the factory requires both).
///
///   FACTORY=0x… QUOTES_FILE=script/quotes/base.json forge script script/RegisterQuotes.s.sol \
///     --rpc-url base --account <owner keystore> --sender <owner> --broadcast
///
/// `script/quotes/base.json` holds the launch pairs of LAUNCH.md decision #17 (USDC, cbBTC, cbDOGE, cbXRP,
/// cbLTC, cbADA, cbZEC, cbHYPE and the 288 Coinbase stocks) with o1's current start ticks; ETH is registered by
/// the deploy script. Already registered quotes are skipped. The price updater keeps ticks current afterwards.
contract RegisterQuotes is Script {
    uint256 internal constant BATCH = 64;

    function run() external {
        IRWAQuoteRegistry factory = IRWAQuoteRegistry(vm.envAddress("FACTORY"));
        string memory json = vm.readFile(vm.envOr("QUOTES_FILE", string("script/quotes/base.json")));
        address[] memory quotes = vm.parseJsonAddressArray(json, ".quoteTokens");
        int256[] memory ticks = vm.parseJsonIntArray(json, ".startTicks");
        require(quotes.length == ticks.length, "length");

        IRWAQuoteRegistry.QuoteRegistration[] memory pending = new IRWAQuoteRegistry.QuoteRegistration[](quotes.length);
        uint256 count;
        address previous;
        for (uint256 i = 0; i < quotes.length; i++) {
            require(i == 0 || uint160(quotes[i]) > uint160(previous), "quotes must be sorted");
            previous = quotes[i];
            (bool registered,,) = factory.quoteConfig(quotes[i]);
            if (registered) continue;
            pending[count++] = IRWAQuoteRegistry.QuoteRegistration(quotes[i], int24(ticks[i]));
        }
        console.log("to register", count);

        vm.startBroadcast(vm.envOr("SENDER", msg.sender));
        for (uint256 start = 0; start < count; start += BATCH) {
            uint256 size = count - start < BATCH ? count - start : BATCH;
            IRWAQuoteRegistry.QuoteRegistration[] memory batch = new IRWAQuoteRegistry.QuoteRegistration[](size);
            for (uint256 j = 0; j < size; j++) {
                batch[j] = pending[start + j];
            }
            factory.batchRegisterQuotes(batch);
        }
        vm.stopBroadcast();
    }
}
