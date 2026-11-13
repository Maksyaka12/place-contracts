// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {PlaceLaunchFactory} from "../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../src/place/PlaceCreatorVault.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPoolModifyLiquidityTest {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256);
}

interface IHub {
    function campaignCount() external view returns (uint256);
    function statusOf(uint256 id) external view returns (uint8);
    function config() external view returns (address);
}

interface IHubConfig {
    function campaignFeeBps(address target) external view returns (uint16);
}

interface IFeeEscrowView {
    function owed(address recipient, address currency) external view returns (uint256);
}

/// @notice Stage L2 live run on Base Sepolia against the suite deployed by L2Sepolia.s.sol. Three phases, each a
///         separate broadcast (the anti-snipe window and the hub fee need real time and an owner call between):
///
///   forge script script/L2LiveRun.s.sol --sig "launch()" --rpc-url base_sepolia --broadcast --slow --non-interactive
///   forge script script/L2LiveRun.s.sol --sig "trade()"  --rpc-url base_sepolia --broadcast --slow --non-interactive
///   forge script script/L2LiveRun.s.sol --sig "finish()" --rpc-url base_sepolia --broadcast --slow --non-interactive
///
///   launch(): the creator launches a B20 on ETH and an ERC-20 on USDC (vanity suffix, editable metadata, dev buy,
///             buyback + holder rewards); a trader buys and sells through the Universal Router right away, inside
///             the 20 s anti-snipe window.
///   trade():  after the window, buy/sell rounds at the normal 1% fee to fill the vaults.
///   finish(): collect, holder campaigns in the real PlaceHub, creator claims with buyback (minOut from a dry run),
///             rename, and checks: ticker unchanged, liquidity cannot be removed or added.
/// `predict()` prints the two token addresses before launch (for PlaceConfig.setTargetFee).
/// Keys: TEST_DEPLOYER_PRIVATE_KEY (creator) and TEST_METADATA_PRIVATE_KEY (trader) from .env, testnet only.
contract L2LiveRun is Script {
    PlaceLaunchFactory internal constant FACTORY =
        PlaceLaunchFactory(payable(0xf3348E8bC017Aae708c278da3e1CBC1A8AE6fC55));
    address internal constant HOOK = 0xC6C32A05b5392a51f4eac82Fa163979F5166aAcC;
    address internal constant ESCROW = 0xaaA8458ED82EE3EC69Fd0cFda052882Eb807C0eA;
    address internal constant PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;
    address internal constant PLATFORM = 0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4;
    IUniversalRouter internal constant UR = IUniversalRouter(0x492E6456D9528771018DeB9E87ef7750EF184104);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolModifyLiquidityTest internal constant LIQUIDITY_ROUTER =
        IPoolModifyLiquidityTest(0x37429cD17Cb1454C34E7F50b09725202Fd533039);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant SPACING = 200;
    uint16 internal constant VANITY = 0xe01; // token addresses end in …e01 (the factory requires the final 01)
    string internal constant RUN_FILE = "deployments/base-sepolia-l2-run.json";

    // Universal Router: command V4_SWAP; v4 actions SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
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

    uint256 internal creatorKey;
    uint256 internal traderKey;
    address internal creator;
    address internal trader;

    function _keys() internal {
        require(block.chainid == 84_532, "Base Sepolia only");
        creatorKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        traderKey = vm.envUint("TEST_METADATA_PRIVATE_KEY");
        creator = vm.addr(creatorKey);
        trader = vm.addr(traderKey);
    }

    // ───────────────────────────── Launch params ─────────────────────────────

    function _b20Params() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.B20;
        p.tokenName = "Place L2 B20";
        p.tokenSymbol = "PL2B";
        p.tokenContractURI = "https://place-blond.vercel.app/launch/l2-test.json";
        p.quoteToken = address(0);
        p.economics.buybackBps = 2_000;
        p.economics.buybackBurn = true;
        p.economics.rewardsBps = 6_000;
        _common(p);
    }

    function _erc20Params() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.ERC20;
        p.tokenName = "Place L2 ERC20";
        p.tokenSymbol = "PL2E";
        p.tokenContractURI = "https://place-blond.vercel.app/launch/l2-test.json";
        p.quoteToken = USDC;
        p.economics.buybackBps = 3_000;
        p.economics.buybackBurn = false; // "hold": bought-back tokens go to the creator's payout address
        p.economics.rewardsBps = 4_000;
        _common(p);
    }

    function _common(PlaceLaunchFactoryCore.LaunchParams memory p) internal view {
        p.expectedConfigVersion = FACTORY.configVersion();
        p.deadline = uint64(block.timestamp + 1 hours);
        p.metadataEditable = true;
        p.metadataKeys = new string[](3);
        p.metadataValues = new string[](3);
        (p.metadataKeys[0], p.metadataValues[0]) = ("website", "https://place-blond.vercel.app");
        (p.metadataKeys[1], p.metadataValues[1]) = ("x", "https://x.com/place");
        (p.metadataKeys[2], p.metadataValues[2]) = ("telegram", "https://t.me/place");
        p.economics.xShares = new PlaceCreatorVault.XShare[](0);
    }

    /// @dev Deterministic: the first unused salt whose predicted token address ends in VANITY.
    function _mine(PlaceLaunchFactoryCore.LaunchParams memory p) internal view returns (address predicted) {
        for (uint256 i = 0; i < 200_000; i++) {
            p.creatorSalt = keccak256(abi.encode("place-l2", i));
            predicted = FACTORY.predictLaunchToken(p, creator);
            if (
                uint160(predicted) & 0xfff == VANITY
                    && !FACTORY.isLaunchSaltUsed(keccak256(abi.encode(creator, p.creatorSalt)))
            ) return predicted;
        }
        revert("no vanity salt");
    }

    function predict() external {
        _keys();
        console.log("B20   (ETH) ", _mine(_b20Params()));
        console.log("ERC20 (USDC)", _mine(_erc20Params()));
    }

    // ───────────────────────────── Phase 1: launch ─────────────────────────────

    function launch() external {
        _keys();
        PlaceLaunchFactoryCore.LaunchParams memory pb = _b20Params();
        PlaceLaunchFactoryCore.LaunchParams memory pe = _erc20Params();
        address predictedB20 = _mine(pb);
        address predictedErc20 = _mine(pe);
        uint256 fee = FACTORY.nativeLaunchFee();
        bytes memory noHops = abi.encode(new PoolKey[](0));

        // trader gas + trading money
        vm.startBroadcast(creatorKey);
        if (trader.balance < 0.012 ether) payable(trader).transfer(0.012 ether - trader.balance);
        if (IERC20(USDC).balanceOf(trader) < 6e6) IERC20(USDC).transfer(trader, 6e6 - IERC20(USDC).balanceOf(trader));
        vm.stopBroadcast();

        // B20 on ETH with a 0.001 ETH dev buy, then the trader inside the anti-snipe window
        vm.broadcast(creatorKey);
        (address b20,, uint256 devOutB) = FACTORY.createLaunchAndBuy{value: fee + 0.001 ether}(
            pb,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: address(0), amountIn: 0.001 ether, minAmountOut: 1, routeData: noHops
            })
        );
        require(b20 == predictedB20, "b20 address");
        PoolKey memory kb = _key(b20, address(0));
        uint256 snipeB = _buy(kb, b20, 0.0002 ether);
        _sell(kb, b20, IERC20(b20).balanceOf(trader) / 2);

        // ERC-20 on USDC with a 1 USDC dev buy, then the trader inside the window
        vm.startBroadcast(creatorKey);
        IERC20(USDC).approve(FACTORY.launchBuyAdapter(), 1e6);
        (address erc20,, uint256 devOutE) = FACTORY.createLaunchAndBuy{value: fee}(
            pe,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: USDC, amountIn: 1e6, minAmountOut: 1, routeData: noHops
            })
        );
        vm.stopBroadcast();
        require(erc20 == predictedErc20, "erc20 address");
        PoolKey memory ke = _key(erc20, USDC);
        uint256 snipeE = _buy(ke, erc20, 0.2e6);
        _sell(ke, erc20, IERC20(erc20).balanceOf(trader) / 2);

        console.log("B20", b20);
        console.log("  dev buy 0.001 ETH ->", devOutB);
        console.log("  (simulated) anti-snipe buy 0.0002 ETH ->", snipeB);
        console.log("ERC20", erc20);
        console.log("  dev buy 1 USDC ->", devOutE);
        console.log("  (simulated) anti-snipe buy 0.2 USDC ->", snipeE);

        string memory o = "run";
        vm.serializeAddress(o, "b20", b20);
        vm.serializeUint(o, "b20DevBuyOut", devOutB);
        vm.serializeUint(o, "b20AntiSnipeBuyOut", snipeB);
        vm.serializeAddress(o, "erc20", erc20);
        vm.serializeUint(o, "erc20DevBuyOut", devOutE);
        string memory json = vm.serializeUint(o, "erc20AntiSnipeBuyOut", snipeE);
        vm.writeJson(json, RUN_FILE);
    }

    // ───────────────────────────── Phase 2: trade ─────────────────────────────

    function trade() external {
        _keys();
        string memory json = vm.readFile(RUN_FILE);
        address b20 = vm.parseJsonAddress(json, ".b20");
        address erc20 = vm.parseJsonAddress(json, ".erc20");
        PoolKey memory kb = _key(b20, address(0));
        PoolKey memory ke = _key(erc20, USDC);

        // same-size buy as the anti-snipe one, now at 1%
        uint256 normalB = _buy(kb, b20, 0.0002 ether);
        uint256 normalE = _buy(ke, erc20, 0.2e6);
        console.log("B20 buy 0.0002 ETH after the window ->", normalB);
        console.log("ERC20 buy 0.2 USDC after the window ->", normalE);
        for (uint256 i = 0; i < 4; i++) {
            _buy(kb, b20, 0.0025 ether);
            _sell(kb, b20, IERC20(b20).balanceOf(trader));
        }
        for (uint256 i = 0; i < 5; i++) {
            _buy(ke, erc20, 5e6);
            _sell(ke, erc20, IERC20(erc20).balanceOf(trader));
        }
        // the trader keeps a small bag of each token for the holder snapshot
        _buy(kb, b20, 0.0003 ether);
        _buy(ke, erc20, 0.3e6);
        _status(b20, erc20);
    }

    /// @notice Extra B20/ETH buy-sell rounds if the B20 rewards pool is still below its minimum.
    function moreB20(uint256 rounds) external {
        _keys();
        string memory json = vm.readFile(RUN_FILE);
        address b20 = vm.parseJsonAddress(json, ".b20");
        address erc20 = vm.parseJsonAddress(json, ".erc20");
        PoolKey memory kb = _key(b20, address(0));
        uint256 keep = IERC20(b20).balanceOf(trader);
        for (uint256 i = 0; i < rounds; i++) {
            uint256 out = _buy(kb, b20, 0.0025 ether);
            _sell(kb, b20, out);
        }
        require(IERC20(b20).balanceOf(trader) == keep, "bag");
        _status(b20, erc20);
    }

    // ───────────────────────────── Phase 3: finish ─────────────────────────────

    function finish() external {
        _keys();
        string memory json = vm.readFile(RUN_FILE);
        address b20 = vm.parseJsonAddress(json, ".b20");
        address erc20 = vm.parseJsonAddress(json, ".erc20");
        PlaceCreatorVault vb = _vault(b20);
        PlaceCreatorVault ve = _vault(erc20);
        IHubConfig hubConfig = IHubConfig(IHub(HUB).config());
        console.log("hub fee bps B20 / ERC20", hubConfig.campaignFeeBps(b20), hubConfig.campaignFeeBps(erc20));

        // anyone can collect
        vm.startBroadcast(traderKey);
        vb.collect();
        ve.collect();
        vm.stopBroadcast();

        // holder campaigns from the rewards pools (creator: no interval wait)
        uint256 hubBefore = IHub(HUB).campaignCount();
        vm.startBroadcast(creatorKey);
        uint256 campaignB = vb.startRewardsCampaign();
        uint256 campaignE = ve.startRewardsCampaign();
        vm.stopBroadcast();
        require(IHub(HUB).campaignCount() == hubBefore + 2, "campaigns");
        console.log("PlaceHub campaigns", campaignB, campaignE);
        console.log("status (1 = Scheduled)", IHub(HUB).statusOf(campaignB), IHub(HUB).statusOf(campaignE));

        // creator claims with buyback; minOut = 99% of a dry run against the same state
        uint256 deadBefore = IERC20(b20).balanceOf(DEAD);
        uint256 payoutTokensBefore = IERC20(erc20).balanceOf(creator);
        uint256 minB = _dryClaim(vb) * 99 / 100;
        uint256 minE = _dryClaim(ve) * 99 / 100;
        vm.startBroadcast(creatorKey);
        (uint256 paidB, uint256 boughtB) = vb.claim(minB);
        (uint256 paidE, uint256 boughtE) = ve.claim(minE);
        vm.stopBroadcast();
        require(IERC20(b20).balanceOf(DEAD) - deadBefore == boughtB && boughtB >= minB, "burn");
        require(IERC20(erc20).balanceOf(creator) - payoutTokensBefore == boughtE && boughtE >= minE, "hold");
        console.log("B20 claim: paid ETH", paidB);
        console.log("  bought back and burned to 0xdead", boughtB, "minOut", minB);
        console.log("ERC20 claim: paid USDC", paidE);
        console.log("  bought back and held by the creator", boughtE, "minOut", minE);

        // rename (editable metadata); the ticker cannot change
        vm.startBroadcast(creatorKey);
        FACTORY.updateTokenName(b20, "Place L2 B20 Renamed");
        FACTORY.updateTokenName(erc20, "Place L2 ERC20 Renamed");
        FACTORY.updateTokenExtraMetadata(erc20, "website", "https://place-blond.vercel.app/launch");
        vm.stopBroadcast();
        require(keccak256(bytes(IERC20Metadata(b20).symbol())) == keccak256("PL2B"), "b20 ticker");
        require(keccak256(bytes(IERC20Metadata(erc20).symbol())) == keccak256("PL2E"), "erc20 ticker");
        console.log("names", IERC20Metadata(b20).name(), IERC20Metadata(erc20).name());
        console.log("tickers unchanged", IERC20Metadata(b20).symbol(), IERC20Metadata(erc20).symbol());
        (bool symbolCall,) =
            address(FACTORY).call(abi.encodeWithSignature("updateTokenSymbol(address,string)", b20, "NEW"));
        require(!symbolCall, "factory has no symbol setter");

        _liquidityLocked(b20, address(0));
        _liquidityLocked(erc20, USDC);
        _status(b20, erc20);
    }

    // ───────────────────────────── Helpers ─────────────────────────────

    function _key(address token, address quote) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = uint160(token) < uint160(quote) ? (token, quote) : (quote, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(HOOK));
    }

    function _vault(address token) internal view returns (PlaceCreatorVault) {
        return PlaceCreatorVault(payable(FACTORY.creatorRights(token).creatorFeeRecipient));
    }

    function _buy(PoolKey memory key, address token, uint256 amountIn) internal returns (uint256 out) {
        address quote =
            Currency.unwrap(key.currency0) == token ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        uint256 before = IERC20(token).balanceOf(trader);
        _swap(key, quote, token, amountIn);
        out = IERC20(token).balanceOf(trader) - before;
    }

    function _sell(PoolKey memory key, address token, uint256 amountIn) internal returns (uint256) {
        address quote =
            Currency.unwrap(key.currency0) == token ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        return _swap(key, token, quote, amountIn);
    }

    /// @dev Exact-in single-pool swap through the Universal Router (Permit2 for ERC-20 input), as the trader.
    function _swap(PoolKey memory key, address input, address output, uint256 amountIn) internal returns (uint256) {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
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

        vm.startBroadcast(traderKey);
        if (input != address(0)) {
            IERC20(input).approve(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(input, address(UR), uint160(amountIn), uint48(block.timestamp + 1 hours));
        }
        UR.execute{value: input == address(0) ? amountIn : 0}(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp + 1 hours
        );
        vm.stopBroadcast();
        return amountIn;
    }

    function _dryClaim(PlaceCreatorVault vault) internal returns (uint256 bought) {
        uint256 snap = vm.snapshotState();
        vm.prank(creator);
        (, bought) = vault.claim(1);
        vm.revertToState(snap);
    }

    /// @dev Removing (or adding) liquidity on a launch pool reverts in the hook: simulated through Uniswap's
    ///      PoolModifyLiquidityTest on Base Sepolia, not broadcast.
    function _liquidityLocked(address token, address quote) internal {
        PoolKey memory key = _key(token, quote);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        vm.prank(creator);
        try LIQUIDITY_ROUTER.modifyLiquidity(
            key, IPoolModifyLiquidityTest.ModifyLiquidityParams(lo, hi, -1e18, 0), ""
        ) {
            revert("liquidity removed");
        } catch (bytes memory reason) {
            require(_has(reason, bytes4(keccak256("LiquidityLocked()"))), "remove: not LiquidityLocked");
        }
        vm.prank(creator);
        try LIQUIDITY_ROUTER.modifyLiquidity(key, IPoolModifyLiquidityTest.ModifyLiquidityParams(lo, hi, 1e9, 0), "") {
            revert("liquidity added");
        } catch (bytes memory reason) {
            require(_has(reason, bytes4(keccak256("LiquidityLocked()"))), "add: not LiquidityLocked");
        }
        console.log("liquidity: remove and add both revert with LiquidityLocked for", token);
    }

    /// @dev The hook's error sits inside PoolManager's WrappedError, so look for its selector anywhere in the data.
    function _has(bytes memory data, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _status(address b20, address erc20) internal view {
        PlaceCreatorVault vb = _vault(b20);
        PlaceCreatorVault ve = _vault(erc20);
        console.log("vault B20  ", address(vb), "pending ETH", vb.pendingFees());
        console.log("  rewards available", vb.rewardsAvailable(), "buyback reserve", vb.buybackReserve());
        console.log("vault ERC20", address(ve), "pending USDC", ve.pendingFees());
        console.log("  rewards available", ve.rewardsAvailable(), "buyback reserve", ve.buybackReserve());
        console.log(
            "platform owed ETH / USDC",
            IFeeEscrowView(ESCROW).owed(PLATFORM, address(0)),
            IFeeEscrowView(ESCROW).owed(PLATFORM, USDC)
        );
        console.log("PoolManager holds B20 / ERC20", IERC20(b20).balanceOf(PM), IERC20(erc20).balanceOf(PM));
    }
}
