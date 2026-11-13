// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchBuyAdapter} from "../../src/place/PlaceLaunchBuyAdapter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchBuyTest is LaunchFixture {
    PlaceLaunchBuyAdapter internal adapter;
    MockERC20 internal usd;
    PoolKey internal ethUsd;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        adapter = new PlaceLaunchBuyAdapter(address(factory), address(hook), address(pm));
        factory.setLaunchBuyAdapter(address(adapter));

        // A plain v4 ETH/USD pool (no hook) for the ETH -> USD -> token route; 1 ETH = ~2000 USD.
        usd = new MockERC20("USD", "USD", 18);
        factory.registerQuote(address(usd), -124_200);
        ethUsd = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usd)), 3000, 60, IHooks(address(0)));
        pm.initialize(ethUsd, TickMath.getSqrtPriceAtTick(76_020));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        usd.mint(address(this), 1_000_000e18);
        usd.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 100 ether);
        lp.modifyLiquidity{value: 50 ether}(ethUsd, IPoolManager.ModifyLiquidityParams(-887_220, 887_220, 1e21, 0), "");
    }

    function _launchAndBuy(
        PlaceLaunchFactoryCore.LaunchParams memory p,
        address funding,
        uint256 amountIn,
        bytes memory route
    ) internal returns (address token, uint256 out) {
        _mineSalt(p, CREATOR);
        uint256 fee = factory.nativeLaunchFee();
        uint256 value = fee + (funding == address(0) ? amountIn : 0);
        vm.deal(CREATOR, value);
        vm.prank(CREATOR);
        (token,, out) = factory.createLaunchAndBuy{value: value}(
            p,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: funding, amountIn: amountIn, minAmountOut: 1, routeData: route
            })
        );
    }

    function test_devBuy_eth_directPool_normalFeeNoSurcharge() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        (address token, uint256 out) = _launchAndBuy(p, address(0), 1 ether, abi.encode(new PoolKey[](0)));
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(CREATOR), out);
        // the launch buy pays the normal 1% (0.25% platform), no 99% anti-snipe surcharge
        assertEq(escrow.owed(PLATFORM, address(0)), 0.0025 ether);
        assertEq(escrow.owed(address(_vault(token)), address(0)), 0.0075 ether);
        assertEq(address(adapter).balance, 0);
    }

    function test_devBuy_ethViaUsdHop() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(usd));
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = ethUsd;
        (address token, uint256 out) = _launchAndBuy(p, address(0), 0.1 ether, abi.encode(hops));
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(CREATOR), out);
        assertGt(escrow.owed(PLATFORM, address(usd)), 0, "fee taken in the quote (USD)");
        assertEq(usd.balanceOf(address(adapter)), 0);
    }

    function test_devBuy_erc20Funding_pulledFromCreator() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(usd));
        usd.mint(CREATOR, 100e18);
        vm.prank(CREATOR);
        usd.approve(address(adapter), 100e18);
        (address token, uint256 out) = _launchAndBuy(p, address(usd), 100e18, abi.encode(new PoolKey[](0)));
        assertEq(IERC20(token).balanceOf(CREATOR), out);
        assertEq(usd.balanceOf(CREATOR), 0);
        assertEq(escrow.owed(PLATFORM, address(usd)), 0.25e18);
    }

    function test_devBuy_badRoute_reverts() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(usd));
        _mineSalt(p, CREATOR);
        vm.deal(CREATOR, 2 ether);
        vm.prank(CREATOR);
        vm.expectRevert();
        factory.createLaunchAndBuy{value: 1.0005 ether}(
            p,
            PlaceLaunchFactoryCore.LaunchBuyParams({
                fundingToken: address(0), amountIn: 1 ether, minAmountOut: 1, routeData: abi.encode(new PoolKey[](0))
            })
        );
    }

    receive() external payable {}

    function test_adapter_onlyHook() public {
        PlaceLaunchBuyAdapter.LaunchBuyRequest memory r;
        vm.expectRevert(PlaceLaunchBuyAdapter.NotHook.selector);
        adapter.executeLaunchBuy(r);
    }
}
