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
| `AGWFactory` | **To build** — creates agent wallets at addresses computable before deployment |
| `PushAgentWallet` | **To build** — holds funds; an unrestricted owner door and a fully checked agent door |
| `UCEP` | **To build** — the only novel contract: opens the cross-chain payload and enforces every limit |
| `PushSessionValidator` | **Carried forward** — `src/validators/`, stateless signature check (secp256k1 / Ed25519) |
| `SmartSession` | **Adopted unmodified** — `lib/smartsessions/`, the permission engine |

## What is in `src/` today

```
src/validators/PushSessionValidator.sol   carried forward — see its PRD before editing
src/libraries/                            PushWalletTypes (authoritative gateway structs),
                                          ModeLib, ExecutionLib, PushWalletErrors
src/interfaces/                           IERC7579Module, IUSigVerifier, IUniversalGatewayPC
```

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
