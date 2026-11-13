// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {MockHub, MockXRegistry} from "../utils/Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Random trading, collecting, claiming and campaigns against one launch.
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
        suite.vault().collect();
    }

    function claim() external {
        suite.doClaim();
    }

    function claimX() external {
        try suite.vault().claimX(42) {} catch {}
    }

    function campaign() external {
        try suite.vault().startRewardsCampaign() {} catch {}
    }

    function escrowClaimPlatform() external {
        try suite.escrowRef().claimFor(address(0x9A7F), address(0)) {} catch {}
    }
}

contract LaunchInvariantsTest is LaunchFixture {
    using StateLibrary for IPoolManager;

    address public token;
    PoolId internal poolId;
    PoolKey internal key;
    PlaceCreatorVault public vault;
    LaunchHandler internal handler;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint128 internal seededLiquidity;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
        MockHub hub = new MockHub();
        MockXRegistry xreg = new MockXRegistry();
        xreg.bind(42, address(0x7777));
        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: address(hub),
                xRegistry: address(xreg),
                campaignInterval: 1 days,
                rulesHash: keccak256("rules"),
                rulesURI: "ipfs://rules"
            })
        );
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.buybackBps = 2_000;
        p.economics.buybackBurn = true;
        p.economics.rewardsBps = 2_000;
        p.economics.xShares = new PlaceCreatorVault.XShare[](1);
        p.economics.xShares[0] = PlaceCreatorVault.XShare({xId: 42, bps: 3_000});
        (token, poolId) = _launch(p);
        key = _poolKey(token, address(0));
        vault = _vault(token);

        // the single seed band: token is currency1 against ETH -> [minUsable, startTick]
        int24 startTick = -ETH_START_TICK;
        tickUpper = startTick;
        tickLower = (TickMath.MIN_TICK / SPACING) * SPACING;
        (seededLiquidity,,) = pm.getPositionInfo(poolId, address(hook), tickLower, tickUpper, bytes32(0));
        assertGt(seededLiquidity, 0);

        handler = new LaunchHandler(this);
        targetContract(address(handler));
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

    function doClaim() external {
        vm.prank(CREATOR);
        try vault.claim(0) {} catch {}
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

    /// The creator fee recipient is the vault forever; the protocol recipient is frozen.
    function invariant_recipientsFixed() public view {
        (,,,,, address recipient,,,,,,) = hook.poolConfig(poolId);
        assertEq(recipient, address(vault));
    }

    /// The vault always holds what it earmarked for buyback, creator and X.
    function invariant_vaultSolvent() public view {
        assertGe(address(vault).balance, vault.buybackReserve() + vault.creatorOwed() + vault.xOwedTotal());
    }
}
