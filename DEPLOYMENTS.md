# Deployments

Every Place Launch deployment gets a row here. The hub contracts (`PlaceHub`, `PlaceConfig`) live in
[`place-web/contracts/DEPLOYMENTS.md`](https://github.com/Maksyaka12/place-web/blob/dev/contracts/DEPLOYMENTS.md).

## Base Sepolia (84532)

Deployed 2026-11-13, blocks 58275925–58276026, commit `539251b` + `script/L2Sepolia.s.sol` (stage L2), Foundry 1.8.5,
solc 0.8.26 (via-IR, 200 runs). Version **0.1.0-testnet** (not audited).

| Contract | Address | Basescan |
|---|---|---|
| PlaceLaunchFactory | [`0xf3348E8bC017Aae708c278da3e1CBC1A8AE6fC55`](https://sepolia.basescan.org/address/0xf3348E8bC017Aae708c278da3e1CBC1A8AE6fC55) | not verified (see below); exact match on [Sourcify](https://repo.sourcify.dev/84532/0xf3348E8bC017Aae708c278da3e1CBC1A8AE6fC55) |
| PlaceLaunchHook | [`0xC6C32A05b5392a51f4eac82Fa163979F5166aAcC`](https://sepolia.basescan.org/address/0xC6C32A05b5392a51f4eac82Fa163979F5166aAcC#code) | verified |
| FeeEscrow | [`0xaaA8458ED82EE3EC69Fd0cFda052882Eb807C0eA`](https://sepolia.basescan.org/address/0xaaA8458ED82EE3EC69Fd0cFda052882Eb807C0eA#code) | verified |
| PlaceCreatorVault (implementation) | [`0x7B7D1de1ca7f97AcD29d92C8F04BCC38d0fC33e1`](https://sepolia.basescan.org/address/0x7B7D1de1ca7f97AcD29d92C8F04BCC38d0fC33e1#code) | verified |
| XRecipientRegistry | [`0x852C1541091f7BAf0DD4547FCEe2e7934102c68F`](https://sepolia.basescan.org/address/0x852C1541091f7BAf0DD4547FCEe2e7934102c68F#code) | verified |
| PlaceLaunchBuyAdapter | [`0xAc68AF3ADF53706cd75A641220ae2b8Bf9B3E72B`](https://sepolia.basescan.org/address/0xAc68AF3ADF53706cd75A641220ae2b8Bf9B3E72B#code) | verified |
| AnnouncementRegistry | [`0x7fEFD265C317E9Bd573eB7A9389d00F2E2EA6888`](https://sepolia.basescan.org/address/0x7fEFD265C317E9Bd573eB7A9389d00F2E2EA6888#code) | verified |
| PlaceLaunchTokenDeployer | [`0xCeA99dc4Fde9c22e6Ce071720A7aeA1772d0931d`](https://sepolia.basescan.org/address/0xCeA99dc4Fde9c22e6Ce071720A7aeA1772d0931d#code) | verified |
| PlaceLaunchOperations (library) | [`0x1f06Bd7575e46831C6bFEc1C7371716dEF8AEC5E`](https://sepolia.basescan.org/address/0x1f06Bd7575e46831C6bFEc1C7371716dEF8AEC5E#code) | verified |
| PlaceLaunchValidation (made by the factory) | [`0x415d02dc1435fF9E56298ed49a3EBC3FF5D1421d`](https://sepolia.basescan.org/address/0x415d02dc1435fF9E56298ed49a3EBC3FF5D1421d#code) | verified |

External: Uniswap v4 PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`, PlaceHub 1.0.0
`0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1`, B20 factory precompile `0xB20f…0000`.

The factory links the `PlaceLaunchOperations` library at deploy time. The local bytecode matches the deploy
transaction byte for byte and Sourcify gives an exact match, but Basescan rejects the standard-JSON submission with
`--libraries` ("deployment bytecode does NOT match"). Open for L3.

Settings:

| Setting | Value |
|---|---|
| Owner of the factory and the X registry | `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` (two-step, accepted 2026-11-13: [factory](https://sepolia.basescan.org/tx/0x3145b04a3ce339e5a31dd1666c3bb7065729ec5da24a4ed1f33f0206da5363e8), [X registry](https://sepolia.basescan.org/tx/0x4b3650ab15304f1342a5b42f77d1ac42b94e5e21b793932feb38691c629d33b3)) |
| Platform fee recipient (25%, anti-snipe surplus, launch fee) | `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` |
| Launch fee | 0.0005 ETH |
| Launches | enabled |
| Pairs (start tick, token0 frame) | ETH −200 600, USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` −400 600 |
| Rewards minimum (testnet, low on purpose) | 0.0001 ETH, 0.1 USDC |
| Vault settings | hub PlaceHub 1.0.0, X registry above, interval 7 days, rules [`rules/launch-holders-v1.json`](rules/launch-holders-v1.json) (`rulesHash` `0x3c661671…a015`) |
| X verifier | not set (bindings paused until L5) |
| Hub fee for the L2 test tokens | 0 via `PlaceConfig.setTargetFee` ([B20](https://sepolia.basescan.org/tx/0xeed97e470f67dc58eb6c50fc6e69d1ade74cfa3886075148a8953245c784c257), [ERC-20](https://sepolia.basescan.org/tx/0x5f7408041f5d570f0520fe85070b9ecd8aa0366f24e42218a6f7ff7773f707a1)) |

Deployer: test wallet `0x6bB35f78A2FE7fAD0809D849A99B2E2b1C5e3134` (21 transactions, ≈ 0.00014 ETH). It has no role
left once ownership is accepted: the hook and token deployer were wired once and cannot be rewired.

L2 test launches (live run `script/L2LiveRun.s.sol`, data in [`deployments/base-sepolia-l2-run.json`](deployments/base-sepolia-l2-run.json)):

| Token | Kind / pair | Creator vault | Hub campaign |
|---|---|---|---|
| [`0xb200000000000000000000edee389ab594913E01`](https://sepolia.basescan.org/token/0xb200000000000000000000edee389ab594913E01) PL2B | B20 / ETH | [`0x18B74a6AE4230454A46b1CA502B57BAc6be072CB`](https://sepolia.basescan.org/address/0x18B74a6AE4230454A46b1CA502B57BAc6be072CB) | #1 |
| [`0xB4F38E468f983611a1fB5574989Be0E6a94Efe01`](https://sepolia.basescan.org/token/0xB4F38E468f983611a1fB5574989Be0E6a94Efe01) PL2E | ERC-20 / USDC | [`0xD8Aca3846a15a99a0dd92153164eF9D22292e013`](https://sepolia.basescan.org/address/0xD8Aca3846a15a99a0dd92153164eF9D22292e013) | #2 |

## Base (8453)

Not deployed. Needs the delta audit first (LAUNCH.md §7.4); owner and fee recipient there must be the platform Safe.
