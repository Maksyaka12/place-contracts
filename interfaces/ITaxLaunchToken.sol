// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ITaxLaunchToken is IERC20Metadata {
    function factory() external view returns (address);
    function dividendsEnabled() external view returns (bool);
    function dividend() external view returns (address);
    function initializeDividend(address dividendContract) external;
}
