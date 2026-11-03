// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITaxDividendClaimHelper} from "./interfaces/ITaxDividendClaimHelper.sol";
import {ITaxDividend} from "./interfaces/ITaxDividend.sol";
import {TaxSuiteConstants} from "./TaxSuiteConstants.sol";

interface ITaxDividendClaimHook {
    function factory() external view returns (address);
    function feeEscrow() external view returns (address);
    function poolManager() external view returns (address);
    function wired() external view returns (bool);
    function isDividendContract(address dividend) external view returns (bool);
}

interface ITaxDividendClaimFactory {
    function dividendOf(address token) external view returns (address);
}

/// @notice Atomically withdraw the calling holder's earned dividends from this suite's registered launches.
/// @dev The immutable Hook's existing protected, set-once wiring is the only factory binding.
contract TaxDividendClaimHelper is ITaxDividendClaimHelper, ReentrancyGuard {
    address public immutable override hook;
    uint256 public constant MAX_BATCH_SIZE = TaxSuiteConstants.MAX_BATCH_SIZE;

    error InvalidConfiguration();
    error InvalidBatch();
    error DuplicateToken(address token);
    error InvalidDividend(address token);

    event DividendsClaimed(address indexed holder, uint256 requestedCount, uint256 paidCount);

    constructor(address launchHook) {
        if (launchHook.code.length == 0) revert InvalidConfiguration();
        hook = launchHook;
    }

    function factory() public view override returns (address) {
        return ITaxDividendClaimHook(hook).factory();
    }

    function claimDividends(Claim[] calldata claims)
        external
        override
        nonReentrant
        returns (uint256 paidCount, bool[] memory paid)
    {
        uint256 count = claims.length;
        if (count == 0 || count > MAX_BATCH_SIZE) revert InvalidBatch();
        address holder = msg.sender;
        ITaxDividendClaimHook launchHook = ITaxDividendClaimHook(hook);
        address launchFactory = factory();
        if (launchFactory.code.length == 0 || !launchHook.wired()) revert InvalidConfiguration();
        address escrow = launchHook.feeEscrow();
        address manager = launchHook.poolManager();
        ITaxDividend[] memory targets = new ITaxDividend[](count);
        // Validate the complete batch before any payment or receiver callback.
        for (uint256 i; i < count; ++i) {
            address token = claims[i].token;
            for (uint256 j; j < i; ++j) {
                if (claims[j].token == token) revert DuplicateToken(token);
            }
            address dividend = ITaxDividendClaimFactory(launchFactory).dividendOf(token);
            if (dividend.code.length == 0 || !launchHook.isDividendContract(dividend)) revert InvalidDividend(token);
            ITaxDividend target = ITaxDividend(dividend);
            if (
                target.taxToken() != token || target.owner() != launchFactory || target.hook() != hook
                    || target.claimHelper() != address(this) || target.feeEscrow() != escrow
                    || target.poolManager() != manager
            ) revert InvalidDividend(token);
            targets[i] = target;
        }
        paid = new bool[](count);
        for (uint256 i; i < count; ++i) {
            paid[i] = targets[i].withdrawDividendsFor(holder, claims[i].unwrapWrappedNative);
            if (paid[i]) ++paidCount;
        }
        emit DividendsClaimed(holder, count, paidCount);
    }
}
