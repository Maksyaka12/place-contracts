// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceLaunchFactory} from "../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";
import {FeeEscrow} from "../src/FeeEscrow.sol";
import {PlaceCreatorVault} from "../src/place/PlaceCreatorVault.sol";
import {PlaceCommunityVault} from "../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {PlaceStaking} from "../src/staking/PlaceStaking.sol";
import {VaultId} from "../src/staking/interfaces/IPlaceStakingCore.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev PlaceRewardsDistributor.stream() read as raw words (the full struct is too deep for a script).
interface IStreamWords {
    function stream(bytes32 id) external view returns (uint256[19] memory);
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Live run on Base Sepolia against 0.3.0-testnet (deployments/base-sepolia-0.3.0.json). Each phase is a
///         separate broadcast (the anti-snipe window and the daily epochs need real time):
///
///   forge script script/V6LiveRun.s.sol --sig "launch()"   --rpc-url <sepolia> --broadcast --slow --non-interactive
///   forge script script/V6LiveRun.s.sol --sig "trade()"    --rpc-url <sepolia> --broadcast --slow --non-interactive
///   forge script script/V6LiveRun.s.sol --sig "community()" --rpc-url <sepolia> --broadcast --slow --non-interactive
///   (after 00:00 UTC)
///   forge script script/V6LiveRun.s.sol --sig "close()"    --rpc-url <sepolia> --broadcast --slow --non-interactive
///   (the Place publisher posts the roots; the claim transactions come from the site API)
///   forge script script/V6LiveRun.s.sol --sig "claim()"    --rpc-url <sepolia> --broadcast --slow --non-interactive
///   (after the staking epoch: programStart + 1 day)
///   forge script script/V6LiveRun.s.sol --sig "claimStaking()" --rpc-url <sepolia> --broadcast --slow --non-interactive
///
///   launch():    the creator launches a Standard B20 on ETH and an Economy ERC-20 on USDC (buy 3%, sell 5%, all five
///                baskets, holder and trader rewards paid in ETH), each with a dev buy, and funds two extra wallets.
///   trade():     four wallets buy and sell through the Universal Router; anyone burns the burn basket.
///   community(): the creator spends the Economy token's community pool on a holders campaign (today + tomorrow)
///                and a staking program in the token (bought in its own pool); the trader stakes.
///   close():     the keeper's job: closes the finished epochs of every stream (the Economy streams swap USDC into
///                ETH) and converts deferred input.
///   claim():     sends the claimMany transactions in deployments/base-sepolia-v6-claims.json from each wallet.
/// Keys: TEST_DEPLOYER_PRIVATE_KEY (creator) and TEST_METADATA_PRIVATE_KEY (trader) from .env, testnet only; the two
/// extra wallets are derived from the creator key inside forge.
contract V6LiveRun is Script {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    IUniversalRouter internal constant UR = IUniversalRouter(0x492E6456D9528771018DeB9E87ef7750EF184104);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant SPACING = 200;
    uint16 internal constant VANITY = 0xe01; // token addresses end in …e01 (the factory requires the final 01)
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    string internal constant DEPLOY_FILE = "deployments/base-sepolia-0.3.0.json";
    string internal constant RUN_FILE = "deployments/base-sepolia-v6-run.json";
    string internal constant COMMUNITY_FILE = "deployments/base-sepolia-v6-community.json";
    string internal constant CLAIMS_FILE = "deployments/base-sepolia-v6-claims.json";

    bytes1 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    PlaceLaunchFactory internal factory;
    address internal hook;
    FeeEscrow internal escrow;
    PlaceRewardsDistributor internal distributor;
    PlaceStaking internal staking;
    uint256[4] internal keys; // creator, trader, wallet A, wallet B
    address[4] internal wallets;

    function _setup() internal {
        require(block.chainid == 84_532, "Base Sepolia only");
        string memory d = vm.readFile(DEPLOY_FILE);
        factory = PlaceLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        hook = vm.parseJsonAddress(d, ".hook");
        escrow = FeeEscrow(payable(vm.parseJsonAddress(d, ".feeEscrow")));
        distributor = PlaceRewardsDistributor(payable(vm.parseJsonAddress(d, ".rewardsDistributor")));
        staking = PlaceStaking(payable(vm.parseJsonAddress(d, ".staking")));
        keys[0] = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        keys[1] = vm.envUint("TEST_METADATA_PRIVATE_KEY");
        for (uint256 i = 2; i < 4; i++) {
            keys[i] = uint256(keccak256(abi.encode(keys[0], "place-v6-wallet", i))) % (SECP256K1_N - 1) + 1;
        }
        for (uint256 i = 0; i < 4; i++) {
            wallets[i] = vm.addr(keys[i]);
        }
    }

    // ───────────────────────────── Launch params ─────────────────────────────

    function _standardParams() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.B20;
        p.tokenName = "Place V6 Standard";
        p.tokenSymbol = "PV6S";
        p.quoteToken = address(0);
        _common(p);
    }

    function _economyParams() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.ERC20;
        p.tokenName = "Place V6 Economy";
        p.tokenSymbol = "PV6E";
        p.quoteToken = USDC;
        _common(p);
        p.economics.launchType = PlaceLaunchFactoryCore.LaunchType.Economy;
        p.economics.buyTaxRate = 3_000_000; // 3%
        p.economics.sellTaxRate = 5_000_000; // 5%
        p.economics.allocation = PlaceLaunchFactoryCore.Allocation({
            creator: 30_000_000, holders: 25_000_000, traders: 20_000_000, burn: 15_000_000, community: 10_000_000
        });
        p.economics.minHolding = 10_000e18;
        p.economics.minTraderDailyVolume = 0.1e6; // 0.1 USDC a day
        p.economics.rewardToken = address(0); // paid in ETH: USDC -> ETH through the reward-token registry
    }

    function _common(PlaceLaunchFactoryCore.LaunchParams memory p) internal view {
        p.tokenContractURI = "https://place-blond.vercel.app/launch/l2-test.json";
        p.expectedConfigVersion = factory.configVersion();
        p.deadline = uint64(block.timestamp + 1 hours);
        p.metadataEditable = true;
        p.antiSnipeEnabled = true;
        p.metadataKeys = new string[](1);
        p.metadataValues = new string[](1);
        (p.metadataKeys[0], p.metadataValues[0]) = ("website", "https://place-blond.vercel.app");
        p.economics.xShares = new PlaceCreatorVault.XShare[](0);
    }

    /// @dev Deterministic: the first unused salt whose predicted token address ends in VANITY.
    function _mine(PlaceLaunchFactoryCore.LaunchParams memory p) internal view returns (address predicted) {
        for (uint256 i = 0; i < 200_000; i++) {
            p.creatorSalt = keccak256(abi.encode("place-v6", i));
            predicted = factory.predictLaunchToken(p, wallets[0]);
            if (
                uint160(predicted) & 0xfff == VANITY
                    && !factory.isLaunchSaltUsed(keccak256(abi.encode(wallets[0], p.creatorSalt)))
            ) return predicted;
        }
        revert("no vanity salt");
    }

    // ───────────────────────────── Phase 1: launch ─────────────────────────────

    function launch() external {
        _setup();
        address std = _launchOne(_standardParams(), address(0), 0.0003 ether);
        address eco = _launchOne(_economyParams(), USDC, 0.5e6);
        // gas and USDC for the two extra wallets
        vm.startBroadcast(keys[0]);
        for (uint256 i = 2; i < 4; i++) {
            payable(wallets[i]).transfer(0.0003 ether);
            IERC20(USDC).transfer(wallets[i], 0.3e6);
        }
        vm.stopBroadcast();
        _writeRun(std, eco);
    }

    function _launchOne(PlaceLaunchFactoryCore.LaunchParams memory p, address funding, uint256 devBuy)
        internal
        returns (address token)
    {
        address predicted = _mine(p);
        uint256 value = factory.nativeLaunchFee() + (funding == address(0) ? devBuy : 0);
        PlaceLaunchFactoryCore.LaunchBuyParams memory b = PlaceLaunchFactoryCore.LaunchBuyParams({
            fundingToken: funding, amountIn: devBuy, minAmountOut: 1, routeData: abi.encode(new PoolKey[](0))
        });
        vm.startBroadcast(keys[0]);
        if (funding != address(0)) IERC20(funding).approve(factory.launchBuyAdapter(), devBuy);
        uint256 devOut;
        (token,, devOut) = factory.createLaunchAndBuy{value: value}(p, b);
        vm.stopBroadcast();
        require(token == predicted, "address");
        console.log(p.tokenSymbol, token);
        console.log("  dev buy in / tokens out", devBuy, devOut);
    }

    function _writeRun(address std, address eco) internal {
        (, address communityVault) = factory.launchRecord(eco);
        console.log("Standard B20/ETH  creator vault", _creatorVault(std));
        console.log("Economy ERC20/USDC creator vault", _creatorVault(eco));
        console.log("  community vault", communityVault);
        for (uint256 i = 0; i < 4; i++) {
            console.log("wallet", i, wallets[i]);
        }
        string memory o = "run";
        vm.serializeAddress(o, "standard", std);
        vm.serializeAddress(o, "standardCreatorVault", _creatorVault(std));
        vm.serializeAddress(o, "economyCreatorVault", _creatorVault(eco));
        vm.serializeAddress(o, "economyCommunityVault", communityVault);
        vm.serializeBytes32(o, "holdersStream", distributor.economyStreamId(eco, IPlaceRewardsDistributor.Kind.Holders));
        vm.serializeBytes32(o, "tradersStream", distributor.economyStreamId(eco, IPlaceRewardsDistributor.Kind.Traders));
        vm.serializeAddress(o, "wallets", _walletList());
        string memory json = vm.serializeAddress(o, "economy", eco);
        vm.writeJson(json, RUN_FILE);
    }

    // ───────────────────────────── Phase 2: trade + burn ─────────────────────────────

    function trade() external {
        _setup();
        (address std, address eco) = _tokens();
        PoolKey memory ks = _key(std, address(0));
        PoolKey memory ke = _key(eco, USDC);

        // Standard: 1% per swap
        _sell(1, ks, std, _buy(1, ks, std, 0.0005 ether) / 2);
        _buy(2, ks, std, 0.0001 ether);

        // Economy: buy 3%, sell 5%; every wallet ends above the 10,000-token holding minimum and the 0.1 USDC
        // daily volume minimum, except wallet B, which sells most of its bag
        for (uint256 i = 0; i < 2; i++) {
            _sell(1, ke, eco, _buy(1, ke, eco, 0.4e6) / 2);
        }
        _buy(2, ke, eco, 0.2e6);
        _sell(3, ke, eco, _buy(3, ke, eco, 0.2e6) * 99 / 100);
        _buy(0, ke, eco, 0.1e6);

        // burn basket: anyone sends it to 0x…dEaD
        uint256 burnable = escrow.pendingBurn(eco);
        uint256 deadBefore = IERC20(eco).balanceOf(DEAD);
        vm.broadcast(keys[2]);
        uint256 burned = escrow.burn(eco);
        require(burned == burnable && IERC20(eco).balanceOf(DEAD) - deadBefore == burned, "burn");
        console.log("burned PV6E to 0xdead", burned);
        _status(std, eco);
    }

    // ───────────────────────────── Phase 3: community pool ─────────────────────────────

    function community() external {
        _setup();
        (, address eco) = _tokens();
        (, address cv) = factory.launchRecord(eco);
        PlaceCommunityVault vault = PlaceCommunityVault(payable(cv));
        vm.broadcast(keys[1]); // anyone
        vault.collect();
        uint256 fund = vault.fundBalance(USDC);
        console.log("community pool USDC", fund);
        uint64 today = distributor.currentEpoch();

        // holders campaign in USDC (no swap), today and tomorrow, 20,000-token minimum
        vm.broadcast(keys[0]);
        bytes32 campaign = vault.fundCampaign(_campaignRequest(fund / 2, today));

        // staking program paid in PV6E, bought in its own pool
        PlaceCommunityVault.StakingRequest memory sr = PlaceCommunityVault.StakingRequest({
            fundAsset: USDC,
            amountIn: vault.fundBalance(USDC),
            rewardToken: eco,
            minOut: 1,
            startTime: uint64(block.timestamp + 300),
            epochDuration: 1 days,
            epochCount: 1,
            earlyExitMode: 0,
            penaltyBps: 0
        });
        vm.broadcast(keys[0]);
        bytes32 program = vault.fundStaking(sr);

        // the trader stakes half of their bag
        uint256 bag = IERC20(eco).balanceOf(wallets[1]) / 2;
        vm.startBroadcast(keys[1]);
        IERC20(eco).approve(address(staking), bag);
        staking.deposit(VaultId.wrap(program), bag);
        vm.stopBroadcast();

        console.log("holders campaign");
        _logStream(campaign);
        console.log("staking program, trader staked PV6E", bag);
        console.logBytes32(program);
        string memory o = "community";
        vm.serializeBytes32(o, "holdersCampaign", campaign);
        vm.serializeBytes32(o, "stakingProgram", program);
        vm.serializeUint(o, "programStart", sr.startTime);
        string memory json = vm.serializeUint(o, "staked", bag);
        vm.writeJson(json, COMMUNITY_FILE);
    }

    function _campaignRequest(uint256 amountIn, uint64 startEpoch)
        internal
        pure
        returns (PlaceCommunityVault.CampaignRequest memory r)
    {
        r.kind = IPlaceRewardsDistributor.Kind.Holders;
        r.fundAsset = USDC;
        r.amountIn = amountIn;
        r.rewardToken = USDC;
        r.startEpoch = startEpoch;
        r.epochCount = 2;
        r.criterion = 20_000e18;
    }

    // ───────────────────────────── Phase 4: close epochs (keeper) ─────────────────────────────

    function close() external {
        _setup();
        string memory run = vm.readFile(RUN_FILE);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = vm.parseJsonBytes32(run, ".holdersStream");
        ids[1] = vm.parseJsonBytes32(run, ".tradersStream");
        ids[2] = vm.parseJsonBytes32(vm.readFile(COMMUNITY_FILE), ".holdersCampaign");
        vm.broadcast(keys[1]);
        uint256 closed = distributor.closeStreams(ids);
        console.log("closed streams", closed);
        for (uint256 i = 0; i < ids.length; i++) {
            if (_logStream(ids[i]) != 0) {
                vm.broadcast(keys[1]);
                distributor.convert(ids[i], 0);
                _logStream(ids[i]);
            }
        }
    }

    /// @dev Logs a stream and returns its Economy input still waiting for the swap.
    function _logStream(bytes32 id) internal view returns (uint256 pending) {
        // words: 2 economy, 9 lastClosedEpoch, 12 rewardPerEpoch, 13 pendingInput, 15 funded
        uint256[19] memory w = IStreamWords(address(distributor)).stream(id);
        console.logBytes32(id);
        console.log("  last closed epoch / per epoch", w[9], w[12]);
        console.log("  funded / pending input", w[15], w[13]);
        return w[2] != 0 ? w[13] : 0;
    }

    // ───────────────────────────── Phase 5: claims ─────────────────────────────

    /// @dev CLAIMS_FILE: {"wallet": [i, …], "to": [distributor, …], "data": [claimMany calldata, …]} from the
    ///      site's GET launch/rewards?account=… (claimMany[]).
    function claim() external {
        _setup();
        string memory json = vm.readFile(CLAIMS_FILE);
        uint256[] memory who = vm.parseJsonUintArray(json, ".wallet");
        address[] memory to = vm.parseJsonAddressArray(json, ".to");
        bytes[] memory data = vm.parseJsonBytesArray(json, ".data");
        for (uint256 i = 0; i < who.length; i++) {
            uint256 ethBefore = wallets[who[i]].balance;
            uint256 usdcBefore = IERC20(USDC).balanceOf(wallets[who[i]]);
            vm.broadcast(keys[who[i]]);
            (bool ok,) = to[i].call(data[i]);
            require(ok, "claimMany");
            console.log("wallet", who[i], wallets[who[i]]);
            console.log("  ETH received (after gas)", int256(wallets[who[i]].balance) - int256(ethBefore));
            console.log("  USDC received", IERC20(USDC).balanceOf(wallets[who[i]]) - usdcBefore);
        }
    }

    /// @notice After the staking epoch ends (programStart + 1 day): the trader claims the PV6E staking reward.
    function claimStaking() external {
        _setup();
        (, address eco) = _tokens();
        VaultId program = VaultId.wrap(vm.parseJsonBytes32(vm.readFile(COMMUNITY_FILE), ".stakingProgram"));
        uint64[] memory epochs = new uint64[](1);
        uint256 before = IERC20(eco).balanceOf(wallets[1]);
        vm.broadcast(keys[1]);
        uint256 reward = staking.claim(program, epochs, wallets[1]);
        require(reward > 0 && IERC20(eco).balanceOf(wallets[1]) - before == reward, "staking reward");
        console.log("staking reward PV6E", reward);
    }

    // ───────────────────────────── Helpers ─────────────────────────────

    function _walletList() internal view returns (address[] memory list) {
        list = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            list[i] = wallets[i];
        }
    }

    function _tokens() internal view returns (address std, address eco) {
        string memory json = vm.readFile(RUN_FILE);
        std = vm.parseJsonAddress(json, ".standard");
        eco = vm.parseJsonAddress(json, ".economy");
    }

    function _key(address token, address quote) internal view returns (PoolKey memory key) {
        (address c0, address c1) = uint160(token) < uint160(quote) ? (token, quote) : (quote, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(hook));
    }

    function _creatorVault(address token) internal view returns (address) {
        return factory.creatorRights(token).creatorFeeRecipient;
    }

    function _buy(uint256 w, PoolKey memory key, address token, uint256 amountIn) internal returns (uint256 out) {
        address quote =
            Currency.unwrap(key.currency0) == token ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        uint256 before = IERC20(token).balanceOf(wallets[w]);
        _swap(w, key, quote, amountIn);
        out = IERC20(token).balanceOf(wallets[w]) - before;
    }

    function _sell(uint256 w, PoolKey memory key, address token, uint256 amountIn) internal {
        _swap(w, key, token, amountIn);
    }

    /// @dev Exact-in single-pool swap through the Universal Router (Permit2 for ERC-20 input).
    function _swap(uint256 w, PoolKey memory key, address input, uint256 amountIn) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        address output = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key, zeroForOne: zeroForOne, amountIn: uint128(amountIn), amountOutMinimum: 0, hookData: ""
            })
        );
        params[1] = abi.encode(Currency.wrap(input), amountIn);
        params[2] = abi.encode(Currency.wrap(output), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);

        vm.startBroadcast(keys[w]);
        if (input != address(0)) {
            IERC20(input).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(input, address(UR), uint160(amountIn), uint48(block.timestamp + 1 hours));
        }
        UR.execute{value: input == address(0) ? amountIn : 0}(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + 1 hours
        );
        vm.stopBroadcast();
    }

    function _status(address std, address eco) internal view {
        string memory run = vm.readFile(RUN_FILE);
        bytes32 h = vm.parseJsonBytes32(run, ".holdersStream");
        bytes32 t = vm.parseJsonBytes32(run, ".tradersStream");
        (, address cv) = factory.launchRecord(eco);
        console.log("Standard creator vault owed ETH", escrow.owed(_creatorVault(std), address(0)));
        console.log("Economy creator vault owed USDC", escrow.owed(_creatorVault(eco), USDC));
        console.log("Economy community vault owed USDC", escrow.owed(cv, USDC));
        console.log(
            "holders / traders stream pending USDC", distributor.pendingCollection(h), distributor.pendingCollection(t)
        );
        console.log("PoolManager holds PV6S / PV6E", IERC20(std).balanceOf(PM), IERC20(eco).balanceOf(PM));
        for (uint256 i = 0; i < 4; i++) {
            console.log("wallet", i, IERC20(eco).balanceOf(wallets[i]));
        }
    }
}
