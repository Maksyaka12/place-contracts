# Place Launch contracts

Smart contracts of **Place Launch**, the token launchpad of [Place](https://github.com/Maksyaka12/place-web) on Base.

A launch creates a fixed-supply token (1 billion, as a **B20** token or a plain **ERC-20**) and puts the whole supply into a Uniswap v4 pool as single-sided liquidity in one transaction. A shared v4 hook owns that liquidity forever: no code path removes it. Buyers bring the ETH, USDC, crypto major or tokenized stock that the token is paired with.

## Launch types

The creator picks the type at launch. Nothing about the fees can change afterwards.

| | **Standard** | **Economy** |
|---|---|---|
| Swap tax | 1% on buys and sells | buy tax and sell tax, **1% to 5%** each |
| Platform | 30% of the tax (0.3% of the trade) | 30% of the tax (0.3% to 1.5% of the trade) |
| The other 70% | creator vault | five baskets that sum to 100%: **creator**, **holder rewards**, **trader rewards**, **burn**, **community pool** |

- **Creator** (`PlaceCreatorVault`, both types): the creator's payout address, optionally shared with X accounts (paid once the account binds a wallet in `XRecipientRegistry`).
- **Holder rewards / trader rewards** (`PlaceRewardsDistributor`): paid daily in the **reward token** the creator picked at launch (the paired asset, the launch token, or any token the `PlaceRewardTokenRegistry` lists a route to). Holders qualify with a minimum balance (10,000 tokens up to the supply); traders with a minimum daily volume in the paired asset and share the day's budget by volume.
- **Burn**: this basket is charged in the launch token and accumulates in the `FeeEscrow`; anyone calls `FeeEscrow.burn(token)` to send it to `0x…dEaD`.
- **Community pool** (`PlaceCommunityVault`): the creator cannot withdraw it. It only funds reward programs for the token: daily holder or trader streams in the distributor, or `PlaceStaking` programs, in any white-listed reward token (swapped in the same transaction with `minOut` and a per-hop price impact cap). If it sits unused for 30 days, anyone turns it into a holders stream. The creator can also fund NFT holder streams for an official, paid collection of the token (at most 25% of the fund, once per 30 days) and buy back and burn the token (`buybackAndBurn`, guarded by `PlacePriceGuard`).
- **Anti-snipe** (optional per launch): the tax opens at 99% and decays to the normal tax within 20 seconds; the surcharge goes to the platform. The creator's launch buy pays the normal tax.
- **Launch fee:** 0.0005 ETH per launch.

## Daily rewards

`PlaceRewardsDistributor` runs reward streams in UTC-day epochs:

1. The hook keeps each launch's holder and trader baskets in the `FeeEscrow`, one account per stream.
2. Once a day anyone calls `closeEpoch(token)`. The stream pulls its account and, when the reward token differs from the paired asset, swaps it along the registry route (capped price impact per hop; a swap that exceeds the cap is deferred and can be retried in slices with `convert`).
3. The Place publisher posts a **cumulative** Merkle root per stream: every account's total over all days, with the table on IPFS. A root's total can never exceed what the stream has funded, and claims can never exceed the root's total.
4. Accounts claim the difference between their cumulative amount and what they already claimed, for many streams at once with `claimMany`. A day with nobody eligible leaves its budget for the following days. Rewards do not expire.

Anyone can also fund a stream up front for any token (`createStream`, N daily epochs, 5% stream fee); the community pool uses this for its campaigns. Budget that was never allocated returns to the funder 30 days after the last epoch.

Leaf format: `keccak256(bytes.concat(keccak256(abi.encode(streamId, account, cumulativeAmount))))`.

## NFT collections

An NFT launch works like a token launch. `PlaceNftFactory` creates `PlaceNftCollection` clones (ERC-721, ERC-2981)
paired with a token: a Place token (through its launch pool) or any token with a route from ETH in the
`PlaceRewardTokenRegistry` (1–3 Uniswap v4 hops). A token without a route cannot be paired; a free collection may have
no pair. A collection made by the pair token's creator is marked **official**.

- **Unique** (one metadata file per NFT in an IPFS folder) or **Edition** (one URI for all); supply, per-wallet limit,
  mint window, collection metadata (`contractURI`).
- The mint price is in ETH; buyers can also pay in the pair token at the ETH equivalent at the moment of the mint.
- Every mint payment and every royalty (0–10%) is split: **20% platform**, the rest between the creator, NFT holders
  and buyback & burn of the pair token, as the creator set at creation.
- **Holders pool**: the holders share, in the **reward token** the creator picked (ETH, the pair token, or any token
  with a registry route from ETH), is paid out over 30 days. Every day at 00:00 UTC a portion accrues equally to each
  NFT that exists at that moment; a new income re-spreads what is left plus the income over the next 30 days. No
  keeper: any transaction catches up on the days passed. Income that arrives before the first NFT goes to the creator.
  What an NFT accrued stays with the seller when it changes hands; owners claim at any time.
- In the mint transaction the holders share is swapped into the reward token and the burn share buys the pair token
  and burns it (pair-token payments burn at once). If a swap cannot run safely the mint still succeeds and the amount
  waits for the next mint, or for anyone to call `processPending`. ETH royalties wait the same way.
- Swaps go through the factory's `PlaceNftSwapper` and `PlacePriceGuard`: a reference price per pool that moves at most
  1% per observation and is never used in the block it was written. Token-priced mints charge the larger of the
  reference and spot amounts, swaps must reach the reference output minus a tolerance, and both refuse to run while spot
  and reference differ by more than 3%.

## Status

Place Launch **0.3.1** (Standard and Economy launches, daily rewards, community pool, NFT launchpad) is deployed to **Base Sepolia only**; addresses of every release are in [`DEPLOYMENTS.md`](DEPLOYMENTS.md). The code is **not audited yet**. An audit is required before mainnet.

## Build

Install [Foundry](https://book.getfoundry.sh/getting-started/installation) 1.8.5 or later (it runs Base's B20 precompiles with `--hardfork base:Denim`), then:

```bash
git clone --recursive https://github.com/Maksyaka12/place-contracts.git
cd place-contracts
forge build
```

If you cloned without `--recursive`, run `git submodule update --init --recursive` first.

## Test

`forge test` runs everything: unit, fuzz and invariant tests locally, and fork tests that fork Base Sepolia and Base
through public RPCs (override with `BASE_SEPOLIA_RPC_URL` / `BASE_RPC_URL`). B20 only exists on the forks.
`forge test --no-match-contract Fork` runs the local suites only.

## Layout

| Path | What |
|---|---|
| `src/launch/` | launch core: hook, factory (ERC-20 and B20, Standard and Economy), operations, validation, fee math, ERC-20 token |
| `src/place/` | `PlaceCreatorVault`, `PlaceCommunityVault`, `PlaceRewardsDistributor`, `PlaceRewardTokenRegistry`, `XRecipientRegistry`, `PlaceLaunchBuyAdapter` |
| `src/nft/` | `PlaceNftFactory`, `PlaceNftCollection`, `PlaceNftSwapper`, `PlacePriceGuard` |
| `src/staking/` | `PlaceStaking`: staking programs for any token (GPL-3.0-only) |
| `src/FeeEscrow.sol`, `src/AnnouncementRegistry.sol`, `src/base/` | fee escrow (pull claims, reward accounts, burn), announcements, v4 hook base |
| `script/DeployPlaceLaunch.s.sol` | mines the hook address and deploys + wires the suite |
| `script/V75Sepolia.s.sol` | Base Sepolia 0.3.1-testnet: NFT launchpad, price guard and a launch suite with the new community vaults |
| `script/RegisterQuotes.s.sol`, `script/quotes/base.json` | launch pairs on Base, batches of 64 |
| `rules/` | rules templates committed by 0.1.0 and 0.2.0 creator vaults for hub campaigns |

## Security

Please report vulnerabilities privately, not in public issues. See [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE), except `src/staking/`, which is **GPL-3.0-only** ([`src/staking/LICENSE`](src/staking/LICENSE), details in [`src/staking/README.md`](src/staking/README.md)).
