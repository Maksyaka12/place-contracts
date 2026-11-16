// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "./LaunchFixture.sol";
import {MockHub, MockXRegistry} from "./Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {PlaceRewardTokenRegistry} from "../../src/place/PlaceRewardTokenRegistry.sol";
import {PlaceStaking} from "../../src/staking/PlaceStaking.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice LaunchFixture plus the L5 economy around it: mock hub (5% fee), the real PlaceStaking (5%), the reward
///         token registry with an ETH -> USD route through a plain v4 pool, and frozen vault limits.
abstract contract EconomyFixture is LaunchFixture {
    MockHub internal hub;
    MockXRegistry internal xreg;
    PlaceStaking internal staking;
    PlaceRewardTokenRegistry internal rewards;
    MockERC20 internal usd;
    PoolKey internal ethUsd;
    PoolModifyLiquidityTest internal lp;

    uint64 internal constant PROCESS_INTERVAL = 1 days;
    uint64 internal constant DEFAULT_DELAY = 30 days;
    uint128 internal constant MAX_BURN = 0.001 ether;
    uint128 internal constant DEFAULT_MIN = 0.001 ether;
    uint16 internal constant MAX_IMPACT = 500; // 5% per hop

    receive() external payable {}

    function _deployEconomy() internal {
        _deploySuite(IPoolManager(address(0)));
        hub = new MockHub();
        hub.setFee(500);
        xreg = new MockXRegistry();
        staking = new PlaceStaking(address(this), 500, PLATFORM);
        rewards = new PlaceRewardTokenRegistry(address(this), MAX_IMPACT);

        // A plain v4 ETH/USD pool (no hook), 1 ETH ~ 2000 USD, deep enough for fund swaps.
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

        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: address(hub),
                xRegistry: address(xreg),
                staking: address(staking),
                rewardRegistry: address(rewards),
                processInterval: PROCESS_INTERVAL,
                defaultCampaignDelay: DEFAULT_DELAY,
                rulesHash: keccak256("rules"),
                rulesURI: "ipfs://rules"
            })
        );
        factory.setQuoteLimits(
            address(0),
            PlaceLaunchFactoryCore.QuoteLimits({maxBurnPerProcess: MAX_BURN, defaultCampaignMinimum: DEFAULT_MIN})
        );
    }

    function _launchEco(uint16 burnBps, uint16 communityBps, uint256 xId, uint16 xBps)
        internal
        returns (address token, PoolId poolId, PoolKey memory key, PlaceCreatorVault vault)
    {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.burnBps = burnBps;
        p.economics.communityBps = communityBps;
        if (xBps != 0) {
            p.economics.xShares = new PlaceCreatorVault.XShare[](1);
            p.economics.xShares[0] = PlaceCreatorVault.XShare({xId: xId, bps: xBps});
        }
        (token, poolId) = _launch(p);
        key = _poolKey(token, address(0));
        vault = _vault(token);
        vm.warp(block.timestamp + 21); // past the anti-snipe window
    }

    function _campaign(address fundAsset, uint256 amountIn, address rewardToken, uint256 minOut)
        internal
        pure
        returns (PlaceCreatorVault.CampaignRequest memory r)
    {
        r.fundAsset = fundAsset;
        r.amountIn = amountIn;
        r.rewardToken = rewardToken;
        r.minOut = minOut;
        r.snapshotDelay = 24 hours;
        r.claimDuration = 30 days;
        r.burnLeftover = true;
        r.metadataURI = "ipfs://campaign";
    }
}
