# Place Launch contracts

Smart contracts of **Place Launch**, the token launchpad of [Place](https://github.com/Maksyaka12/place-web) on Base.

A launch creates a fixed-supply token (1 billion, as a **B20** token or a plain **ERC-20**) and puts the whole supply into a Uniswap v4 pool as single-sided liquidity in one transaction. A shared v4 hook owns that liquidity forever: no code path removes it. Buyers bring the ETH, USDC, crypto major or tokenized stock that the token is paired with.

- **Fee:** a fixed 1% on every swap, taken in the paired asset: 70% (0.7% of the trade) to the launch's creator vault, 30% to the platform.
- **Anti-snipe:** the fee opens high and decays to 1% within seconds of launch; the surcharge goes to the platform. The creator's launch buy pays the normal 1%.
- **Token economics is a contract, not a promise:** the creator's 70% is split into three baskets fixed at launch (they can only grow later): **creator**, **burn** (bought back in the same pool and sent to `0x…dEaD` by `process()`, which anyone can call, capped per call and per interval) and **community fund** (the creator cannot withdraw it: it can only fund Place hub campaigns or `PlaceStaking` programs for the token, in a white-listed reward token, swapped in the same transaction).
- **Launch fee:** 0.0005 ETH per launch.

The full specification lives in [`docs/LAUNCH.md`](https://github.com/Maksyaka12/place-web/blob/dev/docs/LAUNCH.md) of the `place-web` repository.

## Based on o1

This repository is a fork of [`o1exchange/o1-launch-contracts`](https://github.com/o1exchange/o1-launch-contracts) (MIT), starting from commit `3a49099`: the o1 tax suite as deployed on Base and five other chains. We keep o1's history, copyright and license. Place removes taxes and dividends and adds B20 tokens, the fixed 70/30 fee split, the three-basket creator vault and the link to the Place hub.

**Status:** `dev` holds Place Launch 0.2.0 (stage L5, new economy); `main` holds the unmodified o1 code. Deployed to Base Sepolia only, addresses in [`DEPLOYMENTS.md`](DEPLOYMENTS.md). Place's changes are **not audited** (a delta audit is required before mainnet). The list of changes against o1 is in `docs/LAUNCH.md` §9 and later sections of `place-web`.

## Build

Install [Foundry](https://book.getfoundry.sh/getting-started/installation) 1.8.4 or later (it runs Base's B20 precompiles with `--hardfork base:Cobalt`), then:

```bash
git clone --recursive https://github.com/Maksyaka12/place-contracts.git
cd place-contracts
forge build
```

If you cloned without `--recursive`, run `git submodule update --init --recursive` first.

## Security

Please report vulnerabilities privately, not in public issues. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Copyright (c) 2026 o1 for the original code, and Place for modifications and new code.

Exception: `src/staking/` is **GPL-3.0-only** ([`src/staking/LICENSE`](src/staking/LICENSE)). It holds o1's `O1Staking`, copied without changes from its source verified on Sourcify, and `PlaceStaking`, which deploys it under the Place name. See [`src/staking/README.md`](src/staking/README.md).

## Layout

| Path | What |
|---|---|
| `src/launch/` | o1's tax suite turned into Place Launch: hook, factory (ERC-20 and B20), operations, validation, fee math, ERC-20 token |
| `src/place/` | new Place code: `PlaceCreatorVault`, `PlaceRewardTokenRegistry`, `XRecipientRegistry`, `PlaceLaunchBuyAdapter` |
| `src/staking/` | `PlaceStaking` = o1's `O1Staking` (GPL-3.0-only, unchanged) |
| `src/FeeEscrow.sol`, `src/AnnouncementRegistry.sol`, `src/base/` | o1, unchanged apart from the header |
| `script/DeployPlaceLaunch.s.sol` | mines the hook address and deploys + wires the suite |
| `script/RegisterQuotes.s.sol`, `script/quotes/base.json` | launch pairs on Base, batches of 64 |
| `script/L5Sepolia.s.sol`, `script/L5LiveRun.s.sol` | stage L5: Base Sepolia deploy of 0.2.0 and live run (launches, swaps through the Universal Router, `process()` burn, fund campaigns and staking). The L2 scripts for 0.1.0 are at commit `4eecb9e` |
| `rules/launch-holders-v2.json` | rules template committed by creator vaults (0.2.0+) for community fund campaigns; `v1` is the 0.1.0 template |

## Test

`forge test` runs everything: unit, fuzz and invariant tests locally, and fork tests that fork Base Sepolia and Base
through public RPCs (override with `BASE_SEPOLIA_RPC_URL` / `BASE_RPC_URL`). B20 only exists on the forks.
