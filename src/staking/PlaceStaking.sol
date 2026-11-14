// SPDX-License-Identifier: GPL-3.0-only
// Place Staking: o1's O1Staking deployed under the Place name (see README.md and LICENSE in this folder).
pragma solidity 0.8.26;

import {O1Staking} from "./O1Staking.sol";

/// @title PlaceStaking
/// @notice Staking programs for any token (SPEC.md decision #10). The logic is o1's `O1Staking`, copied without
///         changes from its source verified on Sourcify (Base, 0x6f25a9e1e677616c1bF7ab54b470b0c82839Adb4,
///         GPL-3.0-only). This contract only gives it the Place name; the fee is set at deploy (5%, like every
///         Place hub campaign) and by the owner later.
contract PlaceStaking is O1Staking {
    constructor(address initialOwner, uint16 initialFeeBps, address initialFeeRecipient)
        O1Staking(initialOwner, initialFeeBps, initialFeeRecipient)
    {}
}
