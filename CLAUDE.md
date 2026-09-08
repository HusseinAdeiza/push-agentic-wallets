# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**`docs-internal/v3-architecture-docs/README.md` is the single entry point for design intent.** Read it, and
the reading plan it sets out, before writing any code. This file is conventions, commands and orientation;
it does not restate the architecture.

**Precedence, highest first:** `CORE_RULES_v3.md` → `v3-architecture.md` → `v3-decision-register.md` →
the five PRDs in `v3-prds/` → the worked example (`docs-internal/prds/context/agentic_wallet_flow.md`).
Everything else in the repository is history. **The PRD is the specification; the existing code is not.**

## Commands

```
make build    # forge build
make test     # forge test -vv
make sizes    # the S-06 size gate — forge build --sizes, exits non-zero over 24,576 B
forge fmt     # line_length 120, tab_width 4
```

`make sizes` runs `--sizes` twice — once for the build, once for the vendored engine explicitly. That is
deliberate: **which contracts the default table covers is forge-version-dependent** (1.5.1-stable includes
`lib/`; 1.6.0-nightly did not), and SmartSession has the smallest margin in the build. The gate must not
rest on a reporting default that has already changed once.

Narrower runs:

```
forge test --match-path test/unit/URP.t.sol -vv
forge test --match-test test_U09_ -vvv           # one test, full traces
forge test --match-contract URPTest
forge coverage --ir-minimum                       # via_ir is on; plain coverage will not compile
forge test --gas-report
```

Two suites are env-gated and **skip silently when the variable is unset** — a skipped test is not a passing
test, so run each at least once against a real endpoint before reporting a phase done:

- `PUSH_TESTNET_RPC` — gates P-03, the only fork test of the live Ed25519 precompile, and the sole liveness
  proof of that branch.
- `DEPLOYMENT_RPC` + `CHAIN_ID` — gate S-05, which checks `deployments/<chainId>.json` against a live chain.

Deployment (all five contracts, dependency order, writes `deployments/<chainId>.json`):

```
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast
```

Requires `UNIVERSAL_GATEWAY_PC`, `UNIVERSAL_EXECUTOR_MODULE`, `CHAIN_ID`, and `FACTORY_ADMIN` off local
chains. See `.env.example`. The script asks the chain for its id and reverts on a mismatch with `CHAIN_ID`.

## The system in one pass

A user funds a small, purpose-built wallet on Push Chain and grants it a **mandate**: a frozen bundle of
limits (which agent key, which token, which destination protocol and functions, how much per call, how much
total, until when). The wallet's balance is the hard ceiling on everything the agent can lose. Every agent
action is checked by contracts at execution time; the agent's honesty is never assumed.

**The one hard problem.** Push Chain reaches other chains through a single frozen gateway function, so every
agent action — a trade, a deposit, a theft — is the *same* Push-side call: the wallet calling
`sendUniversalTxOutbound`. To the permission engine they are indistinguishable. Everything the user cares
about lives inside the payload, two decode levels down. **URP is the contract that opens that payload.**

### Five contracts

| Contract | Role |
|---|---|
| `AGWFactory` (`src/`) | UUPS proxy. Deploys wallet clones at pre-computable addresses; the registry of record for "is this a real wallet, and who owns it?" The caller is always the owner — there is no owner parameter. |
| `PushAgentWallet` (`src/`) | Holds funds. Minimal clone with 40 bytes of immutable args (owner 0–19, factory 20–39). Push Chain has no ERC-4337 EntryPoint, so the wallet does the EntryPoint's jobs itself. |
| `URP` (`src/policies/`) | The only novel contract and the security boundary. Sixteen gates, in normative order, fail closed. |
| `PushSessionValidator` (`src/validators/`) | Stateless signature check: secp256k1, or Ed25519 via a raw `staticcall` to the USV precompile. |
| `SmartSession` (`lib/smartsessions/`) | Adopted unmodified. Stores mandates, runs policies, deletes on revoke. The wallet's only installed module. |

### Load-bearing invariants (each has a permanent test)

- **The two doors are the whole authority model.** `execute` (owner door) consults *exactly two things* —
  the immutable-args owner and calldata. No module, policy, engine state or flag may ever be read there; it
  must succeed with the engine uninstalled, a hostile validator installed, or ghost-mandate state. Adding
  any check is the catastrophic regression. `executeWithSession` (agent door) is permissionless — signature,
  nonce and bound op-hash are the authority, never the caller.
- **`execute(bytes32,bytes)` is a frozen signature.** The engine branches on this selector; any other shape
  routes validation to a path where URP's value gate sees a hardcoded zero instead of the real value.
- **The ten-field operation hash** (`_computeOpHash`) uses `abi.encode`, never `encodePacked`. Fields 5
  (permissionId) and 10 (requestExpiry) are v3 additions over shipped v2's eight; regressing to eight is
  forbidden. Field 5 is what makes a banked signed request die on regrant.
- **`grantMandate` enforces the canonical session shape and nothing else** — the skeleton, not the organs.
  Term validation is URP's own init guards. Its monotonic `_grantNonce` becomes the session salt, so every
  grant yields a distinct permission id that never recurs.
- **`stopMandate` / `stopAll` must have nothing on them that can fail.** No guard, no probe, no extra
  external call. Blockable revocation is the one regression these functions can develop.
- **URP's `checkAction` makes no external calls.** It runs *before* the session signature is verified, on
  unauthenticated calldata from an arbitrary caller; its safety rests on having no external calls, all
  effects last, and reverting on every failure. Do not wrap its `abi.decode` in `try/catch` to name an
  error — that introduces the external call the argument forbids.
- **Gate 12 (payload must be a multicall) is not a format check.** It confines the agent to the one CEA
  branch whose entries gates 13–16 can walk; the other branches bypass the allow-list, beneficiary pin and
  value cap entirely.
- **Gate 16's per-entry cap is in destination-chain native units** and is never compared against the
  Push-side `value` (gate 8). Conflating them is a real bug this design once carried.
- **The factory's derivation is frozen forever.** `_walletImplementation` is the append-only storage anchor
  with no setter; the salt formula and the 40-byte immutable-args encoding may never change, because
  counterfactual funding is a supported flow with no recovery path.

### Where the layers meet

- `SEND_OUTBOUND_SELECTOR` and `MULTICALL_SELECTOR` are declared **once**, in
  `src/libraries/PushWalletTypes.sol`, beside the struct mirrors they derive from. The wallet's grant-shape
  check and URP's request gate both read from there so they cannot disagree. `PushWalletTypes` is the
  authoritative mirror of the gateway's frozen structs — reordering a field silently breaks the selector.
- URP's config is keyed `configId => multiplexer => account`. `ConfigId` already binds account and
  permission (see the derivation chain in URP's storage comment — note it mixes `abi.encode` and
  `abi.encodePacked` across levels; an SDK that assumes one throughout derives every id wrong). The middle
  level isolates *callers*: `msg.sender` on the two engine-driven entry points, the `SESSION_ENGINE`
  immutable everywhere else.
- The engine truncates policy revert data to 32 bytes and rewraps it as `PolicyCheckReverted(bytes32)`. Use
  `BaseTest.expectUrpGate(...)` so negative tests name *which* gate fired; never hand-encode this.

## Standing build rules

1. **One phase at a time.** Stop at the gate, report, wait for acknowledgement before proceeding.
2. **One contract per phase, its tests in the same phase.** No contract ships without its suite.
3. **The PRDs are locked.** A PRD error is *reported with evidence and waited on* — never fixed in place,
   never coded around. Never "fix" anything on a PRD's DO NOT FIX list; raise it instead.
4. **`src/libraries/` and `src/interfaces/` may change only via a diff proposed at the start of the phase
   that needs it.** Never edited opportunistically.
5. **Branch `pushAgenticWallet_v3`.** All build work lives there. **Zaryab alone commits and pushes** —
   prepare the change, report what is ready, print the commands; never run `git commit` or `git push`.
   Never commit `deployments/*.json`, `out/`, `cache/`, or `.env`.
6. **Never invent addresses, selectors or magic values.** Several are deploy-time inputs and marked as such.
7. **Say what you did not do.** Skipped, unverified or uncertain work is stated plainly, not presented as
   complete.
8. **Gate report format:** what was built · what was verified and how · what deviated and why · what you are
   unsure of · `forge test` and `forge build --sizes` output verbatim · the exact `forge --version` line.

## Standing test rules

1. **Every negative test names its expected error.** Two documented exceptions only: URP gate 4 case (d)
   (correct-length, malformed-offset body) and validator P-05 — both assert "reverts" because both fail at
   the same un-named `abi.decode` step.
2. **A mock may be the OBSERVER, never the ORACLE.** A mock that supplies the behaviour under test can make
   a dead branch look live. That is how this repo's one shipped critical bug survived review: the Ed25519
   branch called the precompile through a typed interface, solc inserted an `extcodesize` check, precompiles
   have no code — so the branch reverted on the real chain while every test passed, because the tests etched
   bytecode at the precompile address. Whenever you etch or stub something, ask what the code would do
   against the real thing.
3. **Gas assertions carry a number.** "Within a sane budget" is not assertable; a test that cannot fail is
   worse than no test.
4. **Nothing marked ⚠️ NEVER-DELETE is deleted or weakened.** Test names are specification: keep the names
   given, add tests freely, rename nothing.
5. **Prefer artifact assertions over `vm.load` for structural claims.** Solidity offers no runtime way to
   prove "declares no storage"; `assertEmptyStorageLayout` and `assertSelectorSet` in `test/Base.t.sol` read
   solc's own output instead. Use those helpers — do not write second copies.

## Test harness

Every suite extends `BaseTest` (`test/Base.t.sol`), which deploys the real engine, validator, URP, wallet
implementation and an ERC-1967 factory proxy, then hands out wallets via `newWallet(owner)` — the real
`deployWallet` path, not a simulated factory. It also carries the canonical session builder, the outbound
request builder, the gate-naming helper, the USV observers and the call recorder. Test ids (`T-`, `W-`,
`U-`, `P-`, `S-`) come from the PRDs and appear in test names and comments.

## Toolchain pins (facts, not preferences)

- `solc 0.8.26` · `optimizer_runs = 833` · `evm_version = "cancun"` · `via_ir = true`
- OpenZeppelin 5.7.0 · forge-std 1.16.2 · SmartSession fork `7dc20e4`
- **forge: use STABLE, never nightly** (`foundryup -i stable`). Runtime bytecode is a function of
  solc + optimizer + via_ir + evm_version + metadata — all pinned in `foundry.toml` — so the forge binary
  does not change the sizes S-06 gates on. It does change how `--sizes` reports, how remappings resolve, and
  how `forge script` broadcasts, which is where a nightly actually bites. `foundry.toml` has no key for the
  driver version: **record the exact `forge --version` in every gate report.** That is the reproducibility
  mechanism — do not invent a config key for it.

  **Recorded at Gate 0 and still current:** `forge 1.5.1-stable`
  (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`, 2025-12-22). SmartSession runtime 22,581 B / +1,995 margin —
  byte-identical to the figure measured on 1.6.0-nightly, which is the evidence that the driver does not
  move bytecode.

**`optimizer_runs` and `evm_version` are load-bearing.** The vendored engine exceeds EIP-170 above ~833 runs
and becomes undeployable; `cancun` is required for `MCOPY` in URP's `_slice` helper. A local `anvil` deploy
will not catch the size problem — anvil does not enforce EIP-170.

`fs_permissions` grants read access to `out/` and write access to `deployments/`. Both are required, not
conveniences: the artifact-based storage-layout and selector-set assertions depend on the former.

## Layout

| Path | Contents |
|---|---|
| `src/` (root) | `PushAgentWallet.sol`, `AGWFactory.sol` |
| `src/policies/` | `URP.sol` |
| `src/validators/` | `PushSessionValidator.sol` |
| `src/interfaces/` | `IURP`, `IPushSessionValidator`, `IAGWFactory`, `IPushAgentWallet`, `IPushAgentWalletInit`, gateway + module interfaces |
| `src/libraries/` | `PushWalletTypes` (authoritative gateway struct mirror), `ModeLib`, `ExecutionLib`, `PushWalletErrors` |
| `test/Base.t.sol` | Shared harness — every suite extends `BaseTest` |
| `test/unit/`, `test/integration/`, `test/mocks/` | Per-contract suites, end-to-end flows, observers |
| `script/Deploy.s.sol` | The five-contract deployment, in dependency order |
| `deployments/` | `<chainId>.json` records — **never committed** |
| `_to_delete/` | v1/v2 code staged for deletion — **ignore entirely** |

## Build order (all phases complete)

| Phase | Deliverable |
|---|---|
| 0 | Baseline: build green, harness, size gate |
| 1 | `URP` |
| 2 | `PushSessionValidator` — `validateConfig` addition + full suite |
| 3 | `PushAgentWallet` |
| 4 | `AGWFactory` |
| 5 | Integration + deploy script |
