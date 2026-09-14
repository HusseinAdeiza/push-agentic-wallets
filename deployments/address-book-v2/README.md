# Address book v2 — generation `v3.1` (native mode)

Committed, permanent records of where the system lives on each network. Unlike `deployments/<chainId>.json` — which the deploy script rewrites on every run and which is gitignored — these files are edited deliberately and reviewed.

**This book supersedes `deployments/address-book/`.** That one describes generation v3.0 and is retained as history: it is universal-only, its URP is not upgradeable, and mandates granted against it do not carry over. Read v1 only when investigating something that happened before 2026-09-10.

| file | holds |
|---|---|
| `push_agw_contracts.json` | the contracts this repo deploys, plus both proxies and the ProxyAdmin |
| `external_agw_libraries.json` | dependencies this repo does **not** deploy, each with a measured verification status |
| `ADDRESSES.md` | the human-readable view, generated from the two above |

## The three addresses that matter to an integrator

**`factoryProxy` is the address integrations use.** Permanent and user-facing: it goes into the SDK, monitoring and every integration, and it does not change when the factory logic is upgraded. Nothing should ever address `factoryLogic` directly.

**`urp` is the PROXY, not the implementation.** New in this generation. Every wallet pins the proxy address as its canonical policy, so it must never change; the implementation behind it may. Read `version()` *through the proxy* to learn which implementation is live. Addressing `urpImplementation` directly gets you a contract with no configuration — its initialiser is disabled by construction.

**`sessionValidator` is pinned for the life of an environment.** Its address is an input to every permission id, so deploying a second validator does not migrate anything — it creates a parallel id namespace and invalidates every existing mandate.

## What is new in v2, and what it costs you

- **URP is upgradeable.** That is a deliberate trade, stated in URP's own NatSpec: its guarantees now hold *subject to the ProxyAdmin owner not being malicious*. An owner able to install new logic can rewrite every gate. In exchange, a wrong trust anchor is now a proxy upgrade rather than a full redeploy plus regranting every mandate.
- **Two upgrade authorities now exist** — the factory's `DEFAULT_ADMIN_ROLE` and the URP ProxyAdmin owner. They are different powers over different contracts. Both are the deployer EOA on testnet; production should hold each in a multisig, and they should not be the same key.
- **`grantMandate`'s selector changed** — it takes a `MandateType` second argument. Every v1 integration that encodes a grant breaks and must be updated.
- **Policy `initData` changed shape** to `abi.encode(uint8 mode, bytes body)`. A v1-style bare `abi.encode(Config)` reverts rather than mis-decoding into a live config.

**The wallet implementation's derivation is still frozen.** The salt formula and the 40-byte immutable-args encoding may never change, because counterfactual funding is a supported flow with no recovery path. A new wallet version means a new factory deployment, not a new implementation behind the same one — which is exactly what this generation is.

## Reading the verification fields

Every entry in `external_agw_libraries.json` carries `verified` plus the evidence behind it. `verified: false` means the address is configured and believed correct but has no code on that chain — read the `impact` field before assuming it is harmless.

The same applies inside `push_agw_contracts.json`. One entry — `urpProxyAdmin` — is `verified: false` with a `verificationBlocker` field explaining why: it is created by an inner `CREATE`, which this Blockscout instance does not index, so the explorer refuses the submission even though the chain reports 926 bytes of code and answers `owner()` correctly. That is an explorer limitation, recorded rather than hidden. Every other contract in the set is verified on the explorer.
