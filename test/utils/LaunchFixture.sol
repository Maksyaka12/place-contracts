// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceLaunchFactory} from "../../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchTokenDeployer} from "../../src/launch/PlaceLaunchTokenDeployer.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {AnnouncementRegistry} from "../../src/AnnouncementRegistry.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {PlaceCommunityVault} from "../../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {PlaceRewardTokenRegistry} from "../../src/place/PlaceRewardTokenRegistry.sol";
import {PlaceStaking} from "../../src/staking/PlaceStaking.sol";
import {MockXRegistry} from "./Mocks.sol";
import {PlacePriceGuard} from "../../src/nft/PlacePriceGuard.sol";
import {PlaceNftCollection} from "../../src/nft/PlaceNftCollection.sol";
import {PlaceNftFactory} from "../../src/nft/PlaceNftFactory.sol";

/// @notice Deploys a full Place Launch suite (hook at a flag-mined address, factory, escrow, announcements) and
///         its economy (rewards distributor, reward-token registry with an ETH -> USD route through a plain v4 pool,
///         PlaceStaking, X registry) on the current chain: a fresh local PoolManager, or the real one on a fork.
abstract contract LaunchFixture is Test {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant SPACING = 200;
    /// @dev ETH quote, token0 frame: about $4k FDV at ETH ~ $2k.
    int24 internal constant ETH_START_TICK = -200_200;
    uint256 internal constant PCT = 1_000_000; // 1% in PERCENTAGE_SCALE
    uint32 internal constant SCALE = 100_000_000;

    address internal constant PLATFORM = address(0x9A7F);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0x7EAD);
    address internal constant PUBLISHER = address(0x9B11);

    uint64 internal constant DEFAULT_DELAY = 30 days;
    uint64 internal constant DEFAULT_EPOCHS = 30;
    uint128 internal constant DEFAULT_MIN = 0.001 ether;
    uint16 internal constant MAX_IMPACT = 500; // 5% per hop
    uint16 internal constant STREAM_FEE = 500; // 5%

    IPoolManager internal pm;
    PlaceLaunchHook internal hook;
    PlaceLaunchFactory internal factory;
    PlaceLaunchTokenDeployer internal tokenDeployer;
    FeeEscrow internal escrow;
    AnnouncementRegistry internal registry;
    PoolSwapTest internal router;

    PlaceRewardsDistributor internal distributor;
    PlaceRewardTokenRegistry internal rewards;
    PlaceStaking internal staking;
    MockXRegistry internal xreg;
    MockERC20 internal usd;
    PoolKey internal ethUsd;
    PoolModifyLiquidityTest internal lp;
    PlacePriceGuard internal guard;
    PlaceNftFactory internal nftFactory;

    uint32 internal constant GUARD_INTERVAL = 60;
    uint32 internal constant GUARD_WARMUP = 10 minutes;
    uint16 internal constant GUARD_STEP = 100; // 1% per observation
    uint16 internal constant GUARD_DEVIATION = 300; // 3%

    /// @dev The LP router refunds unused ETH; tests also receive stream refunds and payouts.
    receive() external payable {}

    function _deploySuite(IPoolManager existing) internal {
        // Reward epochs are UTC days: start from a realistic clock (forks already have one).
        if (block.timestamp < 1_000_000_000) vm.warp(1_767_225_600 + 12 hours);
        pm = address(existing) == address(0) ? IPoolManager(address(new PoolManager(address(this)))) : existing;
        address hookAddress = address(uint160(0x4444 << 144) | HOOK_FLAGS);
        deployCodeTo("PlaceLaunchHook.sol:PlaceLaunchHook", abi.encode(pm, address(this)), hookAddress);
        hook = PlaceLaunchHook(hookAddress);
        _deployNft();
        tokenDeployer = new PlaceLaunchTokenDeployer(address(this));
        PlaceLaunchFactoryCore.Band[] memory bands = new PlaceLaunchFactoryCore.Band[](1);
        bands[0] = PlaceLaunchFactoryCore.Band({lowerOffset: 0, upperOffset: type(int24).max, supplyShareBps: 10_000});
        factory = new PlaceLaunchFactory(
            pm,
            hook,
            tokenDeployer,
            PlaceLaunchFactoryCore.FactoryInitialization({
                launchSupply: SUPPLY,
                tickSpacing: SPACING,
                protocolFeeRecipient: PLATFORM,
                bandTemplate: bands,
                creatorVaultImplementation: address(new PlaceCreatorVault()),
                communityVaultImplementation: address(new PlaceCommunityVault(address(nftFactory), address(guard)))
            })
        );
        escrow = new FeeEscrow(pm, address(hook));
        hook.initialize(address(factory), address(escrow));
        tokenDeployer.initializeFactory(address(factory));
        registry = new AnnouncementRegistry(address(factory));
        factory.setAnnouncementRegistry(address(registry));
        factory.registerQuote(address(0), ETH_START_TICK);
        factory.setLaunchCreationEnabled(true);
        router = new PoolSwapTest(pm);
        _deployEconomy();
    }

    function _deployEconomy() internal {
        xreg = new MockXRegistry();
        staking = new PlaceStaking(address(this), 500, PLATFORM);
        rewards = new PlaceRewardTokenRegistry(address(this), MAX_IMPACT);
        distributor = new PlaceRewardsDistributor(address(factory), address(this), PUBLISHER, STREAM_FEE, PLATFORM);

        // A plain v4 ETH/USD pool (no hook), 1 ETH ~ 2000 USD, deep enough for reward and fund swaps.
        usd = new MockERC20("USD", "USD", 18);
        ethUsd = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usd)), 3000, 60, IHooks(address(0)));
        pm.initialize(ethUsd, TickMath.getSqrtPriceAtTick(76_020));
        lp = new PoolModifyLiquidityTest(pm);
        usd.mint(address(this), 1_000_000e18);
        usd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 100 ether);
        lp.modifyLiquidity{value: 50 ether}(ethUsd, IPoolManager.ModifyLiquidityParams(-887_220, 887_220, 1e21, 0), "");
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = ethUsd;
        rewards.setRoute(address(0), address(usd), route);
        rewards.setRoute(address(usd), address(0), route);

        factory.setEconomySettings(
            PlaceLaunchFactoryCore.EconomySettings({
                xRegistry: address(xreg),
                staking: address(staking),
                rewardRegistry: address(rewards),
                rewardsDistributor: address(distributor),
                defaultCampaignDelay: DEFAULT_DELAY,
                defaultCampaignEpochs: DEFAULT_EPOCHS
            })
        );
        factory.setQuoteLimits(address(0), PlaceLaunchFactoryCore.QuoteLimits({defaultCampaignMinimum: DEFAULT_MIN}));
        nftFactory.setRewardRegistry(address(rewards));
        nftFactory.addLaunchFactory(address(factory));
    }

    /// @dev Price guard and NFT factory (the community vault template needs both); registry and launch factory
    ///      are wired in `_deployEconomy`.
    function _deployNft() internal {
        guard = new PlacePriceGuard(
            pm,
            address(this),
            PlacePriceGuard.Config({
                minInterval: GUARD_INTERVAL,
                warmup: GUARD_WARMUP,
                maxStepBps: GUARD_STEP,
                maxDeviationBps: GUARD_DEVIATION
            })
        );
        nftFactory = new PlaceNftFactory(
            pm,
            address(this),
            PlaceNftFactory.Settings({
                implementation: address(new PlaceNftCollection()),
                platformRecipient: PLATFORM,
                rewardRegistry: address(0),
                priceGuard: address(guard),
                weth: address(0),
                creationFee: 0.0005 ether
            })
        );
    }

    /// @dev Observes `route` until its reference is warm: one observation per interval for the warmup period.
    function _warmGuard(PoolKey[] memory route) internal {
        guard.observeRoute(route);
        for (uint256 i = 0; i <= GUARD_WARMUP / GUARD_INTERVAL; i++) {
            vm.warp(vm.getBlockTimestamp() + GUARD_INTERVAL);
            vm.roll(vm.getBlockNumber() + 1);
            guard.observeRoute(route);
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _params(PlaceLaunchFactoryCore.TokenKind kind, address quote)
        internal
        view
        returns (PlaceLaunchFactoryCore.LaunchParams memory p)
    {
        p.tokenKind = kind;
        p.tokenName = "Place Test";
        p.tokenSymbol = "PLT";
        p.tokenContractURI = "ipfs://meta";
        p.quoteToken = quote;
        p.expectedConfigVersion = factory.configVersion();
        p.deadline = uint64(block.timestamp + 1 hours);
        p.metadataEditable = true;
        p.antiSnipeEnabled = true;
        p.metadataKeys = new string[](1);
        p.metadataValues = new string[](1);
        p.metadataKeys[0] = "website";
        p.metadataValues[0] = "https://place.example";
    }

    /// @dev Economy params; allocation in percent of the creator side (sum 100).
    function _economyParams(
        PlaceLaunchFactoryCore.TokenKind kind,
        address quote,
        uint32 buyPct,
        uint32 sellPct,
        uint32[5] memory sharesPct, // creator, holders, traders, burn, community
        address rewardToken
    ) internal view returns (PlaceLaunchFactoryCore.LaunchParams memory p) {
        p = _params(kind, quote);
        PlaceLaunchFactoryCore.Economics memory e = p.economics;
        e.launchType = PlaceLaunchFactoryCore.LaunchType.Economy;
        e.buyTaxRate = uint32(buyPct * PCT);
        e.sellTaxRate = uint32(sellPct * PCT);
        e.allocation = PlaceLaunchFactoryCore.Allocation({
            creator: sharesPct[0] * 1_000_000,
            holders: sharesPct[1] * 1_000_000,
            traders: sharesPct[2] * 1_000_000,
            burn: sharesPct[3] * 1_000_000,
            community: sharesPct[4] * 1_000_000
        });
        if (sharesPct[1] != 0) e.minHolding = 100_000e18;
        if (sharesPct[2] != 0) e.minTraderDailyVolume = 0.01 ether;
        if (sharesPct[1] != 0 || sharesPct[2] != 0) e.rewardToken = rewardToken;
    }

    /// @dev Mines `creatorSalt` until the predicted token address ends in the factory's 0x01 suffix.
    function _mineSalt(PlaceLaunchFactoryCore.LaunchParams memory p, address creator) internal view {
        for (uint256 i = 0;; i++) {
            p.creatorSalt = bytes32(i);
            address predicted = factory.predictLaunchToken(p, creator);
            if (
                uint160(predicted) & 0xff == 0x01
                    && !factory.isLaunchSaltUsed(keccak256(abi.encode(creator, p.creatorSalt)))
            ) {
                return;
            }
        }
    }

    function _launch(PlaceLaunchFactoryCore.LaunchParams memory p) internal returns (address token, PoolId poolId) {
        _mineSalt(p, CREATOR);
        uint256 fee = factory.nativeLaunchFee();
        vm.deal(CREATOR, CREATOR.balance + fee);
        vm.prank(CREATOR);
        (token, poolId) = factory.createLaunch{value: fee}(p);
    }

    function _vault(address token) internal view returns (PlaceCreatorVault) {
        return PlaceCreatorVault(payable(factory.creatorRights(token).creatorFeeRecipient));
    }

    function _community(address token) internal view returns (PlaceCommunityVault) {
        (, address vault) = factory.launchRecord(token);
        return PlaceCommunityVault(payable(vault));
    }

    function _holdersId(address token) internal view returns (bytes32) {
        return distributor.economyStreamId(token, IPlaceRewardsDistributor.Kind.Holders);
    }

    function _tradersId(address token) internal view returns (bytes32) {
        return distributor.economyStreamId(token, IPlaceRewardsDistributor.Kind.Traders);
    }

    function _poolKey(address token, address quote) internal view returns (PoolKey memory key) {
        (address c0, address c1) = uint160(token) < uint160(quote) ? (token, quote) : (quote, token);
        key.currency0 = Currency.wrap(c0);
        key.currency1 = Currency.wrap(c1);
        key.fee = 0;
        key.tickSpacing = SPACING;
        key.hooks = hook;
    }

    /// @dev Exact-in swap through the v4 test router. `buy` = quote in, token out.
    function _swap(address who, PoolKey memory key, address token, bool buy, uint256 amountIn)
        internal
        returns (BalanceDelta delta)
    {
        bool tokenIs0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = buy ? !tokenIs0 : tokenIs0;
        address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        uint256 value;
        if (input == address(0)) {
            vm.deal(who, who.balance + amountIn);
            value = amountIn;
        } else {
            vm.prank(who);
            IERC20(input).approve(address(router), amountIn);
        }
        vm.prank(who, who);
        delta = router.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Moves to the middle of the next UTC day.
    function _nextDay() internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 12 hours);
    }
}
