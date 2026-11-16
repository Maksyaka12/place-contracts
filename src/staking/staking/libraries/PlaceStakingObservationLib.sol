// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

import {IPlaceStakingCore} from "../../interfaces/IPlaceStakingCore.sol";
import {PlaceStakingState} from "../PlaceStakingState.sol";
import {PlaceStakingMathLib} from "./PlaceStakingMathLib.sol";

library PlaceStakingObservationLib {
    function write(
        PlaceStakingState.Observation[] storage observations,
        uint64 timestamp,
        uint192 oldBalance,
        uint192 newBalance,
        uint64 startTime,
        uint64 endTime
    ) internal {
        uint256 count = observations.length;
        if (count == 0) {
            observations.push(
                PlaceStakingState.Observation({timestamp: timestamp, balance: newBalance, cumulativeTokenSeconds: 0})
            );
            return;
        }

        PlaceStakingState.Observation storage last = observations[count - 1];
        if (last.timestamp > timestamp || last.balance != oldBalance) {
            revert IPlaceStakingCore.AccountingInvariantBroken();
        }
        uint256 cumulative = last.cumulativeTokenSeconds + uint256(last.balance)
            * (PlaceStakingMathLib.clampTime(timestamp, startTime, endTime)
                - PlaceStakingMathLib.clampTime(last.timestamp, startTime, endTime));
        if (last.timestamp == timestamp) {
            last.balance = newBalance;
            last.cumulativeTokenSeconds = cumulative;
        } else {
            observations.push(
                PlaceStakingState.Observation({
                    timestamp: timestamp, balance: newBalance, cumulativeTokenSeconds: cumulative
                })
            );
        }
    }

    function cumulativeAt(
        PlaceStakingState.Observation[] storage observations,
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
        PlaceStakingState.Observation storage observation = observations[low - 1];
        return observation.cumulativeTokenSeconds + uint256(observation.balance)
            * (PlaceStakingMathLib.clampTime(timestamp, startTime, endTime)
                - PlaceStakingMathLib.clampTime(observation.timestamp, startTime, endTime));
    }
}
