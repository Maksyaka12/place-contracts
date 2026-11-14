// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IO1Staking} from "../../interfaces/IO1Staking.sol";

library O1StakingAssetLib {
    using SafeERC20 for IERC20;

    function actualBalance(address currency) internal view returns (uint256) {
        if (currency == address(0)) return address(this).balance;
        return erc20Balance(currency, address(this));
    }

    function erc20Balance(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (!success || data.length != 32) {
            revert IO1Staking.UnsupportedTokenBehavior();
        }
        balance = abi.decode(data, (uint256));
    }

    function pullERC20Exact(address token, address from, uint256 amount) internal {
        uint256 beforeFrom = erc20Balance(token, from);
        uint256 beforeContract = erc20Balance(token, address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 afterFrom = erc20Balance(token, from);
        uint256 afterContract = erc20Balance(token, address(this));
        if (
            afterFrom > beforeFrom || beforeFrom - afterFrom != amount || afterContract < beforeContract
                || afterContract - beforeContract != amount
        ) revert IO1Staking.UnsupportedTokenBehavior();
    }

    function pushERC20Exact(address token, address to, uint256 amount) internal {
        uint256 beforeContract = erc20Balance(token, address(this));
        uint256 beforeTo = erc20Balance(token, to);
        IERC20(token).safeTransfer(to, amount);
        uint256 afterContract = erc20Balance(token, address(this));
        uint256 afterTo = erc20Balance(token, to);
        if (
            afterContract > beforeContract || beforeContract - afterContract != amount || afterTo < beforeTo
                || afterTo - beforeTo != amount
        ) revert IO1Staking.UnsupportedTokenBehavior();
    }

    function pushERC20ExactAndRemainSolvent(address token, address to, uint256 amount, uint256 minimumBalance)
        internal
    {
        uint256 beforeContract = erc20Balance(token, address(this));
        uint256 beforeTo = erc20Balance(token, to);
        if (beforeContract < minimumBalance) {
            revert IO1Staking.CurrencyInsolvent();
        }

        IERC20(token).safeTransfer(to, amount);

        uint256 afterContract = erc20Balance(token, address(this));
        uint256 afterTo = erc20Balance(token, to);
        if (
            afterContract > beforeContract || beforeContract - afterContract != amount || afterTo < beforeTo
                || afterTo - beforeTo != amount
        ) revert IO1Staking.UnsupportedTokenBehavior();
        if (afterContract < minimumBalance) {
            revert IO1Staking.CurrencyInsolvent();
        }
    }

    function transferCurrencyOut(address currency, address to, uint256 amount) internal {
        if (currency == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            if (!success) revert IO1Staking.NativeTransferFailed();
        } else {
            pushERC20Exact(currency, to, amount);
        }
    }
}
