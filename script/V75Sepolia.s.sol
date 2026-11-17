// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {DeployPlaceLaunch} from "./DeployPlaceLaunch.s.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";
import {PlacePriceGuard} from "../src/nft/PlacePriceGuard.sol";
import {PlaceNftCollection} from "../src/nft/PlaceNftCollection.sol";
import {PlaceNftFactory} from "../src/nft/PlaceNftFactory.sol";

/// @notice Deploys Place Launch 0.3.1-testnet to Base Sepolia: the NFT launchpad (PlacePriceGuard, PlaceNftCollection
///         template, PlaceNftFactory) and a new launch suite whose community vaults can fund NFT holders campaigns
///         and buy back and burn their token. Community vaults are clones with an immutable template, so the suite
///         (factory, hook, escrow, distributor, vault templates) is deployed again; the 0.3.0 suite keeps working
///         for its launches. The reward-token registry and PlaceStaking of 0.3.0 are reused, and the NFT factory
///         recognises creators of both launch factories.
///
///   forge script script/V75Sepolia.s.sol --rpc-url base_sepolia --account <keystore> --sender <address> \
///     --broadcast --slow --non-interactive --verify
///
/// Signs with the Foundry keystore (`--account`); reads no private key. Settings:
///   - NFT: platform 20% of mints and royalties, creation fee 0.0005 ETH, WETH royalties unwrapped;
///   - price guard: one observation per 60 s, reference moves at most 1% per observation, usable 30 min after the
///     first observation, quotes refused while spot and reference differ by more than 3%;
///   - launch suite: as 0.3.0 (platform 30% of the tax, 5% price impact per hop, 5% stream fee, default campaign
///     after 30 days); ETH and USDC pairs;
///   - every owner role starts a two-step transfer to the platform wallet, which then calls `acceptOwnership`.
contract V75DeploySepolia is Script {
    address internal constant PLATFORM = 0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4;
    address internal constant PUBLISHER = 0x0851B25D5D5b38BA260258A1520aff53E72c757d;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant FACTORY_0_3_0 = 0x5AC1d5Bf12017502242d45ae9F519DEdce15E453;
    address internal constant REWARD_REGISTRY = 0xF2941258d77903409DEc6746A9668Aa84D3899A0;
    address internal constant STAKING = 0x693dd75b148a12c3d90935ea6354C5d1e2629283;
    int24 internal constant USDC_START_TICK = -400_600;
    string internal constant OUT_FILE = "deployments/base-sepolia-0.3.1.json";

    struct Nft {
        PlacePriceGuard guard;
        PlaceNftCollection collectionImplementation;
        PlaceNftFactory factory;
    }

    function run() external returns (DeployPlaceLaunch.Deployed memory d, Nft memory n) {
        require(block.chainid == 84_532, "Base Sepolia only");
        address deployer = msg.sender; // --sender, signing with --account
        uint256 startBlock = block.number;
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        vm.startBroadcast(deployer);
        n.guard = new PlacePriceGuard(
            pm,
            deployer,
            PlacePriceGuard.Config({minInterval: 60, warmup: 30 minutes, maxStepBps: 100, maxDeviationBps: 300})
        );
        n.collectionImplementation = new PlaceNftCollection();
        n.factory = new PlaceNftFactory(
            pm,
            deployer,
            PlaceNftFactory.Settings({
                implementation: address(n.collectionImplementation),
                platformRecipient: PLATFORM,
                rewardRegistry: REWARD_REGISTRY,
                priceGuard: address(n.guard),
                weth: WETH,
                creationFee: 0.0005 ether
            })
        );
        n.factory.addLaunchFactory(FACTORY_0_3_0);
        vm.stopBroadcast();

        vm.setEnv("SENDER", vm.toString(deployer));
        vm.setEnv("POOL_MANAGER", vm.toString(POOL_MANAGER));
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(PLATFORM));
        vm.setEnv("REWARDS_PUBLISHER", vm.toString(PUBLISHER));
        vm.setEnv("PLACE_STAKING", vm.toString(STAKING));
        vm.setEnv("REWARD_REGISTRY", vm.toString(REWARD_REGISTRY));
        vm.setEnv("NFT_FACTORY", vm.toString(address(n.factory)));
        vm.setEnv("PRICE_GUARD", vm.toString(address(n.guard)));
        vm.setEnv("STREAM_FEE_BPS", "500");
        vm.setEnv("DEFAULT_CAMPAIGN_DELAY", "2592000");
        vm.setEnv("DEFAULT_CAMPAIGN_EPOCHS", "30");
        vm.setEnv("ETH_DEFAULT_MINIMUM", "100000000000000"); // 0.0001 ETH
        vm.setEnv("ENABLE_LAUNCHES", "true");
        vm.setEnv("FINAL_OWNER", vm.toString(PLATFORM));

        d = new DeployPlaceLaunch().run();

        vm.startBroadcast(deployer);
        d.factory.registerQuote(USDC, USDC_START_TICK);
        d.factory.setQuoteLimits(USDC, PlaceLaunchFactoryCore.QuoteLimits({defaultCampaignMinimum: 100_000}));
        n.factory.addLaunchFactory(address(d.factory));
        n.factory.transferOwnership(PLATFORM);
        n.guard.transferOwnership(PLATFORM);
        vm.stopBroadcast();

        string memory o = "deploy";
        vm.serializeString(o, "version", "0.3.1-testnet");
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", startBlock);
        vm.serializeAddress(o, "factory", address(d.factory));
        vm.serializeAddress(o, "hook", address(d.hook));
        vm.serializeAddress(o, "feeEscrow", address(d.escrow));
        vm.serializeAddress(o, "creatorVaultImplementation", address(d.vaultImplementation));
        vm.serializeAddress(o, "communityVaultImplementation", address(d.communityVaultImplementation));
        vm.serializeAddress(o, "rewardsDistributor", address(d.distributor));
        vm.serializeAddress(o, "xRecipientRegistry", address(d.xRegistry));
        vm.serializeAddress(o, "launchBuyAdapter", address(d.adapter));
        vm.serializeAddress(o, "announcementRegistry", address(d.announcements));
        vm.serializeAddress(o, "tokenDeployer", address(d.tokenDeployer));
        vm.serializeAddress(o, "rewardTokenRegistry", address(d.rewardRegistry));
        vm.serializeAddress(o, "staking", address(d.staking));
        vm.serializeAddress(o, "launchValidation", address(d.factory.launchValidation()));
        vm.serializeAddress(o, "priceGuard", address(n.guard));
        vm.serializeAddress(o, "nftCollectionImplementation", address(n.collectionImplementation));
        vm.serializeAddress(o, "nftFactory", address(n.factory));
        vm.serializeAddress(o, "previousFactory", FACTORY_0_3_0);
        string memory json = vm.serializeAddress(o, "publisher", PUBLISHER);
        vm.writeJson(json, OUT_FILE);

        console.log("deployer", deployer);
        console.log("PlacePriceGuard", address(n.guard));
        console.log("PlaceNftFactory", address(n.factory));
        console.log("PlaceNftCollection (implementation)", address(n.collectionImplementation));
    }
}
