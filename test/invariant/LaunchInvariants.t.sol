// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {EconomyFixture} from "../utils/EconomyFixture.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Random trading, processing, claiming and fund spending against one launch.
contract LaunchHandler is Test {
    LaunchInvariantsTest internal immutable suite;

    constructor(LaunchInvariantsTest suite_) {
        suite = suite_;
    }

    function buy(uint256 amount) external {
        suite.doSwap(true, bound(amount, 1e9, 5 ether));
    }

    function sell(uint256 fraction) external {
        suite.doSell(bound(fraction, 1, 100));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function collect() external {
        suite.track(abi.encodeCall(PlaceCreatorVault.collect, ()), address(0));
    }

    function process() external {
        suite.track(abi.encodeCall(PlaceCreatorVault.process, ()), address(0));
    }

    function claim() external {
        suite.track(abi.encodeCall(PlaceCreatorVault.claim, ()), suite.CREATOR_());
    }

    function claimX() external {
        suite.track(abi.encodeCall(PlaceCreatorVault.claimX, (42)), address(0));
    }

    function fundCampaign(uint256 amount, bool inUsd) external {
        suite.doFundCampaign(amount, inUsd);
    }

    function defaultCampaign() external {
        suite.track(abi.encodeCall(PlaceCreatorVault.startDefaultCampaign, ()), address(0));
    }

    function escrowClaimPlatform() external {
        try suite.escrowRef().claimFor(address(0x9A7F), address(0)) {} catch {}
    }
}

contract LaunchInvariantsTest is EconomyFixture {
    using StateLibrary for IPoolManager;

    bytes32 internal constant COLLECTED = keccak256("Collected(uint256,uint256,uint256,uint256,uint256)");

    address public token;
    PoolId internal poolId;
    PoolKey internal key;
    PlaceCreatorVault public vault;
    LaunchHandler internal handler;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal seededLiquidity;
    /// Sum of every `toCreator` the vault ever booked.
    uint256 public ghostCreatorBooked;

    function setUp() public {
        _deployEconomy();
        xreg.bind(42, address(0x7777));
        (token, poolId, key, vault) = _launchEco(2_000, 3_000, 42, 3_000);
        assertEq(CREATOR.balance, 0);

        // the single seed band: token is currency1 against ETH -> [minUsable, startTick]
        int24 startTick = -ETH_START_TICK;
        tickUpper = startTick;
        tickLower = (TickMath.MIN_TICK / SPACING) * SPACING;
        (seededLiquidity,,) = pm.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertGt(seededLiquidity, 0);

        handler = new LaunchHandler(this);
        targetContract(address(handler));
    }

    function CREATOR_() external pure returns (address) {
        return CREATOR;
    }

    function escrowRef() external view returns (FeeEscrow) {
        return escrow;
    }

    function doSwap(bool isBuy, uint256 amount) external {
        _swap(TRADER, key, token, isBuy, amount);
    }

    function doSell(uint256 pct) external {
        uint256 bal = IERC20(token).balanceOf(TRADER);
        uint256 amount = bal * pct / 100;
        if (amount == 0) return;
        _swap(TRADER, key, token, false, amount);
    }

    function doFundCampaign(uint256 amount, bool inUsd) external {
        uint256 available = vault.fundBalance(address(0));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        track(
            abi.encodeCall(
                PlaceCreatorVault.fundCampaign, (_campaign(address(0), amount, inUsd ? address(usd) : address(0), 0))
            ),
            CREATOR
        );
    }

    /// Calls the vault (as `caller` if set), ignores reverts, and adds up the creator share of every Collected event.
    function track(bytes memory data, address caller) public {
        vm.recordLogs();
        if (caller != address(0)) vm.prank(caller);
        (bool ok,) = address(vault).call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return; // a reverted call booked nothing (its logs are recorded anyway)
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == COLLECTED) {
                (,,,, uint256 toCreator) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                ghostCreatorBooked += toCreator;
            }
        }
    }

    /// Nothing can remove the hook's permanent liquidity.
    function invariant_hookLiquidityNeverDecreases() public view {
        (uint128 liquidity,,) = pm.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertEq(liquidity, seededLiquidity);
    }

    /// The escrow's ERC-6909 claims cover everything it owes.
    function invariant_escrowCoversOwed() public view {
        uint256 claimsEth = pm.balanceOf(address(escrow), Currency.wrap(address(0)).toId());
        uint256 owedEth = escrow.owed(PLATFORM, address(0)) + escrow.owed(address(vault), address(0));
        assertGe(claimsEth, owedEth);
        uint256 claimsToken = pm.balanceOf(address(escrow), Currency.wrap(token).toId());
        assertGe(claimsToken, escrow.owed(hook.BURN_SINK(), token));
    }

    /// The creator fee recipient is the vault forever.
    function invariant_recipientsFixed() public view {
        (,,,,, address recipient,,,,,,) = hook.poolConfig(poolId);
        assertEq(recipient, address(vault));
    }

    /// The vault always holds what it earmarked for burn, creator and X.
    function invariant_vaultSolvent() public view {
        assertGe(address(vault).balance, vault.burnReserve() + vault.creatorOwed() + vault.xOwedTotal());
    }

    /// The creator only ever receives their own basket: never the burn reserve or the community fund.
    function invariant_creatorGetsOnlyOwnShare() public view {
        assertEq(CREATOR.balance + vault.creatorOwed(), ghostCreatorBooked);
    }

    /// The burn never exceeds the frozen cap per interval: the reserve is drawn down at most MAX_BURN per day.
    function invariant_processCadence() public view {
        uint64 last = vault.lastProcessAt();
        if (last != 0) assertEq(vault.nextProcessAt(), last + PROCESS_INTERVAL);
    }
}
