# Address book

Committed, permanent records of where the system lives on each network. Unlike `deployments/<chainId>.json` — which the deploy script rewrites on every run and which is gitignored — these files are edited deliberately and reviewed.

| file | holds |
|---|---|
| `push_agw_contracts.json` | the five contracts this repo deploys, plus the factory proxy |
| `external_agw_libraries.json` | dependencies this repo does **not** deploy, each with a measured verification status |

**`factoryProxy` is the address integrations use.** It is permanent and user-facing: it goes into the SDK, monitoring and every integration, and it does not change when the factory logic is upgraded. Nothing should ever address `factoryLogic` directly.

**`sessionValidator` is pinned for the life of an environment.** Its address is an input to every permission id, so deploying a second validator does not migrate anything — it creates a parallel id namespace and invalidates every existing mandate.

**The wallet implementation's derivation is frozen.** The salt formula and the 40-byte immutable-args encoding may never change, because counterfactual funding is a supported flow with no recovery path. A new wallet version means a new factory deployment, not a new implementation behind the same one.

Every entry in `external_agw_libraries.json` carries `verified` plus the evidence behind it. `verified: false` means the address is configured and believed correct but has no code on that chain — read the `impact` field before assuming it is harmless.
