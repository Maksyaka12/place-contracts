// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Place Launch L0: B20 precompile and Uniswap v4 checks. Fork-only (the B20 feature is not
// activated in a plain local EVM):
//   forge test --match-path test/fork/B20Fork.t.sol \
//     --fork-url https://base-sepolia-rpc.publicnode.com --hardfork base:Cobalt -vv

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

interface IB20Factory {
    struct B20AssetCreateParams {
        uint8 version;
        string name;
        string symbol;
        address initialAdmin;
        uint8 decimals;
    }

    function createB20(uint8 variant, bytes32 salt, bytes calldata params, bytes[] calldata initCalls)
        external
        payable
        returns (address token);
    function getB20Address(uint8 variant, address sender, bytes32 salt) external view returns (address);
    function isB20(address token) external view returns (bool);
}

interface IB20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function updateName(string calldata) external;
    function updateSymbol(string calldata) external;
    function mint(address, uint256) external;
    function burn(uint256) external;
    function updateSupplyCap(uint256) external;
    function hasRole(bytes32, address) external view returns (bool);
    function grantRole(bytes32, address) external;
    function renounceLastAdmin() external;
    function METADATA_ROLE() external view returns (bytes32);
    function BURN_ROLE() external view returns (bytes32);
    function MINT_ROLE() external view returns (bytes32);
}

contract B20ForkTest is Test, IUnlockCallback {
    using CurrencySettler for Currency;

    IB20Factory constant FACTORY = IB20Factory(0xB20f000000000000000000000000000000000000);
    IPoolManager constant PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408); // Base Sepolia v4
    uint256 constant SUPPLY = 1_000_000_000e18;
    bytes32 constant METADATA_ROLE = 0x6bd6b5318a46e5fff572d5e4258a20774aab40cc35ac7680654b9081fcc82f80;
    address constant META = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function _initCalls(address recipient) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](3);
        calls[0] = abi.encodeCall(IB20.updateSupplyCap, (SUPPLY));
        calls[1] = abi.encodeCall(IB20.mint, (recipient, SUPPLY));
        calls[2] = abi.encodeCall(IB20.grantRole, (METADATA_ROLE, META));
    }

    function _create(address admin, bytes32 salt, address recipient) internal returns (IB20 token) {
        bytes memory params = abi.encode(IB20Factory.B20AssetCreateParams(1, "Place Test", "PLT", admin, 18));
        address predicted = FACTORY.getB20Address(0, address(this), salt);
        token = IB20(FACTORY.createB20(0, salt, params, _initCalls(recipient)));
        assertEq(address(token), predicted, "address = getB20Address");
        assertTrue(FACTORY.isB20(address(token)));
        console.log("token", address(token));
    }

    function test_fixedSupply_withRenounce() public {
        IB20 t = _create(address(this), keccak256("a"), address(this));
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.supplyCap(), SUPPLY);
        assertEq(t.balanceOf(address(this)), SUPPLY);
        assertTrue(t.hasRole(bytes32(0), address(this)));
        t.renounceLastAdmin();
        assertFalse(t.hasRole(bytes32(0), address(this)));
        // no admin: cannot grant, mint or raise the cap
        bytes32 mintRole = t.MINT_ROLE();
        vm.expectRevert();
        t.grantRole(mintRole, address(this));
        vm.expectRevert();
        t.mint(address(this), 1);
        vm.expectRevert();
        t.updateSupplyCap(SUPPLY * 2);
        // metadata role survives the renounce
        vm.prank(META);
        t.updateName("Renamed");
        assertEq(t.name(), "Renamed");
        vm.prank(META);
        t.updateSymbol("NEW"); // METADATA_ROLE also gates the symbol: Place must not expose it
        vm.expectRevert();
        t.updateName("nope");
        // transfers, approve, transferFrom
        t.transfer(BOB, 100e18);
        vm.prank(BOB);
        t.approve(address(this), 40e18);
        t.transferFrom(BOB, address(0xdead), 40e18);
        assertEq(t.balanceOf(address(0xdead)), 40e18);
        assertEq(t.allowance(BOB, address(this)), 0);
        // burn needs BURN_ROLE, even for one's own balance
        vm.expectRevert();
        t.burn(1e18);
        // Denim rejects transfers to the token itself; Cobalt still accepts them
        (bool ok,) = address(t).call(abi.encodeCall(IB20.transfer, (address(t), 1)));
        console.log("transfer to token itself accepted:", ok);
    }

    function test_adminless_atCreation() public {
        IB20 t = _create(address(0), keccak256("b"), address(this));
        assertEq(t.totalSupply(), SUPPLY);
        assertFalse(t.hasRole(bytes32(0), address(this)));
        assertTrue(t.hasRole(METADATA_ROLE, META));
        vm.expectRevert();
        t.grantRole(METADATA_ROLE, BOB);
    }

    function test_burnRole_grantedAtCreation() public {
        bytes memory params = abi.encode(IB20Factory.B20AssetCreateParams(1, "Burn Test", "BRN", address(0), 18));
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IB20.updateSupplyCap, (SUPPLY));
        calls[1] = abi.encodeCall(IB20.mint, (address(this), SUPPLY));
        calls[2] = abi.encodeCall(IB20.grantRole, (keccak256("BURN_ROLE"), address(this)));
        IB20 t = IB20(FACTORY.createB20(0, keccak256("c"), params, calls));
        t.burn(1e18);
        assertEq(t.totalSupply(), SUPPLY - 1e18);
    }

    // ---- Uniswap v4: single-sided token-only position + swaps both ways ----

    enum Action {
        ADD,
        SWAP
    }

    PoolKey internal key;

    function test_v4Pool_singleSided_andSwaps() public {
        IB20 t = _create(address(0), keccak256("d"), address(this));
        require(address(t) > address(0), "sorting");
        // native ETH (address 0) is always currency0, so the B20 token is currency1
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(t)), 10_000, 200, IHooks(address(0)));
        PM.initialize(key, TickMath.getSqrtPriceAtTick(0));
        // token1-only liquidity lies below the current tick
        PM.unlock(abi.encode(Action.ADD, int24(-200_000), int24(0), int256(1e24)));
        uint256 seeded = SUPPLY - t.balanceOf(address(this));
        console.log("seeded tokens", seeded);
        assertGt(seeded, 0);

        vm.deal(address(this), 1 ether);
        uint256 before = t.balanceOf(address(this));
        PM.unlock(abi.encode(Action.SWAP, true, -int256(0.01 ether), uint256(0)));
        uint256 bought = t.balanceOf(address(this)) - before;
        console.log("bought", bought);
        assertGt(bought, 0);

        uint256 ethBefore = address(this).balance;
        PM.unlock(abi.encode(Action.SWAP, false, -int256(bought / 2), uint256(0)));
        assertGt(address(this).balance, ethBefore);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        Action a = abi.decode(data[:32], (Action));
        if (a == Action.ADD) {
            (, int24 lo, int24 hi, int256 liq) = abi.decode(data, (Action, int24, int24, int256));
            (BalanceDelta d,) = PM.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(lo, hi, liq, 0), "");
            require(d.amount0() == 0, "not single sided");
            key.currency1.settle(PM, address(this), uint256(uint128(-d.amount1())), false);
        } else {
            (, bool zeroForOne, int256 amount,) = abi.decode(data, (Action, bool, int256, uint256));
            BalanceDelta d = PM.swap(
                key,
                IPoolManager.SwapParams(
                    zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
            if (zeroForOne) {
                key.currency0.settle(PM, address(this), uint256(uint128(-d.amount0())), false);
                key.currency1.take(PM, address(this), uint256(uint128(d.amount1())), false);
            } else {
                key.currency1.settle(PM, address(this), uint256(uint128(-d.amount1())), false);
                key.currency0.take(PM, address(this), uint256(uint128(d.amount0())), false);
            }
        }
        return "";
    }

    receive() external payable {}
}
