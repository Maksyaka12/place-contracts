// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TaxLaunchOperations} from "./TaxLaunchOperations.sol";
import {ITaxDividendClaimHelper} from "./interfaces/ITaxDividendClaimHelper.sol";
import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";
import {TaxLaunchpadFactoryCore} from "./TaxLaunchpadFactoryCore.sol";
import {TaxLaunchHook} from "./TaxLaunchHook.sol";
import {ITaxLaunchTokenFactory} from "./TaxLaunchTokenDeployer.sol";
import {ITaxDividendFactory, TaxDividendDeployer} from "./TaxDividendDeployer.sol";
import {TaxFeeMath} from "./TaxFeeMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {AnnouncementRegistry} from "../AnnouncementRegistry.sol";
import {ILaunchBuyAdapter} from "../interfaces/ILaunchBuyAdapter.sol";

/// @notice Stateless validation and genesis calculations, with no asset forwarding or recovery functionality.
contract TaxLaunchValidation {
    uint256 private constant BPS = TaxSuiteConstants.BPS;
    int24 private constant TAIL = type(int24).max;
    uint256 private constant MAX_BANDS = TaxSuiteConstants.MAX_BANDS;
    error InvalidConfig();
    error OutOfBounds();
    error MisalignedOffset();
    error AntiSnipeUnavailable();

    struct RecipientContext {
        address factory;
        TaxLaunchHook hook;
        address tokenDeployer;
        address dividendDeployer;
        address dividendImplementation;
        address dividendClaimHelper;
        address announcementRegistry;
        address launchBuyAdapter;
        address launchBuyRouter;
        address launchBuySwapCaller;
        bool checkLaunchRecords;
    }

    function validateFeeRecipient(address recipient, TaxLaunchpadFactoryCore factory) external view {
        _validateRecipient(recipient, _recipientContext(factory, factory.hook()));
    }

    function validateLaunchRecipients(
        TaxLaunchpadFactoryCore factory,
        address creatorFeeRecipient,
        address integratorFeeRecipient,
        address predictedToken,
        bytes32 scopedSalt,
        bool dividendsEnabled
    ) external view {
        RecipientContext memory context = _recipientContext(factory, factory.hook());
        address predictedDividend;
        if (dividendsEnabled) {
            predictedDividend = TaxDividendDeployer(context.dividendDeployer).predictDividendAddress(scopedSalt);
        }
        _validateLaunchRecipient(creatorFeeRecipient, context, predictedToken, predictedDividend);
        if (integratorFeeRecipient != address(0)) {
            _validateLaunchRecipient(integratorFeeRecipient, context, predictedToken, predictedDividend);
        }
        _validateConfiguredRecipients(factory, context, predictedToken, predictedDividend);
    }

    function validateFactoryWiring(TaxLaunchpadFactoryCore factory) external view {
        TaxLaunchHook hook = factory.hook();
        address registry = factory.announcementRegistry();
        address escrow = hook.feeEscrow();
        if (
            registry == address(0) || registry.code.length == 0
                || AnnouncementRegistry(registry).factory() != address(factory) || !hook.wired()
                || hook.factory() != address(factory) || escrow == address(0) || escrow.code.length == 0
        ) revert InvalidConfig();
        RecipientContext memory context = _recipientContext(factory, hook);
        if (ITaxDividendClaimHelper(context.dividendClaimHelper).factory() != address(factory)) revert InvalidConfig();
        _validateConfiguredRecipients(factory, context, address(0), address(0));
    }

    /// @dev Called from the factory constructor, before its getters exist, so bindings are passed explicitly.
    function validateInitialDeploymentRecipients(
        address protocolFeeRecipient,
        address factory,
        TaxLaunchHook hook,
        address tokenDeployer,
        TaxDividendDeployer dividendDeployer
    ) external view {
        RecipientContext memory context = _initialRecipientContext(factory, hook);
        context.tokenDeployer = tokenDeployer;
        context.dividendDeployer = address(dividendDeployer);
        context.dividendImplementation = address(dividendDeployer.implementation());
        context.dividendClaimHelper = dividendDeployer.implementation().claimHelper();
        if (ITaxDividendClaimHelper(context.dividendClaimHelper).hook() != address(hook)) revert InvalidConfig();
        _validateRecipient(protocolFeeRecipient, context);
    }

    function validateLaunchTax(
        TaxFeeMath.TaxConfiguration calldata tax,
        TaxFeeMath.TaxPolicy calldata policy,
        uint256 supply,
        bool antiSnipeEnabled
    ) external pure {
        TaxFeeMath.validateTax(tax, policy, supply);
        if (antiSnipeEnabled && policy.antiSnipeConfiguration.windowSeconds == 0) revert AntiSnipeUnavailable();
    }

    function previewTaxConfiguration(
        TaxFeeMath.TaxConfiguration calldata tax,
        TaxFeeMath.TaxPolicy calldata policy,
        uint256 supply,
        uint64 configVersion
    ) external pure returns (TaxFeeMath.TaxConfigurationPreview memory preview) {
        preview.dividendsEnabled = TaxFeeMath.validateTax(tax, policy, supply);
        preview.configVersion = configVersion;
        preview.minimumDividendHoldingRequirement = policy.minimumDividendHoldingRequirement;
        preview.buyRates = TaxFeeMath.rates(tax.buyTaxRate, policy.protocolFeeConfiguration, tax, 0);
        preview.sellRates = TaxFeeMath.rates(tax.sellTaxRate, policy.protocolFeeConfiguration, tax, 0);
    }

    function resolveSeedPositions(
        TaxLaunchpadFactoryCore.Band[] memory tmpl,
        int24 startTick,
        int24 spacing,
        bool tokenIsCurrency0,
        uint256 supply
    ) external pure returns (TaxLaunchHook.SeedPosition[] memory positions) {
        positions = new TaxLaunchHook.SeedPosition[](tmpl.length);
        // forge-lint: disable-next-line(divide-before-multiply) the truncation IS the alignment
        int24 maxUsable = (TickMath.MAX_TICK / spacing) * spacing;
        // forge-lint: disable-next-line(divide-before-multiply) the truncation IS the alignment
        int24 minUsable = (TickMath.MIN_TICK / spacing) * spacing;

        for (uint256 i = 0; i < tmpl.length; i++) {
            if (tmpl[i].lowerOffset % spacing != 0) revert MisalignedOffset();
            if (tmpl[i].upperOffset != TAIL && tmpl[i].upperOffset % spacing != 0) revert MisalignedOffset();

            int24 tickLower;
            int24 tickUpper;
            if (tokenIsCurrency0) {
                tickLower = startTick + tmpl[i].lowerOffset;
                tickUpper = tmpl[i].upperOffset == TAIL ? maxUsable : startTick + tmpl[i].upperOffset;
            } else {
                tickUpper = startTick - tmpl[i].lowerOffset;
                tickLower = tmpl[i].upperOffset == TAIL ? minUsable : startTick - tmpl[i].upperOffset;
            }
            if (tickLower >= tickUpper) revert OutOfBounds();

            uint256 amount = supply * tmpl[i].supplyShareBps / BPS;
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liquidity = tokenIsCurrency0
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, amount)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, amount);
            if (liquidity == 0 || liquidity >= uint128(type(int128).max)) revert OutOfBounds();

            positions[i] =
                TaxLaunchHook.SeedPosition({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
        }
    }

    function validateBandTemplate(TaxLaunchpadFactoryCore.Band[] memory newBands, int24 spacing) external pure {
        if (newBands.length == 0 || newBands.length > MAX_BANDS) revert OutOfBounds();
        if (newBands[0].lowerOffset != 0) revert InvalidConfig();
        uint256 totalBps;
        for (uint256 i = 0; i < newBands.length; i++) {
            bool isTail = newBands[i].upperOffset == TAIL;
            if (
                newBands[i].lowerOffset < 0 || newBands[i].supplyShareBps == 0 || (isTail && i != newBands.length - 1)
                    || (!isTail && newBands[i].upperOffset <= newBands[i].lowerOffset)
            ) {
                revert InvalidConfig();
            }
            if (newBands[i].lowerOffset % spacing != 0 || (!isTail && newBands[i].upperOffset % spacing != 0)) {
                revert MisalignedOffset();
            }
            totalBps += newBands[i].supplyShareBps;
        }
        if (totalBps != BPS) revert InvalidConfig();
    }

    function validateTaxPolicy(
        TaxFeeMath.TaxPolicy calldata policy,
        uint256 supply,
        address factory,
        TaxLaunchHook hook
    ) external view {
        TaxFeeMath.validatePolicy(policy, supply);
        _validateRecipient(
            policy.protocolFeeConfiguration.protocolFeeRecipient,
            _recipientContext(TaxLaunchpadFactoryCore(factory), hook)
        );
    }

    /// @dev Called from the factory constructor, before its getters exist, so bindings are passed explicitly.
    function validateInitialTaxPolicy(
        TaxFeeMath.TaxPolicy calldata policy,
        uint256 supply,
        address factory,
        TaxLaunchHook hook
    ) external view {
        TaxFeeMath.validatePolicy(policy, supply);
        _validateRecipient(
            policy.protocolFeeConfiguration.protocolFeeRecipient, _initialRecipientContext(factory, hook)
        );
    }

    function _initialRecipientContext(address factory, TaxLaunchHook hook)
        private
        view
        returns (RecipientContext memory context)
    {
        context.factory = factory;
        context.hook = hook;
        context.launchBuyAdapter = hook.launchBuyAdapter();
        if (context.launchBuyAdapter != address(0)) {
            if (context.launchBuyAdapter.code.length == 0) revert InvalidConfig();
            ILaunchBuyAdapter adapter = ILaunchBuyAdapter(context.launchBuyAdapter);
            context.launchBuyRouter = adapter.router();
            context.launchBuySwapCaller = adapter.swapCaller();
            if (
                context.launchBuyRouter == address(0) || context.launchBuyRouter.code.length == 0
                    || context.launchBuySwapCaller == address(0) || context.launchBuySwapCaller.code.length == 0
            ) revert InvalidConfig();
        }
    }

    function _recipientContext(TaxLaunchpadFactoryCore factory, TaxLaunchHook hook)
        private
        view
        returns (RecipientContext memory context)
    {
        context = _initialRecipientContext(address(factory), hook);
        context.tokenDeployer = ITaxLaunchTokenFactory(address(factory)).tokenDeployer();
        context.dividendDeployer = ITaxDividendFactory(address(factory)).dividendDeployer();
        context.dividendImplementation = address(TaxDividendDeployer(context.dividendDeployer).implementation());
        context.dividendClaimHelper = TaxDividendDeployer(context.dividendDeployer).implementation().claimHelper();
        context.announcementRegistry = factory.announcementRegistry();
        context.checkLaunchRecords = true;
    }

    function _validateConfiguredRecipients(
        TaxLaunchpadFactoryCore factory,
        RecipientContext memory context,
        address predictedToken,
        address predictedDividend
    ) private view {
        _validateLaunchRecipient(
            factory.taxPolicy().protocolFeeConfiguration.protocolFeeRecipient,
            context,
            predictedToken,
            predictedDividend
        );
    }

    function _validateLaunchRecipient(
        address recipient,
        RecipientContext memory context,
        address predictedToken,
        address predictedDividend
    ) private view {
        if (recipient == predictedToken || recipient == predictedDividend) {
            revert InvalidConfig();
        }
        _validateRecipient(recipient, context);
    }

    function _validateRecipient(address recipient, RecipientContext memory context) private view {
        TaxLaunchHook hook = context.hook;
        if (
            recipient == address(0) || recipient == context.factory || recipient == address(hook)
                || recipient == address(hook.poolManager()) || recipient == hook.feeEscrow()
                || hook.isDividendContract(recipient) || recipient == address(this)
                || recipient == address(TaxLaunchOperations) || recipient == context.tokenDeployer
                || recipient == context.dividendDeployer || recipient == context.dividendImplementation
                || recipient == context.dividendClaimHelper || recipient == context.announcementRegistry
                || recipient == context.launchBuyAdapter || recipient == context.launchBuyRouter
                || recipient == context.launchBuySwapCaller
        ) revert InvalidConfig();
        if (context.checkLaunchRecords && TaxLaunchpadFactoryCore(context.factory).isLaunchToken(recipient)) {
            revert InvalidConfig();
        }
    }
}
