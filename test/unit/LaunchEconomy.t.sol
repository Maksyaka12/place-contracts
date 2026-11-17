// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFixture} from "../utils/LaunchFixture.sol";
import {PlaceLaunchFactoryCore} from "../../src/launch/PlaceLaunchFactoryCore.sol";
import {PlaceLaunchHook} from "../../src/launch/PlaceLaunchHook.sol";
import {PlaceFeeMath} from "../../src/launch/PlaceFeeMath.sol";
import {PlaceRewardsDistributor} from "../../src/place/PlaceRewardsDistributor.sol";
import {IPlaceRewardsDistributor} from "../../src/place/interfaces/IPlaceRewardsDistributor.sol";
import {FeeEscrow} from "../../src/FeeEscrow.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LaunchEconomyTest is LaunchFixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        _deploySuite(IPoolManager(address(0)));
    }

    function _even(address reward) internal view returns (PlaceLaunchFactoryCore.LaunchParams memory) {
        return
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 5, [uint32(20), 20, 20, 20, 20], reward
            );
    }

    function _expectLaunchRevert(PlaceLaunchFactoryCore.LaunchParams memory p, bytes memory reason) internal {
        _mineSalt(p, CREATOR);
        uint256 fee = factory.nativeLaunchFee();
        vm.deal(CREATOR, fee);
        vm.expectRevert(reason);
        vm.prank(CREATOR);
        factory.createLaunch{value: fee}(p);
    }

    function _sel(bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(selector);
    }

    // ───────────── fee split ─────────────

    function test_economy_buy3pct_fiveBaskets() public {
        (address token,) = _launch(_even(address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether);
        // 3% tax: 0.9% platform; the 2.1% remainder in five equal baskets, burn charged in the token
        assertEq(escrow.owed(PLATFORM, address(0)), 0.009 ether, "platform 30% of the tax");
        assertEq(escrow.owed(address(_vault(token)), address(0)), 0.0042 ether, "creator");
        assertEq(escrow.accountOwed(address(distributor), _holdersId(token), address(0)), 0.0042 ether, "holders");
        assertEq(escrow.accountOwed(address(distributor), _tradersId(token), address(0)), 0.0042 ether, "traders");
        assertEq(escrow.owed(address(_community(token)), address(0)), 0.0042 ether, "community");
        assertGt(escrow.pendingBurn(token), 0, "burn basket in the token");
    }

    function test_economy_sell5pct_protocolIs30pct() public {
        (address token,) = _launch(_even(address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether);
        uint256 platformBefore = escrow.owed(PLATFORM, address(0));
        uint256 creatorBefore = escrow.owed(address(_vault(token)), address(0));
        uint256 burnBefore = escrow.pendingBurn(token);
        _swap(TRADER, key, token, false, IERC20(token).balanceOf(TRADER));
        uint256 platform = escrow.owed(PLATFORM, address(0)) - platformBefore;
        uint256 creator = escrow.owed(address(_vault(token)), address(0)) - creatorBefore;
        // 5%: platform 1.5%, each basket 0.7%
        assertApproxEqRel(platform * 7, creator * 15, 1e12, "1.5 : 0.7");
        assertGt(escrow.pendingBurn(token), burnBefore, "sell burn in the token too");
    }

    function test_burn_anyoneSendsToDead() public {
        (address token,) = _launch(_even(address(0)));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether);
        uint256 pending = escrow.pendingBurn(token);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FeeEscrow.TokensBurned(token, address(0xB0B), pending);
        vm.prank(address(0xB0B));
        assertEq(escrow.burn(token), pending);
        assertEq(IERC20(token).balanceOf(DEAD), pending, "at 0x...dEaD");
        assertEq(escrow.pendingBurn(token), 0);
        vm.expectRevert(FeeEscrow.NothingToClaim.selector);
        escrow.burn(token);
    }

    function test_standard_hasNoBaskets() public {
        (address token,) = _launch(_params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0)));
        (PlaceLaunchFactoryCore.LaunchType launchType, address community) = factory.launchRecord(token);
        assertEq(uint8(launchType), uint8(PlaceLaunchFactoryCore.LaunchType.Standard));
        assertEq(community, address(0));
        PoolKey memory key = _poolKey(token, address(0));
        vm.warp(vm.getBlockTimestamp() + 21);
        _swap(TRADER, key, token, true, 1 ether);
        assertEq(escrow.pendingBurn(token), 0);
        assertEq(escrow.owed(address(_vault(token)), address(0)), 0.007 ether);
        assertFalse(distributor.closable(_holdersId(token)));
    }

    function test_economy_onlySomeBaskets_wiresOnlyThose() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _economyParams(
            PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 2, 2, [uint32(50), 0, 0, 50, 0], address(0)
        );
        (address token, PoolId poolId) = _launch(p);
        (,,,,,,,,,, address rewardsDistributor, address communityVault,) = hook.poolConfig(poolId);
        assertEq(rewardsDistributor, address(0));
        assertEq(communityVault, address(0));
        assertEq(distributor.stream(_holdersId(token)).token, address(0), "no streams");
    }

    function test_economy_registersStreams() public {
        (address token,) = _launch(_even(address(usd)));
        PlaceRewardsDistributor.Stream memory h = distributor.stream(_holdersId(token));
        PlaceRewardsDistributor.Stream memory t = distributor.stream(_tradersId(token));
        assertEq(h.token, token);
        assertTrue(h.economy);
        assertEq(h.rewardToken, address(usd));
        assertEq(h.source, address(0));
        assertEq(h.criterion, 100_000e18, "min holding");
        assertEq(t.criterion, 0.01 ether, "min daily volume");
        assertEq(h.startEpoch, distributor.currentEpoch());
    }

    function test_antiSnipe_canBeDisabled() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _even(address(0));
        p.antiSnipeEnabled = false;
        (address token,) = _launch(p);
        _swap(TRADER, _poolKey(token, address(0)), token, true, 1 ether); // launch block, no surcharge
        assertEq(escrow.owed(PLATFORM, address(0)), 0.009 ether);
    }

    function test_antiSnipe_surchargeToPlatform() public {
        (address token,) = _launch(_even(address(0)));
        _swap(TRADER, _poolKey(token, address(0)), token, true, 1 ether); // launch block: 99%
        assertApproxEqAbs(escrow.owed(address(_vault(token)), address(0)), 0.0042 ether, 2, "baskets keep the tax");
        assertGt(escrow.owed(PLATFORM, address(0)), 0.9 ether, "surcharge to the platform");
    }

    function test_preview() public view {
        PlaceFeeMath.TaxConfigurationPreview memory preview =
            factory.previewTaxConfiguration(_even(address(0)).economics);
        uint256 rateScale = 1e24;
        assertEq(preview.buyRates.protocolRate, rateScale * 9 / 1000, "0.9%");
        assertEq(preview.sellRates.protocolRate, rateScale * 15 / 1000, "1.5%");
        assertEq(preview.buyRates.burnRate, rateScale * 42 / 10_000, "0.42% burn");
    }

    // ───────────── validation ─────────────

    function test_standard_rejectsEconomyFields() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.buyTaxRate = 2_000_000;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        p = _params(PlaceLaunchFactoryCore.TokenKind.ERC20, address(0));
        p.economics.allocation.burn = SCALE;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
    }

    function test_economy_taxBounds() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _even(address(0));
        p.economics.buyTaxRate = 5_000_001;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidTaxConfiguration.selector));
        p = _even(address(0));
        p.economics.sellTaxRate = 999_999;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidTaxConfiguration.selector));
    }

    function test_economy_basketsMustSum100() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _even(address(0));
        p.economics.allocation.community -= 1;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidTaxConfiguration.selector));
    }

    function test_economy_minHoldingBounds() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _even(address(0));
        p.economics.minHolding = 9_999e18;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        p.economics.minHolding = SUPPLY + 1;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        p = _economyParams(
            PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 3, [uint32(50), 0, 50, 0, 0], address(0)
        );
        p.economics.minHolding = 10_000e18; // set without a holders basket
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        p.economics.minHolding = SUPPLY; // the whole supply is the upper bound
        p.economics.allocation.holders = 10_000_000;
        p.economics.allocation.creator = 40_000_000;
        _launch(p);
    }

    function test_economy_rewardTokenMustBeListed() public {
        address unlisted = address(new FeeEscrow(pm, address(hook))); // any contract
        _expectLaunchRevert(
            _even(unlisted),
            abi.encodeWithSelector(PlaceRewardsDistributor.RouteNotListed.selector, address(0), unlisted)
        );
    }

    function test_economy_rewardInOwnToken() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _even(address(0));
        _mineSalt(p, CREATOR);
        address predicted = factory.predictLaunchToken(p, CREATOR);
        p.economics.rewardToken = predicted;
        (address token,) = _launch(p);
        assertEq(token, predicted);
        assertEq(distributor.stream(_holdersId(token)).rewardToken, token);
    }

    function test_economy_rewardFieldsWithoutRewardBaskets_revert() public {
        PlaceLaunchFactoryCore.LaunchParams memory p = _economyParams(
            PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 3, [uint32(50), 0, 0, 50, 0], address(0)
        );
        p.economics.rewardToken = address(usd);
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        p.economics.rewardToken = address(0);
        p.economics.minTraderDailyVolume = 1;
        _expectLaunchRevert(p, _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
    }

    function test_economy_needsDistributor() public {
        factory.setEconomySettings(
            PlaceLaunchFactoryCore.EconomySettings({
                xRegistry: address(xreg),
                staking: address(staking),
                rewardRegistry: address(rewards),
                rewardsDistributor: address(0),
                defaultCampaignDelay: DEFAULT_DELAY,
                defaultCampaignEpochs: DEFAULT_EPOCHS
            })
        );
        _expectLaunchRevert(_even(address(0)), _sel(PlaceLaunchFactoryCore.InvalidEconomics.selector));
        // burn + creator only still works without a distributor
        _launch(
            _economyParams(
                PlaceLaunchFactoryCore.TokenKind.ERC20, address(0), 3, 3, [uint32(50), 0, 0, 50, 0], address(0)
            )
        );
    }

    function test_settings_distributorMustBeBound() public {
        PlaceRewardsDistributor other =
            new PlaceRewardsDistributor(address(factory), address(this), PUBLISHER, 0, PLATFORM);
        PlaceLaunchFactoryCore.EconomySettings memory s = factory.economySettings();
        s.rewardsDistributor = address(other);
        factory.setEconomySettings(s); // bound to this factory: fine
        s.rewardsDistributor = address(rewards); // a contract without factory()
        vm.expectRevert();
        factory.setEconomySettings(s);
    }

    function test_onlyFactoryRegistersStreams() public {
        IPlaceRewardsDistributor.LaunchStreams memory s;
        vm.expectRevert(PlaceRewardsDistributor.NotFactory.selector);
        distributor.registerLaunch(s);
    }

    function test_economics_frozen_noSetters() public {
        (address token, PoolId poolId) = _launch(_even(address(0)));
        (,,,,,,,,,,,, PlaceFeeMath.TaxConfiguration memory tax) = hook.poolConfig(poolId);
        assertEq(tax.buyTaxRate, 3_000_000);
        assertEq(tax.sellTaxRate, 5_000_000);
        assertEq(PlaceFeeMath.shareSum(tax), SCALE);
        (bool ok,) =
            address(factory).call(abi.encodeWithSignature("setTaxConfiguration(address,uint32,uint32)", token, 1, 1));
        assertFalse(ok);
        (ok,) = address(_vault(token)).call(abi.encodeWithSignature("increaseEconomics(uint16,uint16)", 1, 1));
        assertFalse(ok, "no basket changes after launch");
    }

    function test_tradeEvent_carriesTraderAndVolume() public {
        (address token, PoolId poolId) = _launch(_even(address(0)));
        vm.warp(vm.getBlockTimestamp() + 21);
        vm.expectEmit(true, true, true, false, address(hook));
        emit PlaceLaunchHook.Trade(poolId, address(router), TRADER, true, address(0), 0, 0, bytes32(0));
        _swap(TRADER, _poolKey(token, address(0)), token, true, 1 ether);
    }
}
