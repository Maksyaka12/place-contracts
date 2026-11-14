// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {IO1Staking} from "../../interfaces/IO1Staking.sol";
import {O1StakingState} from "../O1StakingState.sol";
import {O1StakingMathLib} from "./O1StakingMathLib.sol";

library O1StakingObservationLib {
    function write(
        O1StakingState.Observation[] storage observations,
        uint64 timestamp,
        uint192 oldBalance,
        uint192 newBalance,
        uint64 startTime,
        uint64 endTime
    ) internal {
        uint256 count = observations.length;
        if (count == 0) {
            observations.push(
                O1StakingState.Observation({timestamp: timestamp, balance: newBalance, cumulativeTokenSeconds: 0})
            );
            return;
        }

        O1StakingState.Observation storage last = observations[count - 1];
        if (last.timestamp > timestamp || last.balance != oldBalance) {
            revert IO1Staking.AccountingInvariantBroken();
        }
        uint256 cumulative = last.cumulativeTokenSeconds + uint256(last.balance)
            * (O1StakingMathLib.clampTime(timestamp, startTime, endTime)
                - O1StakingMathLib.clampTime(last.timestamp, startTime, endTime));
        if (last.timestamp == timestamp) {
            last.balance = newBalance;
            last.cumulativeTokenSeconds = cumulative;
        } else {
            observations.push(
                O1StakingState.Observation({
                    timestamp: timestamp, balance: newBalance, cumulativeTokenSeconds: cumulative
                })
            );
        }
    }

    function cumulativeAt(
        O1StakingState.Observation[] storage observations,
        uint64 timestamp,
        uint64 startTime,
        uint64 endTime
    ) internal view returns (uint256) {
        uint256 count = observations.length;
        if (count == 0) return 0;

        uint256 low;
        uint256 high = count;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (observations[mid].timestamp <= timestamp) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low == 0) return 0;
        O1StakingState.Observation storage observation = observations[low - 1];
        return observation.cumulativeTokenSeconds + uint256(observation.balance)
            * (O1StakingMathLib.clampTime(timestamp, startTime, endTime)
                - O1StakingMathLib.clampTime(observation.timestamp, startTime, endTime));
    }
}
