# Push Agentic Wallet — contracts

ERC-7579 smart accounts on Push Chain that let an autonomous agent execute bounded, cross-chain actions on a user's behalf **without ever taking custody of their funds**.

> ## Architecture v3 — implementation starting from a clean slate
>
> The v1 and v2 implementations have been **removed from this repository**. What remains under `src/` is only what v3 carries forward. Nothing here describes a design that is no longer current.
>
> ### 👉 Start at [`docs-internal/v3-architecture-docs/README.md`](./docs-internal/v3-architecture-docs/README.md)
>
> That file is the single entry point: what we are building, what to read in what order, and where the build specifications live. **Read it before writing any code.**

---

## The five contracts

| Contract | Status |
| --- | --- |
| `AGWFactory` | **Built** — `src/AGWFactory.sol`; creates agent wallets at addresses computable before deployment |
| `AGW` (Agentic Wallet) | **Built** — `src/AGW.sol`; holds funds; an unrestricted owner door and a fully checked agent door |
| `UniversalRulesPolicy` (URP) | **Built** — `src/policies/UniversalRulesPolicy.sol`; the only novel contract: opens the cross-chain payload and enforces every limit |
| `AgentValidator` | **Carried forward** — `src/validators/AgentValidator.sol`, stateless sender validator |
| `SmartSession` | **Adopted unmodified** — `lib/smartsessions/`, the permission engine |

## What is in `src/` today

```
src/AGW.sol, src/AGWFactory.sol             the wallet and its factory
src/policies/UniversalRulesPolicy.sol       URP — the rules policy (three rulebooks)
src/validators/AgentValidator.sol           the session validator
src/libraries/                              Types.sol, Errors.sol, PushChainLib, OwnerAuthLib,
                                            ModeLib, ExecutionLib
src/interfaces/                             IAGW, IAGWInit, IAGWFactory, IUniversalRulesPolicy,
                                            IAgentValidator, gateway + module interfaces
```

Naming follows the core/gateway standard: see `docs-internal/sdk-first-changes/N-nomenclature_prd.md`.

Everything else is written fresh from the specifications in `docs-internal/v3-architecture-docs/v3-prds/`.

## Toolchain

`solc 0.8.26` · `evm_version = cancun` · `via_ir = true`. **Cancun is required** — the code uses `MCOPY`; lowering the EVM target breaks it silently at deploy time rather than loudly at compile time.

```bash
forge build
forge test
forge fmt
```

`lib/` holds the adopted dependencies: `smartsessions` (a pinned fork — treat any upgrade as a migration), OpenZeppelin 5.7.0, and the vendored ERC-7579 / ERC-4337 / solady sources that `smartsessions` needs. **The OpenZeppelin *upgradeable* package is deliberately not vendored.**

## Public documentation

Written after the implementation lands, not before.
