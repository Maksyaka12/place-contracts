// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCreatorVault} from "../../src/place/PlaceCreatorVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiveHub {
    function campaignCount() external view returns (uint256);
    function statusOf(uint256 id) external view returns (uint8);
}

/// @notice A B20 launch's vault funds a holders campaign in the real PlaceHub v1.0.0 on Base Sepolia.
contract VaultHubForkTest is LaunchFixture {
    IPoolManager internal constant SEPOLIA_PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address internal constant HUB = 0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://base-sepolia-rpc.publicnode.com")));
        _deploySuite(SEPOLIA_PM);
        factory.setVaultSettings(
            PlaceLaunchFactoryCore.VaultSettings({
                hub: HUB,
                xRegistry: address(0),
                campaignInterval: 7 days,
                rulesHash: keccak256("place-launch-holders-v1"),
                rulesURI: "ipfs://place-launch-holders-v1"
            })
        );
        factory.setRewardsMinimum(address(0), 0.001 ether);
    }

    function test_b20_rewardsCampaign_inRealHub() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.B20, address(0));
        p.economics.rewardsBps = 5_000;
        p.economics.buybackBps = 2_000;
        p.economics.buybackBurn = true;
        (address token,) = _launch(p);
        PlaceCreatorVault vault = _vault(token);
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(block.timestamp + 21);
        _swap(TRADER, key, token, true, 1 ether); // 0.0075 ETH to the vault, 0.00375 for rewards

        uint256 before = ILiveHub(HUB).campaignCount();
        uint256 id = vault.startRewardsCampaign();
        assertEq(id, before);
        assertEq(ILiveHub(HUB).campaignCount(), before + 1);
        assertEq(ILiveHub(HUB).statusOf(id), 1, "Scheduled");
        assertLe(vault.rewardsAvailable(), 1, "pool + hub fee paid out of the rewards");
        assertGt(HUB.balance, 0);

        // the creator still claims, with the buyback burned in the same pool
        vm.prank(CREATOR);
        (uint256 paid, uint256 bought) = vault.claim(1);
        assertGt(paid, 0);
        assertGt(bought, 0);
        assertGe(IERC20(token).balanceOf(address(0xdEaD)), bought);
    }
}
