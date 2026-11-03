# Launch consent

`LaunchConsent` is an internal library in `contracts/src/tax/LaunchConsent.sol`. `TaxLaunchHook` uses it to ask the integrator contract of a new pool for consent. An integrator contract can refuse a launch that names it. The hook records a launch that the integrator accepts. `PadVault` is the first integrator policy; see [the pad launch policy](../pads/LAUNCH_POLICY.md).

## Where the check runs

- `TaxLaunchHook.registerPool` calls `LaunchConsent.requireConsent` once for each pool.
- The call comes after `_validateRegistration` and before the hook writes `poolConfig`.
- Before `registerPool`, the factory deploys the token and any dividend clone and initializes the pool. After it, the factory seeds liquidity and runs any launch buy.
- A reject reverts the complete launch, including an atomic launch buy.
- Trades do not ask again.

## Answers

| Integrator | Result |
| --- | --- |
| Zero address or an address without code | The hook does not ask. It records nothing. |
| One 32-byte word equal to `ILaunchConsent.launchConsent.selector` | The launch continues. The hook sets `launchConsented[poolId]` and emits `LaunchConsented(poolId, integrator)`. |
| One 32-byte word equal to `bytes4(keccak256("LAUNCH_REJECTED"))` | The launch reverts with `IntegratorRejectedLaunch(integrator)`. |
| Another value or size, a revert, no `launchConsent` function, a state write, or gas exhaustion | The launch continues. The hook records nothing. |

An integrator can block only the launches that name it. It cannot block another launch, move funds, or change the pool.

## Gas limits

- The hook makes a static call with `LaunchConsent.GAS`, which is 50,000 gas.
- The hook copies back at most one 32-byte word.
- Before the call, the library requires `GAS + GAS / 63 + 3,000` gas. With less gas, the launch reverts with `InsufficientGasForLaunchConsent`. A caller thus cannot starve a rejecting policy and launch anyway.
- The check fails open. A policy must answer well inside the cap, or its reject can become no answer. The `PadVault` worst case is allowlist access and restricted quotes, with every check passing. The worst case also has 64 allowed quotes, six finite tax ranges, and a finite dividend threshold window, so the vault reads all three policy slots and both lists. It used 30,456 gas on 6 October 2026 for the active child hook, and 37,047 gas for the hook of an additional suite that the registry owner enabled and the pad owner accepted. The regression tests require less than 34,000 and 40,000 gas.

## Launch context

`ILaunchConsent.LaunchContext` contains:

- `token` and `quoteToken`;
- `creator`, the original creator that the factory records;
- `antiSnipeEnabled`;
- `taxConfiguration`, the seven-field tax configuration of the launch.

The call is read-only. A policy can also read public chain state, such as the token, the factory settings, and the pool price. The pool has no liquidity at that point, and the factory creator-rights record does not exist yet. A policy cannot count launches, collect a fee, or consume a ticket.

## Record and membership

- `TaxLaunchHook.launchConsented(poolId)` exposes the record. An accept costs one storage write and one event.
- A record is permanent. A later policy change does not remove it.
- `PadRegistry.isMember(poolId)` requires the record and a pool integrator that is a vault of the same registry.
- The launch receipt processor stores the record as `poolConfigs.launchConsented`. `convex/lib/padScope.ts` requires it for pad membership.
- `src/lib/launch/errors.ts` maps `IntegratorRejectedLaunch` and `InsufficientGasForLaunchConsent` to user messages.

## Deployment consequences

**Warning:** `PadRegistry` checks the suite wiring in its constructor, but not the consent function of the hook. On a hook without `launchConsented`, `isMember` reverts and presets have no effect. Do not bind a registry to such a suite.

- The live Base tax suite `base-mainnet-tax-token-v1` has no consent check. A pad suite needs its own deployment.
- A new hook needs a newly mined address with the same permission bits, new factory wiring, and a new suite entry.
- The factory imports the hook, so the factory and hook artifacts change. Export fresh artifacts and verify them through the [artifact trust procedure](../../../docs/TAX_TOKEN_SUITE_DEPLOYMENT.md#trusted-artifacts-and-operations-binding). `test/tax/TaxVerifier.t.sol` reads the exported bundle.

## Security invariants

- Only the exact reject word blocks a launch.
- Only the exact accept word creates a record.
- A missing answer never creates a record.
- The static call cannot change state.
- The gas check stops a caller from starving a rejecting policy.
- The check runs before the pool state write. A reject leaves no token, pool, or launch buy.

## Tests

`contracts/test/tax/TaxLaunchConsent.t.sol` covers:

- exact accept and reject words, missing policies, and hostile return data;
- state writes and bounded gas for hostile policies;
- low caller gas;
- the launch context with both currency orders and a native quote;
- the gas cost of an accepted record;
- an atomic launch buy with an accept and with a reject.

`contracts/test/pads/PadTaxPresetUpdate.t.sol` covers the pad vault as a policy.

## Activation prerequisites

**Warning:** Mainnet execution is human-only. Each deployment and configuration step needs its own exact-target approval.

- An independent contract review of `LaunchConsent.sol`, `ILaunchConsent.sol`, and the `TaxLaunchHook.sol` change.
- Approval of the hook change and of the fresh artifact bundle by the tax suite owner.
- A new suite deployment with a newly mined hook, verified through the [tax-suite deployment runbook](../../../docs/TAX_TOKEN_SUITE_DEPLOYMENT.md).
- A dividend exclusion and custody decision for that suite. Use the [exclusion procedure](../../../docs/TAX_TOKEN_DIVIDEND_EXCLUSIONS.md).
- A rehearsal of accepted, rejected, and silent policies on the deployed suite before activation.
