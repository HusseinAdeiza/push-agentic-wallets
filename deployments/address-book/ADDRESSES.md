# Address book — Push Chain Donut Testnet

**Chain ID `42101`** · explorer [donut.push.network](https://donut.push.network) · deployed at block `22631775` · commit `c684505`
Toolchain: solc `0.8.26`, optimizer `833`, evm `cancun`, `via_ir` on.

> Generated from `push_agw_contracts.json` and `external_agw_libraries.json`. Those are the source of truth; update them first.

## Contracts we deploy

| Contract | Address | Size | Verified |
|---|---|---:|:---:|
| **`factoryProxy`** — **use this one** | [`0xF1A131571f89fD06890576e6cD0154114ACBBc8b`](https://donut.push.network/address/0xF1A131571f89fD06890576e6cD0154114ACBBc8b) | — | ✅ |
| `factoryLogic` (AGWFactory) | [`0x4b1dC2bcF9de73d60e7c38E864730866439A368F`](https://donut.push.network/address/0x4b1dC2bcF9de73d60e7c38E864730866439A368F) | 8,300 | ✅ |
| `walletImplementation` (PushAgentWallet) | [`0x959ED7f6943bdd56B3a359BAE0115fef4aa07e17`](https://donut.push.network/address/0x959ED7f6943bdd56B3a359BAE0115fef4aa07e17) | 10,515 | ✅ |
| `urp` (URP) | [`0x79F07D379BdC26468E48025a61bC955909522c1D`](https://donut.push.network/address/0x79F07D379BdC26468E48025a61bC955909522c1D) | 6,833 | ✅ |
| `sessionValidator` (PushSessionValidator) | [`0x5A59a5Ac94d5190553821307F98e4673BF3c4a1D`](https://donut.push.network/address/0x5A59a5Ac94d5190553821307F98e4673BF3c4a1D) | 1,720 | ✅ |
| `sessionEngine` (SmartSession, fork `7dc20e4`) | [`0x7540f9a59693d51CFB4A3727141eAE4836F96749`](https://donut.push.network/address/0x7540f9a59693d51CFB4A3727141eAE4836F96749) | 22,581 | ✅ |

## External dependencies — not deployed by this repo

| Dependency | Address | Used by | Verified |
|---|---|---|:---:|
| `universalGateway` | [`0x00000000000000000000000000000000000000C1`](https://donut.push.network/address/0x00000000000000000000000000000000000000C1) | URP, wallet | ✅ |
| `universalExecutorModule` | [`0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7`](https://donut.push.network/address/0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7) | URP | ⚠️ no code |
| `ed25519Precompile` | `0xEC00000000000000000000000000000000000001` | validator | ✅ |

- **Gateway** is a proxy; its implementation `0x1e412939780f2b834dc42c7ac58d9f99888da659` carries selector `0x77b86bec` (`sendUniversalTxOutbound`), which is what our struct mirror was checked against.
- **Executor module** has no code on Donut (balance 0, nonce 0). The address is confirmed correct, and it gates `creditRevert` only — which Push core does not yet call — so nothing is broken today. It is a URP immutable on a non-upgradeable contract, so correcting it later would mean redeploying URP and regranting every mandate.
- **Ed25519 precompile** is codeless by design and called through a raw staticcall. Verified live: a known-good vector returns `1`, the same vector with one byte flipped returns `0`.

## Admin

| | |
|---|---|
| Deployer | `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` |
| Factory default admin | `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7` (deployer) |
| Admin transfer delay | 172,800 s (2 days) |
| Paused | no |

The admin's one real power is authorising a UUPS upgrade of the factory logic — the only action that can strand counterfactually funded addresses. A production deployment should hold this in a multisig, not an EOA.

## Deployment transactions

| # | Contract | Tx |
|--:|---|---|
| 1 | SmartSession | [`0x6ddc2314…`](https://donut.push.network/tx/0x6ddc23146f000905f64dd2e37bb39a89f088380a207664283fbb7b1209ac13b4) |
| 2 | PushSessionValidator | [`0xbc9bc542…`](https://donut.push.network/tx/0xbc9bc542b077c343240bad63e664ccb98f37714e5cf3ff93f69f2ccb508979fb) |
| 3 | URP | [`0x27948df3…`](https://donut.push.network/tx/0x27948df316e91f8c78eb1a79d7d632c0de7a74f59cb81b44cf799fd1c0ffce00) |
| 4 | PushAgentWallet | [`0x6c9237d0…`](https://donut.push.network/tx/0x6c9237d0da0ae0d73c01a06bf8426d4905652232d42f8e840ebc90ace5d60541) |
| 5 | AGWFactory | [`0x969681a9…`](https://donut.push.network/tx/0x969681a9c5ce00c36764d47db39ff18877b037955a571e6437aca39a156d9ab2) |
| 6 | ERC1967Proxy | [`0x36da0336…`](https://donut.push.network/tx/0x36da03367d53cf648e2646f864426017f79d459a4c5c81c5b327d2c803dbea43) |

## Notes for integrators

- **Only `factoryProxy` is user-facing.** It is permanent and survives factory-logic upgrades. Never address `factoryLogic` directly.
- **`sessionValidator` is pinned for the life of this environment.** Its address is an input to every permission id, so a second validator does not migrate anything — it creates a parallel id namespace and invalidates every existing mandate.
- **The wallet address derivation is frozen.** The salt formula and the 40-byte immutable-args encoding (owner `0..19`, factory `20..39`) may never change, because counterfactual funding is supported and has no recovery path. A new wallet version ships as a new factory deployment.
