# Address book v2 — Push Chain Donut Testnet

**Generation `v3.1` (native mode)** · Chain ID `42101` · explorer [donut.push.network](https://donut.push.network) · deployed at block `23002281` · commit `685624e`
Toolchain: solc `0.8.26`, optimizer `833`, evm `cancun`, `via_ir` on, forge `1.5.1-stable`.

> Generated from `push_agw_contracts.json` and `external_agw_libraries.json` in this folder. Those are the source of truth; update them first.

> **This supersedes `deployments/address-book/` (v3.0).** Every address below is NEW. Nothing was upgraded in place — the v1 URP was not behind a proxy and could not be. The v1 book is retained, superseded, and universal-only; mandates granted against it do not carry over.

## Contracts we deploy

| Contract | Address | Size | Verified |
|---|---|---:|:---:|
| **`factoryProxy`** — **use this one** | [`0x00350B9DdC33da6eD19Fa2Ec9288fa63e5481B4E`](https://donut.push.network/address/0x00350B9DdC33da6eD19Fa2Ec9288fa63e5481B4E) | — | ✅ |
| `factoryLogic` (AGWFactory) | [`0xBee150eeC1813E79636Ad289d94cAcA9b1027175`](https://donut.push.network/address/0xBee150eeC1813E79636Ad289d94cAcA9b1027175) | 8,300 | ✅ |
| `walletImplementation` (PushAgentWallet) | [`0xB2AF9f131821114a8B1890424242CC27806c4a83`](https://donut.push.network/address/0xB2AF9f131821114a8B1890424242CC27806c4a83) | 11,626 | ✅ |
| **`urp`** — **the PROXY, address it here** | [`0xD03D50531d5803a49F4eC286D2EB6bcBbc5c0F22`](https://donut.push.network/address/0xD03D50531d5803a49F4eC286D2EB6bcBbc5c0F22) | — | ✅ |
| `urpImplementation` (URP `v1.0.0`) | [`0x07C978c96218b8347C0886915a409D6Ff8F7F500`](https://donut.push.network/address/0x07C978c96218b8347C0886915a409D6Ff8F7F500) | 12,134 | ✅ |
| `urpProxyAdmin` (ProxyAdmin) | [`0x9C7952558C9aF94D92185AB75eC5d4203FA3040f`](https://donut.push.network/address/0x9C7952558C9aF94D92185AB75eC5d4203FA3040f) | 926 | ⚠️ see below |
| `sessionValidator` (PushSessionValidator) | [`0x1aFcb6b3A2D2778355889be8ac35C06997040145`](https://donut.push.network/address/0x1aFcb6b3A2D2778355889be8ac35C06997040145) | 1,720 | ✅ |
| `sessionEngine` (SmartSession, fork `7dc20e4`) | [`0x9354d04e66386693CEAEC931bBDB7b1b369fF1A7`](https://donut.push.network/address/0x9354d04e66386693CEAEC931bBDB7b1b369fF1A7) | 22,581 | ✅ |

### What changed from v1

- **URP is now upgradeable.** It sits behind a `TransparentUpgradeableProxy`. **Always address it at the proxy** — `0xD03D…0F22`. The implementation is never called directly, and `version()` read *through the proxy* tells you which implementation is live.
- **URP grew 6,833 → 12,134 B.** Native mode adds the N1–N9 gate set, two storage mappings and the mode router. Runtime margin is still 12,442 B.
- **The wallet grew 10,515 → 11,626 B.** `grantMandate` now takes a `MandateType`, native mandates carry 1–8 actions, and `_gateAndDispatch` refuses the wallet and the engine as dispatch targets.
- **`grantMandate`'s selector changed.** Any v1 integration that encodes a grant must be updated to the two-argument form.
- **Policy `initData` changed shape** to `abi.encode(uint8 mode, bytes body)`. A v1-style bare `abi.encode(Config)` now reverts rather than mis-decoding.

### The ProxyAdmin verification note

`urpProxyAdmin` is **unverified on the explorer, and this is an explorer limitation rather than a deployment defect.** It is created by an inner `CREATE` from the `TransparentUpgradeableProxy` constructor; this Blockscout instance does not index internally-created contracts, reports `is_contract: false`, and refuses the submission with *"Address is not a smart-contract"*.

The chain disagrees, and was checked directly:

```
cast code   0x9C79…040f  ->  926 bytes
cast call   0x9C79…040f  'owner()(address)'  ->  0xa895…99C7
cast storage 0xD03D…0F22 <ERC-1967 admin slot>  ->  0x9C79…040f
```

It is stock OpenZeppelin `ProxyAdmin` v5.7.0, unmodified. **Keep this address — no URP upgrade is possible without it.**

## External dependencies — not deployed by this repo

| Dependency | Address | Used by | Verified |
|---|---|---|:---:|
| `universalGateway` | [`0x00000000000000000000000000000000000000C1`](https://donut.push.network/address/0x00000000000000000000000000000000000000C1) | URP, wallet | ✅ |
| `universalExecutorModule` | [`0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7`](https://donut.push.network/address/0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7) | URP | ⚠️ no code |
| `ed25519Precompile` | `0xEC00000000000000000000000000000000000001` | validator | ✅ |

All three re-measured live at block `23002669` during this deployment, not copied forward.

- **Gateway** is a proxy; its implementation `0x1e412939780f2b834dc42c7ac58d9f99888da659` carries selector `0x77b86bec` (`sendUniversalTxOutbound`). Our own mirrored signature hashes to the same value — compared, not assumed.
- **Executor module** still has no code on Donut. It gates `creditRevert` only, which Push core does not yet call, so nothing is broken today. **Improved since v1:** correcting it no longer means redeploying URP and regranting every mandate — it is now a proxy upgrade.
- **Ed25519 precompile** is codeless by design and called through a raw staticcall. A typed interface would insert an `extcodesize` check and revert on-chain.

## Admin

| | |
|---|---|
| Deployer | `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` |
| Factory default admin | `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` (deployer) |
| Admin transfer delay | 172,800 s (2 days) |
| **URP ProxyAdmin owner** | `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` (deployer) |
| Paused | no |

**There are now TWO upgrade authorities, and they are different powers:**

1. **Factory `DEFAULT_ADMIN_ROLE`** — authorises a UUPS upgrade of the factory logic. The only action that can strand counterfactually funded addresses.
2. **URP ProxyAdmin owner** — can replace every gate in the security boundary. URP's own NatSpec states this plainly: its guarantees hold subject to this admin not being malicious.

Both are the deployer EOA on testnet. A production deployment should hold each in a multisig, and **they should not be the same key.**

## Deployment transactions

| # | Contract | Tx |
|--:|---|---|
| 1 | SmartSession | [`0x7202f5d6…`](https://donut.push.network/tx/0x7202f5d63545f204d85aa23c6b474fabd70cf3a89aa44fd3a688157b4627d478) |
| 2 | PushSessionValidator | [`0x832885e4…`](https://donut.push.network/tx/0x832885e46be4282592bfacf0b469245ec6505390f0f6b3e930213188e2068e64) |
| 3 | URP (implementation) | [`0x08eda035…`](https://donut.push.network/tx/0x08eda035eec6c1f3ec54494a2d6f78146543c1b789db864e2916ae499ec7c6ee) |
| 4 | TransparentUpgradeableProxy → URP | [`0xc4b6d0f6…`](https://donut.push.network/tx/0xc4b6d0f67b0dc70a6cf9ec82323ed348d9d4ae9eb89dc7f4f327ffddd76260b5) |
| 5 | PushAgentWallet (implementation) | [`0x0d9cca46…`](https://donut.push.network/tx/0x0d9cca4600ee36a197bed9b14130ad0a26fdf37529c4c6fcdea0c3b073962f8c) |
| 6 | AGWFactory (logic) | [`0x927a456c…`](https://donut.push.network/tx/0x927a456cc85f1d6bfaf81e1c86399976ea0c8fec34ae1fc1eb5c0379c4b60c29) |
| 7 | ERC1967Proxy → AGWFactory | [`0x630742923…`](https://donut.push.network/tx/0x630742923416e1cb04a904aaa70b35dbd1bc0f13e384874bec460cf66f52ee0a) |

The `ProxyAdmin` has no deployment transaction of its own — it is created inside transaction 4.

## Live verification

Read back from the chain after deployment, at block `23002669`.

**URP, through the proxy:** `UNIVERSAL_GATEWAY_PC` → `0x…00C1` · `UNIVERSAL_EXECUTOR_MODULE` → `0x1419…D7d7` · `SESSION_ENGINE` → `0x9354…F1A7` · `version()` → `1.0.0`

**Wallet implementation, all four wiring views:** `sessionEngine` → `0x9354…F1A7` · `urp` → `0xD03D…0F22` *(the proxy)* · `sessionValidator` → `0x1aFc…0145` · `universalGateway` → `0x…00C1` · `accountId` → `push.agentwallet.1.0.0`

**Factory proxy:** `walletImplementation()` → `0xB2AF…4a83` · `defaultAdminDelay()` → `172800`

### Smoke test — a real wallet, not a simulation

`deployWallet("smoke-v2")` from the deployer EOA — [`0x321ac5d5…`](https://donut.push.network/tx/0x321ac5d5a0a6ad8fabc498187d6205f6c3684cc98dbc1161acb9bc16c3ea3159)

Clone [`0x199c5eF60b2619bdd4f0cc381e2754C13Be076De`](https://donut.push.network/address/0x199c5eF60b2619bdd4f0cc381e2754C13Be076De):

| Assertion | Result |
|---|---|
| `factory.isWallet(clone)` | `true` |
| `factory.ownerOf(clone)` | deployer |
| `clone.owner()` | deployer |
| `clone.factory()` | `0x0035…1B4E` |
| `clone.urp()` | `0xD03D…0F22` |
| `clone.accountId()` | `push.agentwallet.1.0.0` |
| `clone.isModuleInstalled(1, engine)` | `true` |

This exercises the whole stack: the factory registry, the clone's 40-byte immutable args, the URP pin, and the engine installed as the wallet's sole validator module.
