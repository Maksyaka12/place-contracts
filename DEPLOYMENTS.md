# Deployments

Every Place Launch deployment gets a row here. The hub contracts (`PlaceHub`, `PlaceConfig`) live in
[`place-web/contracts/DEPLOYMENTS.md`](https://github.com/Maksyaka12/place-web/blob/dev/contracts/DEPLOYMENTS.md).

## Base Sepolia (84532) — 0.3.0-testnet (current)

Deployed 2026-11-16, blocks 59718515–59718596, [`script/V6Sepolia.s.sol`](script/V6Sepolia.s.sol) (wraps
[`script/DeployPlaceLaunch.s.sol`](script/DeployPlaceLaunch.s.sol)), Foundry 1.8.5, solc 0.8.26 (via-IR, 200 runs).
30 transactions, all successful, gas ≈ 0.000168 ETH. Version **0.3.0-testnet** (not audited): Standard and Economy
launches, five tax baskets, daily rewards through `PlaceRewardsDistributor`, `PlaceCommunityVault`, burn in the token.
All 14 contracts verified on Basescan (the factory, its library and `PlaceLaunchValidation` too).
Machine-readable: [`deployments/base-sepolia-0.3.0.json`](deployments/base-sepolia-0.3.0.json).

| Contract | Address |
|---|---|
| PlaceLaunchFactory | [`0x5AC1d5Bf12017502242d45ae9F519DEdce15E453`](https://sepolia.basescan.org/address/0x5AC1d5Bf12017502242d45ae9F519DEdce15E453#code) |
| PlaceLaunchHook | [`0x228f6Dc153a6a164591B240941b819acF8862acC`](https://sepolia.basescan.org/address/0x228f6Dc153a6a164591B240941b819acF8862acC#code) |
| FeeEscrow | [`0x892c643A63DE6e7B9b694Bd10B5D4304d8E68ea4`](https://sepolia.basescan.org/address/0x892c643A63DE6e7B9b694Bd10B5D4304d8E68ea4#code) |
| PlaceRewardsDistributor | [`0x793da842A6c43A0429b996b97a03246771eCA6eD`](https://sepolia.basescan.org/address/0x793da842A6c43A0429b996b97a03246771eCA6eD#code) |
| PlaceCreatorVault (implementation) | [`0xF7C91c7642FFfC8131c60A78685D6741a2539a98`](https://sepolia.basescan.org/address/0xF7C91c7642FFfC8131c60A78685D6741a2539a98#code) |
| PlaceCommunityVault (implementation) | [`0xc2Bae2cd4c26Ce46860fD7749dec0ADAcAd083dc`](https://sepolia.basescan.org/address/0xc2Bae2cd4c26Ce46860fD7749dec0ADAcAd083dc#code) |
| PlaceRewardTokenRegistry | [`0xF2941258d77903409DEc6746A9668Aa84D3899A0`](https://sepolia.basescan.org/address/0xF2941258d77903409DEc6746A9668Aa84D3899A0#code) |
| PlaceStaking (GPL-3.0-only) | [`0x693dd75b148a12c3d90935ea6354C5d1e2629283`](https://sepolia.basescan.org/address/0x693dd75b148a12c3d90935ea6354C5d1e2629283#code) |
| XRecipientRegistry | [`0xD5ede8771fAd4DbB1146A15213a8db37773A14eD`](https://sepolia.basescan.org/address/0xD5ede8771fAd4DbB1146A15213a8db37773A14eD#code) |
| PlaceLaunchBuyAdapter | [`0x396f2875AF9771B33F33d9a19bf97919737FF0fb`](https://sepolia.basescan.org/address/0x396f2875AF9771B33F33d9a19bf97919737FF0fb#code) |
| AnnouncementRegistry | [`0x3E390eE17009b083d23420557822f90E0da86E87`](https://sepolia.basescan.org/address/0x3E390eE17009b083d23420557822f90E0da86E87#code) |
| PlaceLaunchTokenDeployer | [`0xDF75125cc16921aA7b61714Fd1E5D143Da8D7c66`](https://sepolia.basescan.org/address/0xDF75125cc16921aA7b61714Fd1E5D143Da8D7c66#code) |
| PlaceLaunchOperations (library) | [`0x1de22AE74da98cD5f3DD55A1cAC31140431b1776`](https://sepolia.basescan.org/address/0x1de22AE74da98cD5f3DD55A1cAC31140431b1776#code) |
| PlaceLaunchValidation (made by the factory) | [`0x2A339110AcB956108C94e9bED6efC24f69051E24`](https://sepolia.basescan.org/address/0x2A339110AcB956108C94e9bED6efC24f69051E24#code) |

External: Uniswap v4 PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`, B20 factory precompile.
New launches no longer use PlaceHub.

| Setting | Value |
|---|---|
| Standard | 1% per swap: 0.3% platform (30%), 0.7% creator vault (70%) |
| Economy | buy and sell tax 1–5% each; 30% of the tax to the platform (at least 0.3%, at most 1.5% of the trade); the rest split into creator, holders, traders, burn and community baskets |
| Platform fee recipient (30%, anti-snipe surplus, launch fee 0.0005 ETH, 5% stream fee, 5% staking fee) | `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` |
| Owner of the factory, X registry, reward-token registry, rewards distributor and staking | pending: `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` (two-step, `acceptOwnership` not called yet); until then the deployer `0x6bB35f78A2FE7fAD0809D849A99B2E2b1C5e3134` |
| Rewards publisher (posts the daily roots) | `0x0851B25D5D5b38BA260258A1520aff53E72c757d` |
| Pairs (start tick, token0 frame) | ETH −200 600, USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` −400 600 |
| Reward-token routes | ETH ⇄ USDC through the v4 ETH/USDC 1% pool (fee 10000, spacing 200, no hook); max price impact 5% per hop (mainnet plan: 1%) |
| Default campaign | after 30 days without fund spending, 30 daily epochs; minimum 0.0001 ETH / 0.1 USDC (mainnet plan: 0.05 ETH) |
| Funded streams (`createStream`, community campaigns) | 5% fee |
| X verifier | not set |

Live run ([`script/V6LiveRun.s.sol`](script/V6LiveRun.s.sol), data in `deployments/base-sepolia-v6-*.json`). Creator
`0x6bB3…3134`, traders `0xc3fa…B892`, `0x35a4…2B0d`, `0xC421…61B4`.

| Token | Type / pair | Economics | Creator vault | Community vault |
|---|---|---|---|---|
| [`0xb20000000000000000000005210e829C533BDe01`](https://sepolia.basescan.org/token/0xb20000000000000000000005210e829C533BDe01) PV6S | Standard, B20 / ETH | 1%, all 0.7% to the creator | [`0x62E2…af69`](https://sepolia.basescan.org/address/0x62E2EbDaC9e2bfbfcd53cf013932f091525eaf69) | — |
| [`0x32A55Dbc7B4d021B004D8C8ff25898dB0fF05e01`](https://sepolia.basescan.org/token/0x32A55Dbc7B4d021B004D8C8ff25898dB0fF05e01) PV6E | Economy, ERC-20 / USDC | buy 3%, sell 5%; creator 30%, holders 25%, traders 20%, burn 15%, community 10%; holders ≥ 10,000 PV6E, traders ≥ 0.1 USDC a day; rewards in ETH | [`0xCE8A…CA42`](https://sepolia.basescan.org/address/0xCE8Ad9fd4F0c83bbfc33686F1aeeA7473f4FCA42) | [`0x80d6…664E`](https://sepolia.basescan.org/address/0x80d679006E03917276C5D5Be50e8C01Bee38664E) |

- Dev buys: [0.0003 ETH → 152,828 PV6S](https://sepolia.basescan.org/tx/0x89b5ad8b9c7afdae3381e02739f5ea9ceca6c9628c8c0b0180e661f38db65640), [0.5 USDC → 120,964 PV6E](https://sepolia.basescan.org/tx/0x1e7cd11cb5d1b2ab93a974469162d8f9fae3e1646c72577bbba2d0b5f79cffaa); trades from four wallets through the Universal Router.
- [`FeeEscrow.burn`](https://sepolia.basescan.org/tx/0x38668e29a2eb0821bb0e2f1ed3f4cf41b1680724acfb9918d74237866233ad4d): 2,173.1 PV6E to `0x…dEaD`.
- Community pool: [holders campaign](https://sepolia.basescan.org/tx/0xb466383cf4339650d6a62aca68aa470293ec27c71340f399d2c2fec48441bf22) in USDC for 2 days (minimum 20,000 PV6E) and a [staking program](https://sepolia.basescan.org/tx/0x26df4bb2cb2b2555bb34c447692d54a601616e78af6280494d8a7cac422b45fd) paid in PV6E.
- Day 2026-11-16: [`closeStreams`](https://sepolia.basescan.org/tx/0x39b9839ea49afca1866b21b20053111f8a93ada1bfeb4b493af32ad376902cf8) (USDC → ETH in the same call), [`publishRoots`](https://sepolia.basescan.org/tx/0xfb4a0d9b6dc148cc5b6de7873e6d4075a7359cfb856d42f36cf5135121176a87) for the three streams, then `claimMany` from each of the four wallets.

## Base Sepolia (84532) — 0.2.0-testnet (superseded)

Deployed 2026-11-14, blocks 58740635–58740714, [`script/L5Sepolia.s.sol`](https://github.com/Maksyaka12/place-contracts/blob/d6961c5/script/L5Sepolia.s.sol)
(stage L5, new economy), Foundry 1.8.5, solc 0.8.26 (via-IR, 200 runs). 27 transactions, all successful, gas
≈ 0.000175 ETH. Version **0.2.0-testnet** (not audited). All 12 contracts verified on Basescan (the factory too).
Machine-readable: [`deployments/base-sepolia-0.2.0.json`](deployments/base-sepolia-0.2.0.json).
The 0.2.0 sources and scripts are at commit [`d6961c5`](https://github.com/Maksyaka12/place-contracts/tree/d6961c5).

| Contract | Address |
|---|---|
| PlaceLaunchFactory | [`0xEAAaA64419Bade6977Bf491a9828b68357D47D63`](https://sepolia.basescan.org/address/0xEAAaA64419Bade6977Bf491a9828b68357D47D63#code) |
| PlaceLaunchHook | [`0x1206be7D6eFf2Fc2f15A6BdfC88Cfbd697Ea2Acc`](https://sepolia.basescan.org/address/0x1206be7D6eFf2Fc2f15A6BdfC88Cfbd697Ea2Acc#code) |
| FeeEscrow | [`0x4244AFad1c2789E9da79a97E8Ee001Ad744D1dC2`](https://sepolia.basescan.org/address/0x4244AFad1c2789E9da79a97E8Ee001Ad744D1dC2#code) |
| PlaceCreatorVault (implementation) | [`0x170349bc94Ad1D7f62dc82694D4C4D413649d4B6`](https://sepolia.basescan.org/address/0x170349bc94Ad1D7f62dc82694D4C4D413649d4B6#code) |
| PlaceRewardTokenRegistry | [`0x092C21C933911A5205588EB1d7592Da358108D5C`](https://sepolia.basescan.org/address/0x092C21C933911A5205588EB1d7592Da358108D5C#code) |
| PlaceStaking (GPL-3.0-only) | [`0x1390719DDD7A3F597AbCdD8B48BcC7dc465220dF`](https://sepolia.basescan.org/address/0x1390719DDD7A3F597AbCdD8B48BcC7dc465220dF#code) |
| XRecipientRegistry | [`0x1eB2D5512f0d7A413ACeDb1b2252A9Cbb003E4d3`](https://sepolia.basescan.org/address/0x1eB2D5512f0d7A413ACeDb1b2252A9Cbb003E4d3#code) |
| PlaceLaunchBuyAdapter | [`0xbD0c4F2DAb3176159B99d0a2c1F3F74480F3e19C`](https://sepolia.basescan.org/address/0xbD0c4F2DAb3176159B99d0a2c1F3F74480F3e19C#code) |
| AnnouncementRegistry | [`0xD9cd4D6B5F49daD3d8CfDf713f9D31A3cF71d9fF`](https://sepolia.basescan.org/address/0xD9cd4D6B5F49daD3d8CfDf713f9D31A3cF71d9fF#code) |
| PlaceLaunchTokenDeployer | [`0xE5eD380Daa6bA73755C2940f5e0be86887dAE47f`](https://sepolia.basescan.org/address/0xE5eD380Daa6bA73755C2940f5e0be86887dAE47f#code) |
| PlaceLaunchValidation (made by the factory) | [`0x85A3163b8460B88FA755171f8576838704600647`](https://sepolia.basescan.org/address/0x85A3163b8460B88FA755171f8576838704600647#code) |

External: Uniswap v4 PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`, PlaceHub 1.0.0
`0x493F55975Bff2e4f111BAd8D51637F3b9763Bdd1` (default fee 5%, no per-token override needed), B20 factory precompile.

| Setting | Value |
|---|---|
| Fee split | 1% per swap: 0.3% platform (30%), 0.7% creator vault (70%) |
| Platform fee recipient (30%, anti-snipe surplus, launch fee, 5% staking fee) | `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` |
| Owner of the factory, X registry, reward-token registry and staking | `0x9F687A81012e8039679b43BD7A910b5Cf4bb6fC4` (two-step, accepted 2026-11-14 with `place-deployer`) |
| Pairs (start tick, token0 frame) | ETH −200 600, USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` −400 600 |
| `process()` (testnet, frozen per launch) | every 1 hour; burn cap 0.0001 ETH / 0.1 USDC per call (mainnet plan: 1 day, 0.01 ETH) |
| Default campaign | after 30 days without fund spending; minimum 0.0001 ETH / 0.1 USDC (mainnet plan: 0.05 ETH) |
| Fund campaigns | PlaceHub 1.0.0, rules [`rules/launch-holders-v2.json`](rules/launch-holders-v2.json) (`rulesHash` `0x43ea5fcc…e8c4`) |
| Reward-token routes | ETH ⇄ USDC through the v4 ETH/USDC 1% pool (fee 10000, spacing 200, no hook); max price impact 5% per hop (mainnet plan: 1%) |
| PlaceStaking fee | 5% (version 1) |
| X verifier | not set |

L5 live run ([`script/L5LiveRun.s.sol`](https://github.com/Maksyaka12/place-contracts/blob/d6961c5/script/L5LiveRun.s.sol), data in `deployments/base-sepolia-l5-*.json`):

| Token | Kind / pair | Economics | Creator vault | Fund spent on |
|---|---|---|---|---|
| [`0xB2000000000000000000003783b3b582C63bBe01`](https://sepolia.basescan.org/token/0xB2000000000000000000003783b3b582C63bBe01) PL5B | B20 / ETH | burn 25%, community 50%, creator 25% | [`0x3abC…dd51`](https://sepolia.basescan.org/address/0x3abC6610532739B3f660DDD3289882234cE9dd51) | hub campaign #3 in USDC (swap ETH → USDC), staking program in PL5B |
| [`0x68ccDF4342575a5583A1eC1e343531C653143e01`](https://sepolia.basescan.org/token/0x68ccDF4342575a5583A1eC1e343531C653143e01) PL5E | ERC-20 / USDC | burn 20%, community 40%, creator 40% | [`0x6E6A…3316`](https://sepolia.basescan.org/address/0x6E6A1297cFE21d30C1654675AA53E819E46D3316) | hub campaign #4 in PL5E (swap USDC → PL5E), staking program in USDC |

## Base Sepolia (84532) — 0.1.0-testnet (superseded)

Deployed 2026-11-13, blocks 58275925–58276026, stage L2, Foundry 1.8.5,
solc 0.8.26 (via-IR, 200 runs). Version **0.1.0-testnet** (not audited).
The 0.1.0 sources are the ones verified on Basescan and Sourcify; this repository keeps the current release.

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
`--libraries` ("deployment bytecode does NOT match").

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

L2 test launches (live run, data in [`deployments/base-sepolia-l2-run.json`](deployments/base-sepolia-l2-run.json)):

| Token | Kind / pair | Creator vault | Hub campaign |
|---|---|---|---|
| [`0xb200000000000000000000edee389ab594913E01`](https://sepolia.basescan.org/token/0xb200000000000000000000edee389ab594913E01) PL2B | B20 / ETH | [`0x18B74a6AE4230454A46b1CA502B57BAc6be072CB`](https://sepolia.basescan.org/address/0x18B74a6AE4230454A46b1CA502B57BAc6be072CB) | #1 |
| [`0xB4F38E468f983611a1fB5574989Be0E6a94Efe01`](https://sepolia.basescan.org/token/0xB4F38E468f983611a1fB5574989Be0E6a94Efe01) PL2E | ERC-20 / USDC | [`0xD8Aca3846a15a99a0dd92153164eF9D22292e013`](https://sepolia.basescan.org/address/0xD8Aca3846a15a99a0dd92153164eF9D22292e013) | #2 |

## Base (8453)

Not deployed. Needs an audit first; owner and fee recipient there must be the platform Safe.
