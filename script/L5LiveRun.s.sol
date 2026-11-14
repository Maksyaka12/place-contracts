// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {PlaceLaunchFactory} from "../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../src/place/PlaceCreatorVault.sol";
import {PlaceStaking} from "../src/staking/PlaceStaking.sol";
import {VaultId} from "../src/staking/interfaces/IO1Staking.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
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

/// @notice Stage L5 live run on Base Sepolia against 0.2.0-testnet (deployments/base-sepolia-0.2.0.json). Each
///         phase is a separate broadcast (the anti-snipe window and the staking epoch need real time):
///
///   forge script script/L5LiveRun.s.sol --sig "launch()" --rpc-url base_sepolia --broadcast --slow --non-interactive
///   forge script script/L5LiveRun.s.sol --sig "trade()"  --rpc-url base_sepolia --broadcast --slow --non-interactive
///   forge script script/L5LiveRun.s.sol --sig "finish()" --rpc-url base_sepolia --broadcast --slow --non-interactive
///   (one day later)
///   forge script script/L5LiveRun.s.sol --sig "claimStaking()" --rpc-url base_sepolia --broadcast --slow --non-interactive
///
///   launch(): the creator launches a B20 on ETH (burn 25%, community 50%, creator 25%) and an ERC-20 on USDC
///             (burn 20%, community 40%, creator 40%), each with a dev buy.
///   trade():  a trader buys and sells through the Universal Router to fill the vaults (0.7% of every trade).
///   finish(): anyone runs process() (fees booked into the three baskets, burn bought back to 0x…dEaD); the
///             creator funds from the community funds: a PlaceHub campaign in USDC (ETH -> USDC swap in the same
///             transaction), a staking program in the B20 (bought in its own pool), a campaign in the ERC-20
///             (bought in its own pool) and a staking program in USDC (no swap); the trader stakes in both programs;
///             the creator claims; checks that the creator has no way to the funds.
///   claimStaking(): after the epoch ends, the trader claims both programs.
/// Keys: TEST_DEPLOYER_PRIVATE_KEY (creator) and TEST_METADATA_PRIVATE_KEY (trader) from .env, testnet only.
contract L5LiveRun is Script {
    address internal constant PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;
    address internal constant PLATFORM = 0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4;
    IUniversalRouter internal constant UR = IUniversalRouter(0x492E6456D9528771018DeB9E87ef7750EF184104);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant SPACING = 200;
    uint16 internal constant VANITY = 0xe01; // token addresses end in …e01 (the factory requires the final 01)
    string internal constant DEPLOY_FILE = "deployments/base-sepolia-0.2.0.json";
    string internal constant RUN_FILE = "deployments/base-sepolia-l5-run.json";
    string internal constant FINISH_FILE = "deployments/base-sepolia-l5-finish.json";

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
    address internal escrow;
    PlaceStaking internal staking;
    uint256 internal creatorKey;
    uint256 internal traderKey;
    address internal creator;
    address internal trader;

    function _setup() internal {
        require(block.chainid == 84_532, "Base Sepolia only");
        string memory d = vm.readFile(DEPLOY_FILE);
        factory = PlaceLaunchFactory(payable(vm.parseJsonAddress(d, ".factory")));
        hook = vm.parseJsonAddress(d, ".hook");
        escrow = vm.parseJsonAddress(d, ".feeEscrow");
        staking = PlaceStaking(payable(vm.parseJsonAddress(d, ".staking")));
        creatorKey = vm.envUint("TEST_DEPLOYER_PRIVATE_KEY");
        traderKey = vm.envUint("TEST_METADATA_PRIVATE_KEY");
        creator = vm.addr(creatorKey);
        trader = vm.addr(traderKey);
    }

    // ───────────────────────────── Launch params ─────────────────────────────

    function _b20Params() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.B20;
        p.tokenName = "Place L5 B20";
        p.tokenSymbol = "PL5B";
        p.quoteToken = address(0);
        p.economics.burnBps = 2_500;
        p.economics.communityBps = 5_000;
        _common(p);
    }

    function _erc20Params() internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p.tokenKind = PlaceLaunchFactoryCore.TokenKind.ERC20;
        p.tokenName = "Place L5 ERC20";
        p.tokenSymbol = "PL5E";
        p.quoteToken = USDC;
        p.economics.burnBps = 2_000;
        p.economics.communityBps = 4_000;
        _common(p);
    }

    function _common(PlaceLaunchFactoryCore.LaunchParams memory p) internal view {
        p.tokenContractURI = "https://place-blond.vercel.app/launch/l2-test.json";
        p.expectedConfigVersion = factory.configVersion();
        p.deadline = uint64(block.timestamp + 1 hours);
        p.metadataEditable = true;
        p.metadataKeys = new string[](1);
        p.metadataValues = new string[](1);
        (p.metadataKeys[0], p.metadataValues[0]) = ("website", "https://place-blond.vercel.app");
        p.economics.xShares = new PlaceCreatorVault.XShare[](0);
    }

    /// @dev Deterministic: the first unused salt whose predicted token address ends in VANITY.
    function _mine(PlaceLaunchFactoryCore.LaunchParams memory p) internal view returns (address predicted) {
        for (uint256 i = 0; i < 200_000; i++) {
            p.creatorSalt = keccak256(abi.encode("place-l5", i));
            predicted = factory.predictLaunchToken(p, creator);
            if (
                uint160(predicted) & 0xfff == VANITY
                    && !factory.isLaunchSaltUsed(keccak256(abi.encode(creator, p.creatorSalt)))
            ) return predicted;
        }
        revert("no vanity salt");
    }

    // ───────────────────────────── Phase 1: launch ─────────────────────────────

    function launch() external {
        _setup();
        PlaceLaunchFactoryCore.LaunchParams memory pb = _b20Params();
        PlaceLaunchFactoryCore.LaunchParams memory pe = _erc20Params();
        address predictedB20 = _mine(pb);
        address predictedErc20 = _mine(pe);
        uint256 fee = factory.nativeLaunchFee();
        bytes memory noHops = abi.encode(new PoolKey[](0));

        vm.startBroadcast(creatorKey);
        (address b20,, uint256 devOutB) = factory.createLaunchAndBuy{value: fee + 0.0005 ether}(
            pb,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: address(0), amountIn: 0.0005 ether, minAmountOut: 1, routeData: noHops
            })
        );
        IERC20(USDC).approve(factory.launchBuyAdapter(), 0.5e6);
        (address erc20,, uint256 devOutE) = factory.createLaunchAndBuy{value: fee}(
            pe,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: USDC, amountIn: 0.5e6, minAmountOut: 1, routeData: noHops
            })
        );
        vm.stopBroadcast();
        require(b20 == predictedB20 && erc20 == predictedErc20, "addresses");

        console.log("B20  ", b20, "vault", address(_vault(b20)));
        console.log("  dev buy 0.0005 ETH ->", devOutB);
        console.log("ERC20", erc20, "vault", address(_vault(erc20)));
        console.log("  dev buy 0.5 USDC ->", devOutE);
        string memory o = "run";
        vm.serializeAddress(o, "b20", b20);
        vm.serializeAddress(o, "b20Vault", address(_vault(b20)));
        vm.serializeAddress(o, "erc20Vault", address(_vault(erc20)));
        string memory json = vm.serializeAddress(o, "erc20", erc20);
        vm.writeJson(json, RUN_FILE);
    }

    // ───────────────────────────── Phase 2: trade ─────────────────────────────

    function trade() external {
        _setup();
        (address b20, address erc20) = _tokens();
        PoolKey memory kb = _key(b20, address(0));
        PoolKey memory ke = _key(erc20, USDC);
        for (uint256 i = 0; i < 6; i++) {
            uint256 out = _buy(kb, b20, 0.002 ether);
            _sell(kb, b20, out);
        }
        for (uint256 i = 0; i < 3; i++) {
            uint256 out = _buy(ke, erc20, 1.5e6);
            _sell(ke, erc20, out);
        }
        // the trader keeps a bag of each token to stake
        _buy(kb, b20, 0.0003 ether);
        _buy(ke, erc20, 0.3e6);
        _status(b20, erc20);
    }

    // ───────────────────────────── Phase 3: finish ─────────────────────────────

    function finish() external {
        _setup();
        (address b20, address erc20) = _tokens();
        PlaceCreatorVault vb = _vault(b20);
        PlaceCreatorVault ve = _vault(erc20);
        IHubConfig hubConfig = IHubConfig(IHub(HUB).config());
        console.log("hub fee bps B20 / ERC20", hubConfig.campaignFeeBps(b20), hubConfig.campaignFeeBps(erc20));

        // 1. process() by anyone (here the trader): book fees, burn up to the cap to 0xdead
        uint256 deadB = IERC20(b20).balanceOf(DEAD);
        uint256 deadE = IERC20(erc20).balanceOf(DEAD);
        vm.startBroadcast(traderKey);
        (uint256 collectedB, uint256 burnInB, uint256 burnedB) = vb.process();
        (uint256 collectedE, uint256 burnInE, uint256 burnedE) = ve.process();
        vm.stopBroadcast();
        require(IERC20(b20).balanceOf(DEAD) - deadB == burnedB && burnedB > 0, "b20 burn");
        require(IERC20(erc20).balanceOf(DEAD) - deadE == burnedE && burnedE > 0, "erc20 burn");
        console.log("B20 process: collected ETH", collectedB);
        console.log("  burned: ETH in / tokens to 0xdead", burnInB, burnedB);
        console.log("ERC20 process: collected USDC", collectedE);
        console.log("  burned: USDC in / tokens to 0xdead", burnInE, burnedE);

        // 2. community funds, creator only, minOut = 99% of a dry run against the same state
        uint256 fundB = vb.fundBalance(address(0));
        uint256 fundE = ve.fundBalance(USDC);
        console.log("community fund B20 (ETH) / ERC20 (USDC)", fundB, fundE);
        uint256 hubBefore = IHub(HUB).campaignCount();

        PlaceCreatorVault.CampaignRequest memory cb = _campaignReq(address(0), fundB / 2, USDC);
        cb.minOut = _dryCampaign(vb, cb) * 99 / 100;
        vm.broadcast(creatorKey);
        uint256 campaignB = vb.fundCampaign(cb);

        PlaceCreatorVault.StakingRequest memory sb =
            _stakingReq(address(0), vb.fundBalance(address(0)), b20, uint64(block.timestamp + 300));
        sb.minOut = _dryStaking(vb, sb) * 99 / 100;
        vm.broadcast(creatorKey);
        bytes32 programB = vb.fundStaking(sb);

        PlaceCreatorVault.CampaignRequest memory ce = _campaignReq(USDC, fundE / 2, erc20);
        ce.minOut = _dryCampaign(ve, ce) * 99 / 100;
        vm.broadcast(creatorKey);
        uint256 campaignE = ve.fundCampaign(ce);

        PlaceCreatorVault.StakingRequest memory se =
            _stakingReq(USDC, ve.fundBalance(USDC), USDC, uint64(block.timestamp + 300));
        vm.broadcast(creatorKey);
        bytes32 programE = ve.fundStaking(se);

        require(IHub(HUB).campaignCount() == hubBefore + 2, "campaigns");
        console.log("PlaceHub campaigns (USDC, PL5E)", campaignB, campaignE);
        console.log("  status (1 = Scheduled)", IHub(HUB).statusOf(campaignB), IHub(HUB).statusOf(campaignE));
        console.log("staking programs (PL5B reward, USDC reward)");
        console.logBytes32(programB);
        console.logBytes32(programE);

        // 3. the trader stakes in both programs (deposits open one epoch before the start)
        uint256 bagB = IERC20(b20).balanceOf(trader);
        uint256 bagE = IERC20(erc20).balanceOf(trader);
        vm.startBroadcast(traderKey);
        IERC20(b20).approve(address(staking), bagB);
        staking.deposit(VaultId.wrap(programB), bagB);
        IERC20(erc20).approve(address(staking), bagE);
        staking.deposit(VaultId.wrap(programE), bagE);
        vm.stopBroadcast();
        console.log("staked PL5B / PL5E", bagB, bagE);

        // 4. the creator claims their own basket
        uint256 creatorEth = creator.balance;
        vm.startBroadcast(creatorKey);
        uint256 paidB = vb.claim();
        uint256 paidE = ve.claim();
        vm.stopBroadcast();
        console.log("creator claim: ETH / USDC", paidB, paidE);

        // 5. checks on the resulting state (simulated, not broadcast): no way for the creator to the funds
        _noWithdraw(vb);
        _noWithdraw(ve);
        console.log("fund left B20 (ETH) / ERC20 (USDC)", vb.fundBalance(address(0)), ve.fundBalance(USDC));
        console.log("creator ETH change (claim minus gas)", int256(creator.balance) - int256(creatorEth));

        string memory o = "run2";
        vm.serializeUint(o, "campaignB20", campaignB);
        vm.serializeUint(o, "campaignErc20", campaignE);
        vm.serializeBytes32(o, "programB20", programB);
        vm.serializeBytes32(o, "programErc20", programE);
        vm.serializeUint(o, "programStart", sb.startTime);
        string memory json = vm.serializeUint(o, "programEpoch", sb.epochDuration);
        vm.writeJson(json, FINISH_FILE);
        _status(b20, erc20);
    }

    // ───────────────────────────── Phase 4: staking claims ─────────────────────────────

    function claimStaking() external {
        _setup();
        string memory json = vm.readFile(FINISH_FILE);
        VaultId programB = VaultId.wrap(vm.parseJsonBytes32(json, ".programB20"));
        VaultId programE = VaultId.wrap(vm.parseJsonBytes32(json, ".programErc20"));
        (address b20,) = _tokens();
        uint64[] memory epochs = new uint64[](1);
        uint256 b20Before = IERC20(b20).balanceOf(trader);
        uint256 usdcBefore = IERC20(USDC).balanceOf(trader);
        vm.startBroadcast(traderKey);
        uint256 rewardB = staking.claim(programB, epochs, trader);
        uint256 rewardE = staking.claim(programE, epochs, trader);
        vm.stopBroadcast();
        require(IERC20(b20).balanceOf(trader) - b20Before == rewardB && rewardB > 0, "b20 reward");
        require(IERC20(USDC).balanceOf(trader) - usdcBefore == rewardE && rewardE > 0, "usdc reward");
        console.log("staking rewards: PL5B / USDC", rewardB, rewardE);
    }

    // ───────────────────────────── Helpers ─────────────────────────────

    function _tokens() internal view returns (address b20, address erc20) {
        string memory json = vm.readFile(RUN_FILE);
        b20 = vm.parseJsonAddress(json, ".b20");
        erc20 = vm.parseJsonAddress(json, ".erc20");
    }

    function _campaignReq(address fundAsset, uint256 amountIn, address rewardToken)
        internal
        pure
        returns (PlaceCreatorVault.CampaignRequest memory r)
    {
        r.fundAsset = fundAsset;
        r.amountIn = amountIn;
        r.rewardToken = rewardToken;
        r.snapshotDelay = 24 hours;
        r.claimDuration = 30 days;
        r.burnLeftover = true;
        r.metadataURI = "";
    }

    function _stakingReq(address fundAsset, uint256 amountIn, address rewardToken, uint64 start)
        internal
        pure
        returns (PlaceCreatorVault.StakingRequest memory r)
    {
        r.fundAsset = fundAsset;
        r.amountIn = amountIn;
        r.rewardToken = rewardToken;
        r.startTime = start;
        r.epochDuration = 1 days;
        r.epochCount = 1;
        r.earlyExitMode = 0;
    }

    /// @dev Reward tokens a fund swap would give now: the swap output booked by the FundSwapped event.
    function _dryCampaign(PlaceCreatorVault vault, PlaceCreatorVault.CampaignRequest memory r)
        internal
        returns (uint256 out)
    {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(creator);
        vault.fundCampaign(r);
        out = _swapOut(vault);
        vm.revertToState(snap);
    }

    function _dryStaking(PlaceCreatorVault vault, PlaceCreatorVault.StakingRequest memory r)
        internal
        returns (uint256 out)
    {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(creator);
        vault.fundStaking(r);
        out = _swapOut(vault);
        vm.revertToState(snap);
    }

    function _swapOut(PlaceCreatorVault vault) internal returns (uint256 out) {
        bytes32 topic = keccak256("FundSwapped(address,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == topic) {
                (, out) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        require(out > 0, "no swap");
    }

    /// @dev The vault has no withdraw path: try the usual names as the creator (simulated).
    function _noWithdraw(PlaceCreatorVault vault) internal {
        string[4] memory sigs = [
            "withdraw(address,uint256)",
            "withdrawFund(address,uint256)",
            "sweep(address)",
            "rescue(address,address,uint256)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(creator);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(sigs[i], creator, uint256(1)));
            require(!ok, "withdraw path");
        }
    }

    function _key(address token, address quote) internal view returns (PoolKey memory key) {
        (address c0, address c1) = uint160(token) < uint160(quote) ? (token, quote) : (quote, token);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, SPACING, IHooks(hook));
    }

    function _vault(address token) internal view returns (PlaceCreatorVault) {
        return PlaceCreatorVault(payable(factory.creatorRights(token).creatorFeeRecipient));
    }

    function _buy(PoolKey memory key, address token, uint256 amountIn) internal returns (uint256 out) {
        address quote =
            Currency.unwrap(key.currency0) == token ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        uint256 before = IERC20(token).balanceOf(trader);
        _swap(key, quote, token, amountIn);
        out = IERC20(token).balanceOf(trader) - before;
    }

    function _sell(PoolKey memory key, address token, uint256 amountIn) internal {
        address quote =
            Currency.unwrap(key.currency0) == token ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        _swap(key, token, quote, amountIn);
    }

    /// @dev Exact-in single-pool swap through the Universal Router (Permit2 for ERC-20 input), as the trader.
    function _swap(PoolKey memory key, address input, address output, uint256 amountIn) internal {
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
    }

    function _status(address b20, address erc20) internal view {
        PlaceCreatorVault vb = _vault(b20);
        PlaceCreatorVault ve = _vault(erc20);
        console.log("vault B20  ", address(vb), "pending ETH", vb.pendingFees());
        console.log("  fund ETH", vb.fundBalance(address(0)), "burn reserve", vb.burnReserve());
        console.log("vault ERC20", address(ve), "pending USDC", ve.pendingFees());
        console.log("  fund USDC", ve.fundBalance(USDC), "burn reserve", ve.burnReserve());
        console.log(
            "platform owed ETH / USDC",
            IFeeEscrowView(escrow).owed(PLATFORM, address(0)),
            IFeeEscrowView(escrow).owed(PLATFORM, USDC)
        );
        console.log("PoolManager holds PL5B / PL5E", IERC20(b20).balanceOf(PM), IERC20(erc20).balanceOf(PM));
    }
}
