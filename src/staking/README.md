# Place Staking (GPL-3.0-only)

This folder is licensed under the **GNU General Public License v3.0 only** ([`LICENSE`](LICENSE)), unlike the rest
of the repository (MIT).

| File | Origin |
|---|---|
| `O1Staking.sol`, `interfaces/IO1Staking.sol`, `staking/O1StakingRead.sol`, `staking/O1StakingState.sol`, `staking/libraries/O1StakingAssetLib.sol`, `staking/libraries/O1StakingMathLib.sol`, `staking/libraries/O1StakingObservationLib.sol` | **o1**, copied **without changes** from the source of `O1Staking` verified on Sourcify: Base (8453), [`0x6f25a9e1e677616c1bF7ab54b470b0c82839Adb4`](https://repo.sourcify.dev/8453/0x6f25a9e1e677616c1bF7ab54b470b0c82839Adb4), solc 0.8.26, via-IR, 200 runs, cancun. Copyright o1. Downloaded 2026-11-14. |
| `PlaceStaking.sol` | Place: a thin wrapper that deploys `O1Staking` under the Place name, same constructor. |

The OpenZeppelin files the source imports are the ones in `lib/v4-core/lib/openzeppelin-contracts` (identical to
the verified sources apart from line endings).

How it works (o1's design): anyone creates a program for any staking token; epochs of 1–365 days; a fixed reward per
epoch, the whole budget paid in up front plus the protocol fee on top; rewards are shared in proportion to amount ×
time staked; each deposit is locked for one epoch; optional early-exit penalty, burned to `0x…dEaD`. Place sets the
fee to 5% (SPEC.md decision #10). Creator vaults of Place Launch fund programs for their own token from the community
fund through `PlaceCreatorVault.fundStaking`.

Any change Place makes to these files must be listed here and goes into the delta audit.
