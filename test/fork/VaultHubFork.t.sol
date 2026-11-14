// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {PlaceRewardTokenRegistry} from "../../src/place/PlaceRewardTokenRegistry.sol";
import {PlaceStaking} from "../../src/staking/PlaceStaking.sol";
import {VaultId} from "../../src/staking/interfaces/IO1Staking.sol";
import {IB20Factory} from "../../src/launch/interfaces/IB20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiveHub {
    function campaignCount() external view returns (uint256);
    function statusOf(uint256 id) external view returns (uint8);
}

/// @notice L5 economy on a Base Sepolia fork with the real PlaceHub 1.0.0 (5% fee), the real USDC and a real
///         ETH/USDC v4 pool: a B20 launch burns through process(), funds a hub campaign in USDC (swap in the same
///         transaction) and a PlaceStaking program in its own token, which a holder stakes and claims.
contract VaultHubForkTest is LaunchFixture {
    IPoolManager internal constant SEPOLIA_PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address internal constant HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PlaceStaking internal staking;
    PlaceRewardTokenRegistry internal rewards;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://base-sepolia-rpc.publicnode.com")));
        _deploySuite(SEPOLIA_PM);
        staking = new PlaceStaking(address(this), 500, PLATFORM);
        rewards = new PlaceRewardTokenRegistry(address(this), 500);
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC), 10_000, 200, IHooks(address(0)));
        rewards.setRoute(address(0), USDC, route);
        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: HUB,
                xRegistry: address(0),
                staking: address(staking),
                rewardRegistry: address(rewards),
                processInterval: 1 days,
                defaultCampaignDelay: 30 days,
                rulesHash: keccak256("place-launch-holders-v1"),
                rulesURI: "ipfs://place-launch-holders-v1"
            })
        );
        factory.setQuoteLimits(
            address(0),
            PlaceLaunchFactoryCore.QuoteLimits({maxBurnPerProcess: 0.001 ether, defaultCampaignMinimum: 0.001 ether})
        );
    }

    function test_b20_economy_withRealHubAndPools() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.B20, address(0));
        p.economics.burnBps = 2_500;
        p.economics.communityBps = 5_000;
        (address token,) = _launch(p);
        assertTrue(IB20Factory(0xB20f000000000000000000000000000000000000).isB20(token));
        PlaceCreatorVault vault = _vault(token);
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(block.timestamp + 21);
        _swap(TRADER, key, token, true, 1 ether); // 0.007 ETH to the vault: burn 0.00175, fund 0.0035

        // daily process: anyone, capped, to 0xdead
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        (uint256 collected, uint256 quoteIn, uint256 burned) = vault.process();
        assertEq(collected, 0.007 ether);
        assertEq(quoteIn, 0.001 ether);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, burned);
        vm.expectRevert();
        vault.process();

        // fund -> USDC holders campaign in the real hub, swap through the real ETH/USDC pool
        uint256 before = ILiveHub(HUB).campaignCount();
        PlaceCreatorVault.CampaignRequest memory c;
        c.fundAsset = address(0);
        c.amountIn = 0.00005 ether;
        c.rewardToken = USDC;
        c.minOut = 1;
        c.snapshotDelay = 24 hours;
        c.claimDuration = 30 days;
        c.burnLeftover = true;
        vm.prank(CREATOR);
        uint256 id = vault.fundCampaign(c);
        assertEq(id, before);
        assertEq(ILiveHub(HUB).statusOf(id), 1, "Scheduled");
        assertLe(IERC20(USDC).balanceOf(address(vault)), 1, "pool + 5% fee paid from the swap output");

        // fund -> staking program in the launch's own token (bought in its own pool)
        PlaceCreatorVault.StakingRequest memory s = PlaceCreatorVault.StakingRequest({
            fundAsset: address(0),
            amountIn: 0.002 ether,
            rewardToken: token,
            minOut: 1,
            startTime: uint64(block.timestamp + 1 hours),
            epochDuration: 1 days,
            epochCount: 1,
            earlyExitMode: 0,
            penaltyBps: 0
        });
        vm.prank(CREATOR);
        VaultId vid = VaultId.wrap(vault.fundStaking(s));
        uint256 programTokens = IERC20(token).balanceOf(address(staking));
        assertGt(programTokens, 0);

        // a holder stakes, the epoch ends, the holder claims the epoch's reward in the token
        uint256 bag = IERC20(token).balanceOf(TRADER);
        vm.startPrank(TRADER);
        IERC20(token).approve(address(staking), bag);
        staking.deposit(vid, bag);
        vm.stopPrank();
        vm.warp(s.startTime + 1 days + 1);
        uint64[] memory epochs = new uint64[](1);
        vm.prank(TRADER);
        uint256 reward = staking.claim(vid, epochs, TRADER);
        assertGt(reward, 0);
        assertApproxEqRel(reward, programTokens, 1e15, "sole staker gets the program");
        // 0.0035 - 0.00005 - 0.002, plus 0.7% fees from the vault's own swaps in its pool, booked again
        assertApproxEqAbs(vault.fundBalance(address(0)), 0.00145 ether, 0.00001 ether);
    }
}
