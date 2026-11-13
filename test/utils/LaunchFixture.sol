// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceLaunchFactory} from "../../src/launch/PlaceLaunchFactory.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchTokenDeployer} from "../../src/launch/PlaceLaunchTokenDeployer.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {AnnouncementRegistry} from "../../src/AnnouncementRegistry.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";

/// @notice Deploys a full Place Launch suite (hook at a flag-mined address, factory, escrow, registry) on the
///         current chain: a fresh local PoolManager, or the real one on a fork.
abstract contract LaunchFixture is Test {
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    int24 internal constant SPACING = 200;
    /// @dev ETH quote, token0 frame: about $4k FDV at ETH ~ $2k (LAUNCH.md §8.3).
    int24 internal constant ETH_START_TICK = -200_200;

    address internal constant PLATFORM = address(0x9A7F);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0x7EAD);

    IPoolManager internal pm;
    PlaceLaunchHook internal hook;
    PlaceLaunchFactory internal factory;
    PlaceLaunchTokenDeployer internal tokenDeployer;
    FeeEscrow internal escrow;
    AnnouncementRegistry internal registry;
    PoolSwapTest internal router;

    function _deploySuite(IPoolManager existing) internal {
        pm = address(existing) == address(0) ? IPoolManager(address(new PoolManager(address(this)))) : existing;
        address hookAddress = address(uint160(0x4444 << 144) | HOOK_FLAGS);
        deployCodeTo("PlaceLaunchHook.sol:PlaceLaunchHook", abi.encode(pm, address(this)), hookAddress);
        hook = PlaceLaunchHook(hookAddress);
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
                creatorVaultImplementation: address(new PlaceCreatorVault())
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
        p.metadataKeys = new string[](1);
        p.metadataValues = new string[](1);
        p.metadataKeys[0] = "website";
        p.metadataValues[0] = "https://place.example";
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

    function _poolKey(address token, address quote) internal view returns (PoolKey memory key) {
        (address c0, address c1) = uint160(token) < uint160(quote) ? (token, quote) : (quote, token);
        key.currency0 = _c(c0);
        key.currency1 = _c(c1);
        key.fee = 0;
        key.tickSpacing = SPACING;
        key.hooks = hook;
    }

    function _c(address a) private pure returns (Currency) {
        return Currency.wrap(a);
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
        vm.prank(who);
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
}
