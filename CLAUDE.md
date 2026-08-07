# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Per-user, per-mandate ERC-7579 smart accounts on Push Chain that let an autonomous agent
execute bounded cross-chain actions **without ever taking custody of user funds**.

Implements `PRD-push-agentic-wallet-contracts.md` v1.0, which is a **strict
specification**, not a suggestion. Where it says MUST, it is implemented exactly. Do not
add features, admin functions, pause switches, upgrade paths, or convenience helpers
beyond what it specifies — the audit scope is fixed by that document, and PRD §13.10
requires that no function exist in `src/` that it does not specify.

Any forced departure gets recorded in `DEVIATIONS.md` with a compile-level
justification. Open blockers and unresolved questions live in
`docs-internal/TBD_pointers_v1.md` — **read that before starting work**, it explains
which known problems are deliberate.

## Commands

```bash
forge build
forge test
forge fmt

# One suite / one test
forge test --match-path test/unit/ACPActionPolicy.t.sol
forge test --match-test test_S08_A16_validUntilZeroMeansNoExpiry -vvv

# Coverage (--ir-minimum is required; via_ir is on)
forge coverage --no-match-coverage "(test/|script/|lib/)" --ir-minimum --report summary

# Sizes — SmartSession is currently over EIP-170, see below
forge build --sizes
```

Deployment (both scripts write to `deployments/<NETWORK>.json`):

```bash
NETWORK=<net> forge script script/DeployCore.s.sol:DeployCore \
  --rpc-url <RPC> --private-key <PK> --broadcast

NETWORK=<net> UNIVERSAL_GATEWAY_PC=<addr> \
  forge script script/DeployModules.s.sol:DeployModules \
  --rpc-url <RPC> --private-key <PK> --broadcast
```

Toolchain: `solc 0.8.26` · `evm_version = cancun` · `via_ir = true` ·
`optimizer_runs = 99999`. All four are pinned by PRD §3.2 and §D-17 — changing them has
consequences (see the EIP-170 blocker below).

## Architecture

```
AgentWalletFactory ──clones──▶ PushAgentWallet  (ERC-7579 account, holds funds)
                                  │
                                  ├─ installs ──▶ SmartSession        [adopted, type 1]
                                  │                 ├─ PushSessionValidator  [ours, type 7]
                                  │                 ├─ ACPActionPolicy       [ours]
                                  │                 └─ ERC20SpendingLimit / TimeFrame / … [adopted]
                                  │
                                  └─ calls ──────▶ UniversalGatewayPC (external, not ours)
```

Four contracts are ours; everything under `lib/` is adopted and deployed **unmodified**.

### The central invariant

`UniversalGatewayPC` stamps `msg.sender` into its outbound event, and that determines
which CEA executes on the destination chain. Because the **wallet** is the caller — never
the provider agent — the provider cannot be the beneficiary. `ACPActionPolicy` is what
enforces that structurally. If you change who calls the gateway, you have broken the
entire custody model.

### Two things that are unusual and will confuse you

**1. There is no ERC-4337 EntryPoint on Push Chain.** `executeWithSession` is a
native-AA entry point that does the EntryPoint's job itself: it builds a
`PackedUserOperation` in memory purely as the ABI shape SmartSession expects, then
unpacks the returned `ValidationData` by hand. No EntryPoint ever consumes that struct.

This is the only entirely novel code in the system. Replay protection, expiry, and hash
binding are **entirely ours**. Two traps live here:

- `_computeOpHash` binds eight fields. Every omitted field is a replay class — domain,
  chainid, account, validator, mode, payload hash, nonce key, nonce seq. Do not drop one.
- In `ValidationData`, `validUntil == 0` means **no expiry**, not "expired at epoch 0".

**2. `executeWithSession` is deliberately callable by anyone.** Authorization is the
signature checked inside, not `msg.sender` (D-16 — the provider pays gas, and a relayer
works later with no contract change). This is not a missing access control.

### Policy layering

`ACPActionPolicy.checkAction` walks **two** nesting levels, which is easy to conflate:

- SmartSession destructures ERC-7579 batches and calls `checkAction` **once per action**,
  so the policy never iterates the outer batch.
- It **does** iterate the inner multicall inside `req.payload` — a different nesting
  level. Rules R6–R9 and R11 all operate there.

Rules R1–R11 are specified in PRD §8.5 and each maps to a numbered test (`P-01`…`P-20`).

**Beneficiary offsets are configuration, and a wrong one fails silently** — it reads the
wrong 32-byte word and passes on an attacker-controlled beneficiary. Aave v3 is offset
68, Morpho Blue is 228. Adding any protocol to `allowedCalls` requires a P-18-style test
asserting the offset extracts the right address from a real encoded call.

## Tests

164 tests. Names carry their PRD id (`U-`, `S-`, `V-`, `P-`, `I-`, `F-`, `N-`) and attack
ids from §12 (`A-01`…`A-16`) are embedded in test names — `test_P08_A04_…` demonstrates
attack A-04 is prevented. Keep that convention; it is how the spec is traced.

Integration tests run against the **real** `SmartSession` and adopted policies, not mocks.

### Two test-writing traps specific to this repo

**`vm.prank` is one-shot and helpers consume it.** Building calldata via a helper makes
calls of its own, which eats the prank before it reaches the contract under test.
Always encode first, then prank:

```solidity
bytes memory d = _encode(calls);   // encode BEFORE
vm.expectRevert(...);              // then expectRevert
vm.prank(smartSession);            // then prank
policy.checkAction(..., d);        // then call
```

The same applies to `vm.expectRevert` — it must immediately precede the call, not a
helper that calls out.

**Ed25519 tests use a mocked USV** (`vm.etch` at `0xEC00…0001`). PRD §11.3 marks the
real-precompile fork test (V-11) as REQUIRED before mainnet; it is **not yet written**.

## Known problems — do not "fix" these silently

These are recorded, deliberate states. Read `DEVIATIONS.md` and
`docs-internal/TBD_pointers_v1.md` before changing any of them.

- **D-5 · BLOCKER.** `SmartSession` is 28,737 B at the mandated `optimizer_runs = 99999`
  — 4,161 B over EIP-170, so it **cannot deploy**. It fits at upstream's `runs = 833`.
  PRD §3.2 and §4.1 cannot both hold. **Local anvil deploys appear to succeed because
  anvil does not enforce EIP-170** — that green run is not validation.
- **D-3.** The wallet→self config path in §5.7 / Stage B is unreachable: `execute` and
  `installModule` are both `nonReentrant`, so the self-call reverts. The owner calling
  directly works. `ACPActionPolicy` R7 is kept regardless as defence-in-depth.
- **D-4.** `ExecutionLib.decodeBatch` reads its length from unvalidated calldata, so
  batch mode over single-encoded calldata **succeeds having done nothing**. Bounded (mode
  and payload hash are in `opHash`, so nothing unauthorized runs) but it burns a nonce
  and emits `SessionExecuted` for a no-op.
- **D-2.** `ACPActionPolicy.checkAction` must stay non-`view` to match `IActionPolicy`;
  solc's "can be restricted to view" advisory is unavoidable and is the only warning from
  `src/`.
- **D-6.** Coverage reports ~94%, not 100%. Every uncovered line is inline assembly
  (coverage cannot instrument Yul) or an empty `pure` body — all proven executed by
  assertions on their output.

## Dependencies

`smartsessions` resolves its own dependencies through **npm, not git submodules**, so the
exact transitive closure needed to build it is vendored under `lib/vendor/` at pinned
versions recorded in `README.md`. `smartsessions` itself is pinned at
`f5aaf867f7e22f3b9d746ce6f404f3a56833757f` — it is AGPL-3.0 and security-critical, so an
unpinned dependency is not acceptable. Treat any upgrade as a migration.

`UniActionPolicy` and `ArgPolicy` are **deliberately excluded** — both are `pragma
^0.8.27` and will not compile under the 0.8.26 pin. `ACPActionPolicy` supersedes them.

Interfaces for Push Chain contracts (`IUniversalGatewayPC`, `IUSigVerifier`) are declared
locally in `src/interfaces/` with only the signatures we call, to avoid a cross-repo build
dependency. `PushWalletTypes.sol` mirrors `TypesUGPC.sol` and `Types.sol` field-for-field
— if those change upstream, these must be updated in lockstep.

## Storage layout

`PushAgentWallet` storage order is fixed by PRD §5.4 and **must not be reordered**:
`owner`+`_initialized` (slot 0, packed), `_hook` (1), `_modules` (2), `_nonces` (3).
Verify with `forge inspect PushAgentWallet storageLayout`.

`_modules` **must** stay nested `type => address => bool`. Flattening it to
`address => bool` would let a validator be treated as an executor — a privilege
escalation named in the ERC-7579 security considerations (attack A-01).

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
