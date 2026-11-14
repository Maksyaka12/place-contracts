// SPDX-License-Identifier: MIT
// Place Launch (new code, not from o1).
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IPlaceRewardTokenRegistry {
    function maxPriceImpactBps() external view returns (uint16);
    function routeOf(address from, address to) external view returns (PoolKey[] memory);
}
