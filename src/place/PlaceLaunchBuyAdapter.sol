// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ILaunchBuyAdapter} from "../interfaces/ILaunchBuyAdapter.sol";

/// @title PlaceLaunchBuyAdapter
/// @notice The creator's launch buy ("dev buy", LAUNCH.md decision #7) in the launch transaction, behind o1's
///         `ILaunchBuyAdapter`. Flow: factory.createLaunchAndBuy -> hook.executeLaunchBuy (arms the one-swap
///         launch-buy context: no anti-snipe surcharge, normal 1% fee) -> this adapter.
///         The adapter is its own router and swap caller: inside one PoolManager unlock it runs optional
///         exact-in hops from the funding currency to the launch's quote (e.g. ETH -> USDC on a v4 pool), then
///         one exact-in swap quote -> launch token on the launch pool, settles the funding and sends the
///         tokens straight to the creator. The hook checks that the creator received exactly `amountOut`.
/// @dev    `routeData` = abi.encode(PoolKey[] hops): the pools before the launch pool, in order (empty when the
///         funding currency is the quote). ERC-20 funding is pulled from the creator, who approves this adapter.
///         Only the hook can call `executeLaunchBuy`, and the hook only acts for the factory with
///         `originalCreator` = the launch's creator, so nobody can spend another account's allowance.
contract PlaceLaunchBuyAdapter is ILaunchBuyAdapter, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_HOPS = 2;

    address public immutable factory;
    address public immutable launchHook;
    address public immutable poolManager;

    struct Callback {
        LaunchBuyRequest request;
        PoolKey[] hops;
    }

    error NotHook();
    error NotPoolManager();
    error Expired(uint64 deadline);
    error InvalidRoute();
    error WrongValue();
    error PartialFill();

    constructor(address factory_, address launchHook_, address poolManager_) {
        if (factory_.code.length == 0 || launchHook_.code.length == 0 || poolManager_.code.length == 0) {
            revert InvalidRoute();
        }
        factory = factory_;
        launchHook = launchHook_;
        poolManager = poolManager_;
    }

    function router() external view returns (address) {
        return address(this);
    }

    function swapCaller() external view returns (address) {
        return address(this);
    }

    receive() external payable {
        if (msg.sender != poolManager) revert WrongValue();
    }

    function executeLaunchBuy(LaunchBuyRequest calldata request) external payable returns (uint256 amountOut) {
        if (msg.sender != launchHook) revert NotHook();
        // forge-lint: disable-next-line(block-timestamp) user-supplied transaction expiry
        if (block.timestamp > request.deadline) revert Expired(request.deadline);
        PoolKey[] memory hops = abi.decode(request.routeData, (PoolKey[]));
        _validateRoute(request, hops);
        if (request.fundingToken == address(0)) {
            if (msg.value != request.amountIn) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
            IERC20(request.fundingToken).safeTransferFrom(request.originalCreator, address(this), request.amountIn);
        }
        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(Callback(request, hops)));
        uint256 spent;
        (spent, amountOut) = abi.decode(result, (uint256, uint256));
        // Return any funding a hop did not use (only possible with hooks that take less input).
        uint256 refund = request.amountIn - spent;
        if (refund != 0) _pay(request.fundingToken, request.originalCreator, refund);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert NotPoolManager();
        Callback memory cb = abi.decode(data, (Callback));
        IPoolManager manager = IPoolManager(poolManager);
        LaunchBuyRequest memory request = cb.request;

        address currencyIn = request.fundingToken;
        uint256 amount = request.amountIn;
        uint256 spent;
        for (uint256 i = 0; i <= cb.hops.length; i++) {
            PoolKey memory key = i < cb.hops.length ? cb.hops[i] : request.poolKey;
            bool zeroForOne = Currency.unwrap(key.currency0) == currencyIn;
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
            // forge-lint: disable-next-line(unsafe-typecast) exact-in: inDelta <= 0
            uint256 paidIn = uint256(uint128(-inDelta));
            if (i == 0) spent = paidIn;
            else if (paidIn != amount) revert PartialFill(); // intermediate currencies must net to zero
            if (outDelta <= 0) revert PartialFill();
            // forge-lint: disable-next-line(unsafe-typecast) checked > 0
            amount = uint256(uint128(outDelta));
            currencyIn = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        }
        // Settle the funding currency, deliver the launch token to the creator.
        if (request.fundingToken == address(0)) {
            manager.settle{value: spent}();
        } else {
            manager.sync(Currency.wrap(request.fundingToken));
            IERC20(request.fundingToken).safeTransfer(poolManager, spent);
            manager.settle();
        }
        manager.take(Currency.wrap(request.launchToken), request.originalCreator, amount);
        return abi.encode(spent, amount);
    }

    /// @dev The hops must chain fundingToken -> ... -> quoteToken, and the last pool must be the launch pool.
    function _validateRoute(LaunchBuyRequest calldata request, PoolKey[] memory hops) internal pure {
        if (hops.length > MAX_HOPS) revert InvalidRoute();
        address currency = request.fundingToken;
        for (uint256 i = 0; i < hops.length; i++) {
            address c0 = Currency.unwrap(hops[i].currency0);
            address c1 = Currency.unwrap(hops[i].currency1);
            if (currency == c0) currency = c1;
            else if (currency == c1) currency = c0;
            else revert InvalidRoute();
            if (currency == request.launchToken) revert InvalidRoute();
        }
        if (currency != request.quoteToken) revert InvalidRoute();
        address p0 = Currency.unwrap(request.poolKey.currency0);
        address p1 = Currency.unwrap(request.poolKey.currency1);
        if (!((p0 == request.quoteToken && p1 == request.launchToken)
                    || (p1 == request.quoteToken && p0 == request.launchToken))) revert InvalidRoute();
    }

    function _pay(address currency, address to, uint256 amount) internal {
        if (currency == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert WrongValue();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }
}
