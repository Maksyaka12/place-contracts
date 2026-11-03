# o1 Launch — Tax Token Contracts

These are the Solidity contracts behind o1 launch **tax tokens**. A tax token is a fixed-supply ERC20 that launches into a Uniswap v4 pool. Its creator chooses a buy tax and a sell tax. A v4 hook takes that tax on every swap and splits it between the protocol, the creator, a burn, token-holder dividends, and an optional integrator.

The suite has no bonding curve and no graduation step. Each launch creates the token, opens the pool, and locks the liquidity permanently, all in one transaction.

## How it works

```
creator ──createLaunch / createLaunchAndBuy──▶ TaxRWAERC20LaunchpadFactory
                              │ deploys token (+ optional dividend clone)
                              │ opens & seeds the TOKEN/quote v4 pool
                              ▼
trader ──swap──▶ Uniswap v4 PoolManager ──▶ TaxLaunchHook
                                               │ takes buy/sell tax
                                               ▼
                                           FeeEscrow (pull-based claims)
                                     ┌─────────┼──────────┬───────────┐
                                  protocol  creator  integrator   burn (0x…dEaD)
                                               │
                                               └──▶ TaxDividend clone ──▶ token holders
```

1. **Launch.** The factory validates the launch parameters and the creator's tax configuration. It then deploys a `TaxLaunchToken` with CREATE2 and, when the launch enables dividends, a `TaxDividend` clone. Next it initializes a `TOKEN/quote` v4 pool and seeds it with single-sided liquidity. The hook owns that liquidity and can never withdraw it.
2. **Trade.** On each swap, `TaxLaunchHook` charges the launch's buy or sell tax. The tax includes every trading fee; there is no separate LP fee or base fee. The hook records each recipient's share as an ERC-6909 claim in `FeeEscrow`. Transfers between wallets are not taxed.
3. **Claim.** Recipients withdraw from `FeeEscrow` when they choose. Holders withdraw dividends from their token's `TaxDividend` clone. `TaxDividendClaimHelper` claims across many tokens in one call.

## Launching

A creator calls `createLaunch(params)`, or `createLaunchAndBuy(params, buyParams)` to launch and make the first buy in the same transaction.

- **Config version and deadline.** `params.expectedConfigVersion` must equal the factory's current `configVersion`, and the transaction must land before `params.deadline`. Any owner policy change bumps `configVersion`, so a creator never launches under terms they did not see.
- **Quote token.** The quote must be registered on the factory. Each quote has a start tick (`startTickToken0Frame`) that sets the opening price, so every quote can open at a similar market cap. The owner or the `priceUpdater` can move a quote's start tick; the update must name the quote's current revision.
- **Supply and liquidity.** Every launch mints the factory's `launchSupply` (between 1M and 1T tokens) into the pool. The owner's band template spreads that supply across up to 10 single-sided liquidity bands.
- **Address.** The token address is derived from the creator and their `creatorSalt`. Each salt can be used once per creator. The concrete factory also requires the token address to end in `0x01`.
- **Native launch fee.** If the owner sets `nativeLaunchFee`, the creator pays it in native currency. It goes to the protocol fee recipient.
- **Launch buy.** `createLaunchAndBuy` routes the buy through the owner-approved `ILaunchBuyAdapter`. The hook checks that the creator receives exactly the reported output and at least `minAmountOut`. Exact-output launch buys are not supported. If the buy fails, the whole launch reverts.
- **Kill switch.** The owner can turn launch creation off with `setLaunchCreationEnabled(false)`. That stops new launches only. Existing pools keep trading.

## Tax model

The creator picks `buyTaxRate` and `sellTaxRate`, inside the owner's per-side bounds. Each rate is the full fee that side of a trade pays.

- **Protocol cut:** `min(max(totalTax × protocolTaxShare, minimumProtocolFeeRate), maximumProtocolFeeRate)`.
- **Remainder:** four creator-chosen shares split what is left. The shares must sum to 100%, and the same split applies to buys and sells.
  - `creatorAllocationShare`: paid in the quote asset to the creator's fee recipient.
  - `burnAllocationShare`: paid in launched tokens, which go to `0x000000000000000000000000000000000000dEaD`.
  - `dividendAllocationShare`: paid in the quote asset to token holders through the dividend clone.
  - `integratorAllocationShare`: paid in the quote asset to the integrator (for example, a frontend or launchpad) recorded at launch.

Percentages are `uint32` values on a six-decimal scale: `PERCENTAGE_SCALE = 100_000_000`, so `1%` is `1_000_000`. The combined fee can never exceed 99% (`MAX_TOTAL_FEE_RATE`). A side with a zero tax rate pays no fee at all, including no protocol fee. All rounding is specified in `TaxFeeMath`. Use `previewTaxConfiguration` on the factory to see the exact rates a configuration produces.

Every rate, share, integrator and dividend setting is frozen when the token launches. Owner policy changes apply to future launches only.

**Anti-snipe (optional).** A launch can opt into an opening surcharge. The total fee starts at the policy's `startTotalFeeRate` and decays linearly to the normal tax over `windowSeconds`. The surcharge goes to the protocol. Exact-output swaps are blocked while the surcharge is active.

## Dividends

A launch with a positive dividend share gets its own `TaxDividend` clone. Its owner is always the factory.

- Holders earn in proportion to their balance. A holder must hold at least `minimumDividendHolding` tokens to earn; the creator chooses this value, and it must meet the owner's minimum. The pool and other custody addresses can be excluded.
- The token reports every balance change to the clone. The hook reports each dividend fee during the swap. The clone updates a reward-per-share accumulator, so a fee never loops over holders. A buyer cannot claim fees from trades that happened before they held the token.
- If no holder is eligible when a fee arrives, the fee goes to the protocol recipient. It is not held back for future holders.
- Holders call `withdrawDividends()`. The trusted helper can also claim for a holder with `withdrawDividendsFor(holder, unwrapWrappedNative)`. Native-quote pools can pay out in native currency.
- Anyone can add rewards with `depositDividends(amount)`, or restore backing without creating new rewards with `replenishBacking(amount)`.
- `ArcTaxDividend` is a version for the Arc chain (chain id 5042), where USDC is the native currency. It always pays in USDC through ERC20 transfers.

## Creator rights

The factory tracks a `CreatorRights` record for each token: the original creator, the current creator, a pending creator, and the creator fee recipient.

- The current creator can change the fee recipient with `setCreatorFeeRecipient`.
- Rights move in two steps (`proposeCreatorRightsTransfer` then `acceptCreatorRightsTransfer`), or in one step to a contract with `safeTransferCreatorRights`. The receiving contract must implement `ICreatorRightsReceiver`.
- If the creator launched with `metadataEditable`, the current creator can update the token's name, symbol, contract URI and extra metadata through the factory. Otherwise the token has no metadata authority and its metadata is fixed.

## Launch consent

When a launch names an integrator contract, the hook asks that contract whether it accepts the launch (`ILaunchConsent.launchConsent`). The call is a read-only `staticcall` capped at 50,000 gas.

- An explicit rejection reverts the whole launch, including any launch buy.
- An explicit acceptance is recorded in `launchConsented(poolId)`.
- Any other answer lets the launch continue without a record. That includes an unknown value, a revert, or running out of gas.

This lets an integrator refuse launches that name it. It cannot affect any other launch. See [LAUNCH_CONSENT.md](LAUNCH_CONSENT.md) for the exact answer words, gas rules and security invariants.

## Contracts

| Contract | Role |
| --- | --- |
| [`TaxRWAERC20LaunchpadFactory.sol`](TaxRWAERC20LaunchpadFactory.sol) | The concrete factory you deploy. It manages the quote registry and price updater, the launch kill switch, and the token address suffix. |
| [`TaxLaunchpadFactoryCore.sol`](TaxLaunchpadFactoryCore.sol) | Abstract factory logic: launch flow, launch buy, owner policy (`ITaxFeeAdmin`), creator rights, metadata, dividend administration. |
| [`TaxERC20FactoryBase.sol`](TaxERC20FactoryBase.sol) | Abstract layer that binds the factory to its token and dividend deployers. |
| [`TaxLaunchHook.sol`](TaxLaunchHook.sol) | The single shared Uniswap v4 hook. It gates pool creation, locks liquidity, takes the swap tax and routes each share. |
| [`TaxLaunchToken.sol`](TaxLaunchToken.sol) | Fixed-supply ERC20 with no owner, mint, burn, pause or upgrade. It notifies its dividend clone when balances change. |
| [`TaxDividend.sol`](TaxDividend.sol), [`ArcTaxDividend.sol`](ArcTaxDividend.sol) | Per-token dividend tracker, deployed as a clone. |
| [`TaxDividendClaimHelper.sol`](TaxDividendClaimHelper.sol) | Claims many dividend clones in one atomic call, up to 64 tokens. |
| [`TaxLaunchTokenDeployer.sol`](TaxLaunchTokenDeployer.sol), [`TaxDividendDeployer.sol`](TaxDividendDeployer.sol) | Deterministic CREATE2 deployers, each bound once to one factory. |
| [`TaxLaunchValidation.sol`](TaxLaunchValidation.sol), [`TaxLaunchOperations.sol`](TaxLaunchOperations.sol) | Stateless validation and a linked library. They exist to keep the factory under the contract size limit. |
| [`TaxFeeMath.sol`](TaxFeeMath.sol), [`TaxSuiteConstants.sol`](TaxSuiteConstants.sol) | Fee math, rounding rules and constants. |
| [`LaunchConsent.sol`](LaunchConsent.sol) | Gas-bounded integrator consent check. |
| [`interfaces/`](interfaces) | `ILaunchConsent`, `ITaxDividend`, `ITaxDividendClaimHelper`, `ITaxFeeAdmin`, `ITaxLaunchToken`. |

### Shared dependencies

The tax contracts import these shared o1 launch contracts, which are not in this directory:

| Import | Role |
| --- | --- |
| `../FeeEscrow.sol` | Pull-based ERC-6909 fee ledger for every tax recipient. |
| `../AnnouncementRegistry.sol` | Feed of creator announcements, bound to the factory. |
| `../base/BaseHook.sol` | Minimal v4 hook base that checks permission bits and rejects callbacks not from the PoolManager. |
| `../interfaces/ICreatorRightsReceiver.sol`, `ILaunchBuyAdapter.sol`, `ILaunchTokenMetadata.sol`, `IRWAQuoteRegistry.sol` | Shared interfaces for creator-rights transfers, launch buys, token metadata and the quote registry. |

External imports come from Uniswap `v4-core` (`v4-core/...`) and OpenZeppelin Contracts (`@openzeppelin/contracts/...`).

## Trust assumptions

- The **factory owner** sets policy for future launches: tax bounds, protocol fee, anti-snipe, minimum dividend holding, launch supply, tick spacing, band template, native launch fee, launch buy adapter and approved quote tokens. The owner cannot change the tax rates, shares or integrator of a launch that already exists.
- The **price updater** can move a registered quote's start tick. That changes the opening price of future launches only.
- The factory owner or the `creatorAdmin` can, for any existing launch:
  - reassign creator rights or change the creator fee recipient;
  - add or remove dividend exclusions, redirect a holder's dividend receiver, and refresh holder shares;
  - make an **emergency withdrawal** from a dividend clone. That can remove reward backing, so claims may fail until the backing is restored.

  These powers are intentional. They do not reach the locked liquidity or `FeeEscrow`.
- The owner cannot renounce ownership while a creator admin, launch buy adapter or price updater is set, or while launch creation is enabled.
- Liquidity is locked forever, and the tokens cannot be upgraded.

## Build

The contracts target solc `0.8.26`, the Cancun EVM and `via_ir`. To compile them, place this directory at `src/tax/` in a Foundry project that also provides the [shared dependencies](#shared-dependencies), and remap:

```
v4-core/=lib/v4-core/
@openzeppelin/=lib/v4-core/lib/openzeppelin-contracts/
```

Uniswap `v4-core` v4.0.0 also provides OpenZeppelin and solmate.

## License

MIT
