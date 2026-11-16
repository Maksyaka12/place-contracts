# Place Staking (GPL-3.0-only)

This folder is licensed under the **GNU General Public License v3.0 only** ([`LICENSE`](LICENSE)), unlike the rest
of the repository (MIT). Copyright (c) 2026 o1 for the original code, and Place for the changes below.

Changes made by Place (2026-11-15): contract, interface, library and file names changed to `PlaceStaking*`, and
`PlaceStaking` is the contract itself instead of a wrapper. The logic is unchanged.

How it works: anyone creates a program for any staking token; epochs of 1–365 days; a fixed reward per epoch, the
whole budget paid in up front plus the protocol fee on top; rewards are shared in proportion to amount × time staked;
each deposit is locked for one epoch; optional early-exit penalty, burned to `0x…dEaD`. Place sets the fee to 5%.
Creator vaults of Place Launch fund programs for their own token from the community fund through
`PlaceCreatorVault.fundStaking`.
