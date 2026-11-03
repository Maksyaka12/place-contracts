# o1 Launch Tax Contracts

Solidity source of the o1 launch tax suite, as deployed.

A tax token is a fixed-supply ERC20 that launches straight into a Uniswap v4 pool. Its creator picks a buy tax and a sell tax. A v4 hook charges that tax on every swap and splits it between the protocol, the creator, a token burn, holder dividends and an optional integrator.

There is no bonding curve and no graduation step. One transaction deploys the token, opens the pool and locks the liquidity forever.

## Contents

- [How it works](#how-it-works)
- [Contracts](#contracts)
- [Deployments](#deployments)
- [Build](#build)
- [Launching a token](#launching-a-token)
- [Tax model](#tax-model)
- [Dividends](#dividends)
- [Creator rights](#creator-rights)
- [Roles and trust assumptions](#roles-and-trust-assumptions)
- [Security](#security)
- [License](#license)

## How it works

```
 creator --createLaunch--> TaxRWAERC20LaunchpadFactory
                             | deploys the token and its dividend clone
                             | opens and seeds the TOKEN/quote v4 pool
                             v
 trader ---swap---> Uniswap v4 PoolManager ---> TaxLaunchHook
                                                  | takes the buy or sell tax
                                                  v
                                              FeeEscrow (pull-based claims)
                                                  |
             +-----------+-----------+------------+-------------+
             |           |           |            |             |
          protocol    creator    integrator   burn sink    TaxDividend clone
                                                                 |
                                                                 v
                                                           token holders
```

1. **Launch.** The factory validates the launch and its tax configuration, deploys a `TaxLaunchToken` with CREATE2 and, when dividends are on, a `TaxDividend` clone. It then initializes a `TOKEN/quote` v4 pool and seeds it with single-sided liquidity. The hook owns that liquidity and has no code path to remove it.
2. **Trade.** On each swap, `TaxLaunchHook` charges the launch's buy or sell tax. The tax is the whole trading fee: the pool has no separate LP fee. The hook mints each recipient's share to `FeeEscrow` as an ERC-6909 claim. Wallet-to-wallet transfers are never taxed.
3. **Claim.** Recipients withdraw from `FeeEscrow` whenever they like. Holders withdraw dividends from their token's `TaxDividend` clone, or from many clones at once through `TaxDividendClaimHelper`.

## Contracts

| Contract | Role |
| --- | --- |
| [`TaxRWAERC20LaunchpadFactory`](src/tax/TaxRWAERC20LaunchpadFactory.sol) | The factory. Adds the quote registry, price updater, launch kill switch and token address suffix. |
| [`TaxLaunchpadFactoryCore`](src/tax/TaxLaunchpadFactoryCore.sol) | Launch flow, launch buy, owner policy, creator rights, metadata and dividend administration. |
| [`TaxERC20FactoryBase`](src/tax/TaxERC20FactoryBase.sol) | Binds the factory to its token and dividend deployers. |
| [`TaxLaunchHook`](src/tax/TaxLaunchHook.sol) | The shared Uniswap v4 hook. Gates pool creation, locks liquidity, takes the tax and routes each share. |
| [`TaxLaunchToken`](src/tax/TaxLaunchToken.sol) | Fixed-supply ERC20 with no owner, mint, burn, pause or upgrade. Reports balance changes to its dividend clone. |
| [`TaxDividend`](src/tax/TaxDividend.sol) | Per-token dividend tracker, deployed as a clone. |
| [`ArcTaxDividend`](src/tax/ArcTaxDividend.sol) | `TaxDividend` for Arc, where USDC is the native currency. |
| [`TaxDividendClaimHelper`](src/tax/TaxDividendClaimHelper.sol) | Claims many dividend clones in one atomic call. |
| [`TaxLaunchTokenDeployer`](src/tax/TaxLaunchTokenDeployer.sol), [`TaxDividendDeployer`](src/tax/TaxDividendDeployer.sol) | Deterministic CREATE2 deployers, each bound once to one factory. |
| [`TaxLaunchValidation`](src/tax/TaxLaunchValidation.sol), [`TaxLaunchOperations`](src/tax/TaxLaunchOperations.sol) | Validation contract and linked library that keep the factory under the size limit. |
| [`TaxFeeMath`](src/tax/TaxFeeMath.sol), [`TaxSuiteConstants`](src/tax/TaxSuiteConstants.sol) | Fee math, rounding rules and constants. |
| [`FeeEscrow`](src/FeeEscrow.sol) | Pull-based ERC-6909 fee ledger for every tax recipient. |
| [`AnnouncementRegistry`](src/AnnouncementRegistry.sol) | Feed of creator announcements, bound to one factory. |
| [`BaseHook`](src/base/BaseHook.sol) | Minimal v4 hook base. Checks the hook address permission bits and only accepts PoolManager callbacks. |

Interfaces are in [`src/tax/interfaces`](src/tax/interfaces) and [`src/interfaces`](src/interfaces). Any contract that implements [`ILaunchBuyAdapter`](src/interfaces/ILaunchBuyAdapter.sol) can be approved by the owner to route launch buys.

## Deployments

The tax suite is deployed on six chains. Each contract's runtime bytecode matches a build of this repository, with one exception noted below.

| Contract | BSC, X Layer, Arc, Monad, Robinhood | Base |
| --- | --- | --- |
| `TaxRWAERC20LaunchpadFactory` | `0x29CAD997f3cf1aa9CA51E12BE29C09E3E00F119A` | `0x53C59d8d335681d58F564cF62073fA3C57cF81ee` |
| `FeeEscrow` | `0x1Dede99A17e1C7775541d73B675470Ba4BeE0318` | `0xFae34Bd1311b37d315bF412cc1a4e441F07f4517` |
| `TaxDividendClaimHelper` | `0x1b056e998211FfB67Ba26A1b5B82316536F42857` | `0x196C682446F823Ed0078352EF376ac8e94c36E21` |
| `AnnouncementRegistry` | `0x11f1D9d0c3107bde23124e39D3935Bc8d4f904D4` | `0xBe3eE12329751f1A02aD01584a0E7Ff60589559d` |
| `TaxLaunchTokenDeployer` | `0x0598EB4bD64E0dA829a4A82EfAeae2EE019AEC94` | `0xBEcbA599C8bd5373ba9C680eA4B3AfFC5C7a4311` |
| `TaxDividendDeployer` | `0x2202fd7fEA1986C22Fa7417D82CdAc435150d17f` | `0xD69aE39E360E6C71780629fb826BdCeeE3a456Ca` |
| `TaxDividend` (`ArcTaxDividend` on Arc) | `0x3E20211A9372f27a6fd89CD0E81aD242d34a0a1f` | `0x9058CEF57492541512bE650B683c31dB1Bcf2a5F` |
| `TaxLaunchValidation` | `0x6bD93cEf0A71a1c4Df1595e880A3F1843aB738E8` | `0x08daA0eCa69a9B1E295e234Fc7C3A9c5020a378c` |
| `TaxLaunchOperations` | `0x88F9fb0256D8493D1060C8a29C2ABB4841159422` (Arc: `0x03f1D87f5F731442dDFf36B74e365814C832A63D`) | `0x88F9fb0256D8493D1060C8a29C2ABB4841159422` |

Each chain has its own `TaxLaunchHook`:

| Chain | Chain id | `TaxLaunchHook` |
| --- | --- | --- |
| Base | 8453 | `0x9C7155D7216454D9d894F792c8B5C564F2c66AcC` |
| BSC | 56 | `0x993fFbbcc174763FC1B1041D3ae73d71a1632acC` |
| X Layer | 196 | `0xb15927F5605B232CdC57B97FD221bc584032aAcc` |
| Arc | 5042 | `0x7a3D518f9278f32E5D11D931C3B726831E6D6ACc` |
| Monad | 143 | `0x2ac294ffa4A1F3cA188DfBc60F19D8c16a10EACc` |
| Robinhood | 4663 | `0xe05521566199A3Ba8D8721C0e44E96018EB1EaCc` |

The `TaxDividend` implementation on every chain except Arc was deployed from an earlier revision of [`TaxDividend.sol`](src/tax/TaxDividend.sol). That revision had the reward token choice and the payout inline, before they moved into the two internal functions that `ArcTaxDividend` overrides. The behavior is identical, and the runtime bytecode differs by 7 bytes.

## Build

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then:

```bash
git clone --recursive https://github.com/o1exchange/o1-launch-contracts.git
cd o1-launch-contracts
forge build
```

If you cloned without `--recursive`, run `git submodule update --init --recursive` first.

The contracts compile with solc `0.8.26`, the Cancun EVM, `via_ir` and 200 optimizer runs, as set in [`foundry.toml`](foundry.toml). The only dependency is [Uniswap v4-core](https://github.com/Uniswap/v4-core) `v4.0.0`, which also provides OpenZeppelin Contracts.

## Launching a token

A creator calls `createLaunch(params)`, or `createLaunchAndBuy(params, buyParams)` to launch and make the first buy in the same transaction.

- **Config version and deadline.** `params.expectedConfigVersion` must equal the factory's `configVersion`, and the transaction must land at or before `params.deadline`. Changes to the tax policy, quote list or launch settings bump `configVersion`, so a creator never launches under tax terms they did not see.
- **Quote token.** The quote must be registered. Each quote has a start tick (`startTickToken0Frame`) that sets the opening price, so every quote can open at a similar market cap. The owner or the `priceUpdater` can move it, naming the quote's current revision. Start tick moves follow market prices and do not bump `configVersion`.
- **Supply and liquidity.** Every launch mints the factory's `launchSupply` (between 1 million and 1 trillion tokens) into the pool. The owner's band template spreads that supply over up to 10 single-sided liquidity bands.
- **Token address.** The address is derived from the creator and their `creatorSalt`, and each salt works once per creator. The factory only accepts addresses ending in `0x01`, so clients search for a fitting salt with `launchTokenInitCodeHash`.
- **Native launch fee.** If the owner sets `nativeLaunchFee`, the creator pays it in native currency to the protocol fee recipient.
- **Launch buy.** `createLaunchAndBuy` routes the first buy through the owner-approved `ILaunchBuyAdapter`. The hook checks that the creator receives exactly the reported output, and at least `minAmountOut`. If the buy fails, the whole launch reverts.
- **Kill switch.** `setLaunchCreationEnabled(false)` stops new launches. Existing pools keep trading.

## Tax model

The creator picks `buyTaxRate` and `sellTaxRate` inside the owner's bounds. Each rate is the full fee for that side of a trade.

- **Protocol cut:** `min(max(tax * protocolTaxShare, minimumProtocolFeeRate), maximumProtocolFeeRate)`.
- **Remainder:** four creator-chosen shares split what is left. They must sum to 100% and apply to both buys and sells.
  - `creatorAllocationShare`: paid in the quote asset to the creator fee recipient.
  - `burnAllocationShare`: paid in launched tokens to `0x000000000000000000000000000000000000dEaD`.
  - `dividendAllocationShare`: paid in the quote asset to holders through the dividend clone.
  - `integratorAllocationShare`: paid in the quote asset to the integrator recorded at launch, such as a frontend.

Percentages are `uint32` values on a six-decimal scale: `PERCENTAGE_SCALE = 100_000_000`, so `1%` is `1_000_000`. The total fee can never exceed 99% (`MAX_TOTAL_FEE_RATE`). A side with a zero tax pays nothing, not even the protocol fee. `TaxFeeMath` defines every rounding rule, and `previewTaxConfiguration` on the factory returns the exact rates a configuration produces.

Every rate, share, integrator and dividend setting is frozen when the token launches. Owner policy changes apply to future launches only.

**Example.** With a 10% buy tax, a protocol cut of 1% of the trade, and shares of 50% creator, 20% burn and 30% dividends, a 100 USDC buy pays 1 USDC to the protocol, 4.5 USDC to the creator and 2.7 USDC to holders, and burns 1.8 USDC worth of tokens.

**Anti-snipe (optional).** A launch can opt into an opening surcharge. The fee starts at the policy's `startTotalFeeRate` and decays linearly to the normal tax over `windowSeconds`. The surcharge goes to the protocol, and exact-output swaps are blocked while it is active.

## Dividends

A launch with a dividend share gets its own `TaxDividend` clone, owned by the factory.

- Holders earn in proportion to their balance once they hold at least `minimumDividendHolding` tokens. The creator sets this value, and it must meet the owner's minimum. The pool and other custody addresses are excluded.
- The token reports balance changes to the clone, and the hook reports each dividend fee during the swap. A reward-per-share accumulator means fees never loop over holders, and a buyer cannot earn from trades made before they held the token.
- If no holder is eligible when a fee arrives, the fee goes to the protocol recipient instead of waiting for future holders.
- Holders call `withdrawDividends()`. The claim helper can claim for a holder with `withdrawDividendsFor(holder, unwrapWrappedNative)`, and `TaxDividendClaimHelper.claimDividends` claims up to 64 tokens in one call. Native-quote pools can pay out in native currency.
- Anyone can add rewards with `depositDividends(amount)`, or restore backing without creating new rewards with `replenishBacking(amount)`.

`ArcTaxDividend` is `TaxDividend` for Arc, where USDC is the native gas currency. `TaxDividend` handles native-quote pools by wrapping and unwrapping the native currency through a WETH-style contract, and Arc has no such wrapper. `ArcTaxDividend` therefore rejects native-quote launches and always pays the quote token through an ERC20 transfer. It overrides only those two internal functions, so on Arc a launch with dividends uses an ERC20 quote such as USDC.

## Creator rights

The factory keeps a `CreatorRights` record for each token: original creator, current creator, pending creator and creator fee recipient.

- The current creator can change the fee recipient with `setCreatorFeeRecipient`.
- Rights move in two steps (`proposeCreatorRightsTransfer`, then `acceptCreatorRightsTransfer`), or in one step to a contract that implements `ICreatorRightsReceiver` with `safeTransferCreatorRights`.
- If the token launched with `metadataEditable`, the current creator can update its name, symbol, contract URI and extra metadata through the factory. Otherwise its metadata is fixed.

## Roles and trust assumptions

- The **factory owner** sets policy for future launches: tax bounds, protocol fee, anti-snipe, minimum dividend holding, launch supply, tick spacing, band template, native launch fee, launch buy adapter and quote tokens. The owner cannot change the taxes, shares or integrator of an existing launch.
- The **price updater** can move a registered quote's start tick, which changes the opening price of future launches only.
- The factory owner or the **creator admin** can, for any existing launch:
  - reassign creator rights or change the creator fee recipient;
  - add or remove dividend exclusions, redirect a holder's dividend receiver, and refresh holder shares;
  - make an emergency withdrawal from a dividend clone. This can remove reward backing, so claims may fail until backing is restored.

  These powers are intentional. They never reach the locked liquidity or `FeeEscrow`.
- The owner cannot renounce ownership while a creator admin, pending creator admin, launch buy adapter or price updater is set, or while launch creation is enabled.
- Liquidity is locked forever, and no contract is upgradeable.

## Security

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md) for how to report one privately.

## License

[MIT](LICENSE)
