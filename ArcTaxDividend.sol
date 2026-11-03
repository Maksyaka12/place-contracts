// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaxDividend} from "./TaxDividend.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Arc rewards use ERC20 units, including USDC's six-decimal view of the native balance.
contract ArcTaxDividend is TaxDividend {
    using SafeERC20 for IERC20;

    address private constant USDC = 0x3600000000000000000000000000000000000000;

    constructor(address dividendClaimHelper) TaxDividend(USDC, dividendClaimHelper) {
        if (block.chainid != 5042 || IERC20Metadata(USDC).decimals() != 6) revert InvalidConfiguration();
    }

    function _rewardTokenForQuote(address quote) internal pure override returns (address) {
        if (quote == address(0)) revert InvalidConfiguration();
        return quote;
    }

    /// @dev Both payment preferences use ERC20 transfer: Arc USDC has no deposit/withdraw wrapper.
    function _payReward(address receiver, uint256 amount, bool) internal override {
        IERC20(rewardToken).safeTransfer(receiver, amount);
    }
}
