// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {MerkleHelper} from "../utils/Mocks.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceCommunityVault} from "../../src/place/PlaceCommunityVault.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {IB20Factory} from "../../src/launch/interfaces/IB20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Economy launch of a B20 token through the real Base Sepolia PoolManager and B20 precompile (fork):
///         five baskets, burn to 0x…dEaD, a daily epoch with the reward swapped into another token, a Merkle claim,
///         and a community pool campaign.
contract EconomyB20ForkTest is LaunchFixture {
    IPoolManager internal constant SEPOLIA_PM = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    IB20Factory internal constant B20F = IB20Factory(0xB20f000000000000000000000000000000000000);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant HOLDER = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://base-sepolia-rpc.publicnode.com")));
        _deploySuite(SEPOLIA_PM);
    }

    function test_b20_economy_endToEnd() public {
        (address token,) = _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.B20, address(0), 4, 4, [uint32(20), 20, 20, 20, 20], address(usd)
            )
        );
        assertTrue(B20F.isB20(token));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 0.5 ether);
        _swap(TRADER, key, token, false, IERC20(token).balanceOf(TRADER) / 2);

        // 4%: 1.2% platform, 0.56% to each basket
        assertEq(escrow.accountOwed(address(distributor), _holdersId(token), address(0)) > 0, true);
        assertGt(escrow.owed(address(_community(token)), address(0)), 0);

        // burn: the B20 basket goes to 0x…dEaD
        uint256 burnable = escrow.pendingBurn(token);
        assertGt(burnable, 0);
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        escrow.burn(token);
        assertEq(IERC20(token).balanceOf(DEAD) - deadBefore, burnable);

        // next day: the holders basket is swapped into USD and paid against a published root
        _nextDay();
        distributor.closeEpoch(token);
        bytes32 h = _holdersId(token);
        PlaceRewardsDistributor.Stream memory s = distributor.stream(h);
        assertGt(s.funded, 0);
        assertEq(s.pendingInput, 0);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = MerkleHelper.leaf(h, HOLDER, s.funded);
        leaves[1] = MerkleHelper.leaf(h, address(0xB0B), 0);
        (bytes32 root, bytes32[][] memory proofs) = MerkleHelper.build(leaves);
        uint64 day = distributor.currentEpoch() - 1;
        vm.prank(PUBLISHER);
        distributor.publishRoot(PlaceRewardsDistributor.RootUpdate(h, day, root, s.funded, "ipfs://day"));
        distributor.claim(h, HOLDER, s.funded, proofs[0]);
        assertEq(usd.balanceOf(HOLDER), s.funded);

        // community pool: the creator funds a traders campaign in USD
        PlaceCommunityVault vault = _community(token);
        vault.collect();
        uint256 fund = vault.fundBalance(address(0));
        PlaceCommunityVault.CampaignRequest memory r = PlaceCommunityVault.CampaignRequest({
            kind: IPlaceRewardsDistributor.Kind.Traders,
            fundAsset: address(0),
            amountIn: fund,
            rewardToken: address(usd),
            minOut: 1,
            startEpoch: uint64(block.timestamp / 1 days) + 1,
            epochCount: 7,
            criterion: 0.01 ether,
            metadataURI: ""
        });
        vm.prank(CREATOR);
        bytes32 id = vault.fundCampaign(r);
        assertEq(distributor.stream(id).token, token);
        assertEq(vault.fundBalance(address(0)), 0);
        assertGe(usd.balanceOf(address(distributor)), distributor.liabilities(address(usd)));
    }
}
