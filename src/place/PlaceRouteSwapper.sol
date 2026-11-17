// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title PlaceRouteSwapper
/// @notice Exact-in swaps along a list of Uniswap v4 pools (a route of the PlaceRewardTokenRegistry or a launch's
///         own pool), straight against the PoolManager. Every hop must fill completely and may move its pool's
///         price by at most `maxImpactBps`; otherwise the whole swap reverts. The output stays in this contract.
abstract contract PlaceRouteSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SWAP_BPS = 10_000;

    bool private _swapping;

    error NotPoolManager();
    error EmptyRoute();
    error PartialFill();
    error PriceImpactTooHigh(uint256 impactBps, uint256 maxBps);

    function _poolManager() internal view virtual returns (IPoolManager);

    /// @dev Swaps `amountIn` of `input` along `hops`. Returns the input paid and the output received.
    function _swapRoute(address input, PoolKey[] memory hops, uint256 amountIn, uint256 maxImpactBps)
        internal
        returns (uint256 paid, uint256 out)
    {
        if (hops.length == 0) revert EmptyRoute();
        _swapping = true;
        bytes memory result = _poolManager().unlock(abi.encode(input, hops, amountIn, maxImpactBps));
        _swapping = false;
        (paid, out) = abi.decode(result, (uint256, uint256));
    }

    /// @dev Only reachable from this contract's own `unlock` in `_swapRoute`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager manager = _poolManager();
        if (msg.sender != address(manager) || !_swapping) revert NotPoolManager();
        (address input, PoolKey[] memory hops, uint256 amountIn, uint256 maxImpact) =
            abi.decode(data, (address, PoolKey[], uint256, uint256));
        address current = input;
        uint256 amount = amountIn;
        for (uint256 i = 0; i < hops.length; i++) {
            PoolKey memory key = hops[i];
            bool zeroForOne = Currency.unwrap(key.currency0) == current;
            PoolId id = key.toId();
            (uint160 priceBefore,,,) = StateLibrary.getSlot0(manager, id);
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
            int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
            if (inDelta > 0 || outDelta < 0) revert PartialFill();
            // forge-lint: disable-next-line(unsafe-typecast) inDelta <= 0 (we pay)
            if (uint256(uint128(-inDelta)) != amount) revert PartialFill();
            (uint160 priceAfter,,,) = StateLibrary.getSlot0(manager, id);
            uint256 impact = _impactBps(priceBefore, priceAfter);
            if (impact > maxImpact) revert PriceImpactTooHigh(impact, maxImpact);
            // forge-lint: disable-next-line(unsafe-typecast) outDelta >= 0 (we receive)
            amount = uint256(uint128(outDelta));
            current = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        }
        if (input == address(0)) {
            manager.settle{value: amountIn}();
        } else {
            manager.sync(Currency.wrap(input));
            IERC20(input).safeTransfer(address(manager), amountIn);
            manager.settle();
        }
        if (amount != 0) manager.take(Currency.wrap(current), address(this), amount);
        return abi.encode(amountIn, amount);
    }

    /// @dev |price_after / price_before - 1| in bps, from the two sqrt prices.
    function _impactBps(uint160 sqrtBefore, uint160 sqrtAfter) internal pure returns (uint256) {
        uint256 ratio = FullMath.mulDiv(sqrtAfter, 1e18, sqrtBefore);
        uint256 price = FullMath.mulDiv(ratio, ratio, 1e18);
        uint256 move = price > 1e18 ? price - 1e18 : 1e18 - price;
        return move * SWAP_BPS / 1e18;
    }
}
