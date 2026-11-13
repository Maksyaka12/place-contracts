// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Launches against real Base pairs (ETH, USDC, cbBTC, NVDAc) on a Base mainnet fork (Cobalt hardfork).
contract LaunchBaseForkTest is LaunchFixture {
    IPoolManager internal constant BASE_PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com")));
        _deploySuite(BASE_PM);
        // o1's current start ticks (LAUNCH.md §8.3, launch-pairs-o1-base.csv)
        factory.registerQuote(USDC, -400_600);
        factory.registerQuote(CBBTC, -466_600);
        factory.registerQuote(NVDAC, -405_600);
    }

    function _fund(address quote, uint256 amount) internal {
        if (quote == NVDAC) {
            vm.prank(address(BASE_PM)); // B20: deal() cannot write precompile storage; the PM holds NVDAc
            IERC20(NVDAC).transfer(TRADER, amount);
        } else {
            deal(quote, TRADER, amount);
        }
    }

    function _roundTrip(PlaceLaunchFactoryCore.TokenKind kind, address quote, uint256 amountIn) internal {
        (address token,) = _launch(_params(kind, quote));
        PoolKey memory key = _poolKey(token, quote);
        vm.warp(block.timestamp + 21);
        if (quote != address(0)) _fund(quote, amountIn);
        _swap(TRADER, key, token, true, amountIn);
        uint256 bought = IERC20(token).balanceOf(TRADER);
        assertGt(bought, 0, "bought");
        address vault = address(_vault(token));
        assertEq(escrow.owed(PLATFORM, quote) * 3, escrow.owed(vault, quote), "75/25");
        _swap(TRADER, key, token, false, bought / 2);
        assertGt(escrow.owed(vault, quote), 0);
        escrow.claimFor(vault, quote);
    }

    function test_erc20_eth() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 0.4 ether);
    }

    function test_erc20_usdc() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.ERC20, USDC, 400e6);
    }

    function test_erc20_cbbtc() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.ERC20, CBBTC, 0.004e8);
    }

    function test_erc20_nvdac() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.ERC20, NVDAC, 2e8);
    }

    function test_b20_eth() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.B20, address(0), 0.4 ether);
    }

    function test_b20_nvdac() public {
        _roundTrip(PlaceLaunchFactoryCore.TokenKind.B20, NVDAC, 2e8);
    }
}
