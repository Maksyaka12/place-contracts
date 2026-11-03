// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaxDividend} from "./TaxDividend.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ArcTaxDividend
/// @notice `TaxDividend` for Arc (chain id 5042), where USDC is the native gas currency.
/// @dev `TaxDividend` handles native-quote pools by wrapping and unwrapping the native currency through a
///      WETH-style contract. Arc has no such wrapper: its USDC ERC20 at `0x3600...0000` is a six-decimal view
///      of the native balance. This version therefore rejects native-quote launches and always pays the
///      quote token through an ERC20 transfer. Everything else is inherited unchanged.
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
