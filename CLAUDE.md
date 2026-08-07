# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**One** ERC-7579 smart account per user on Push Chain, letting autonomous agents execute
bounded cross-chain actions **without ever taking custody of user funds**.

Implements `docs-internal/prds/base_prd_v2.md` (**v2.3**), which is a **strict
specification**, not a suggestion. Where it says MUST, it is implemented exactly. Do not
add features, admin functions, pause switches, upgrade paths, or convenience helpers
beyond what it specifies — the audit scope is fixed by that document.

`base_prd_v1.md` is **stale**. `src/` is the truth. Where the two disagree, read the source.

Any forced departure gets recorded in `docs-internal/DEVIATIONS.md` with a compile-level
justification. Open blockers live in `docs-internal/TBD_pointers_v1.md` — **read that
before starting work**, it explains which known problems are deliberate.

## Commands

```bash
forge build
forge test
forge fmt

# One suite / one test
forge test --match-path test/unit/MandateLifecycle.t.sol
forge test --match-test test_T57_exhaustingOneMandateLeavesTheOtherIntact -vvv

# Coverage (--ir-minimum is required; via_ir is on). Slow — several minutes.
forge coverage --no-match-coverage "(src/interfaces/|test/|script/|lib/)" --ir-minimum --report summary

# Sizes — all deployed contracts fit under EIP-170; SmartSession has the
# thinnest margin (22,581 B / 1,995 B spare), so watch it after any dependency bump
forge build --sizes
```

Deployment is **one script** (`script/Deploy.s.sol`), writing to `deployments/<NETWORK>.json`:

```bash
NETWORK=<net> UNIVERSAL_GATEWAY_PC=<addr> \
  forge script script/Deploy.s.sol --rpc-url <RPC> --private-key <PK> --broadcast
```

`DeployCore.s.sol` and `DeployModules.s.sol` were **merged and deleted**. Under v2 the
wallet implementation takes the session engine and three policy addresses in its
constructor, which inverts v1's Core-then-Modules order. One script makes the broken
ordering unrepresentable. The verified order is: SmartSession → PushSessionValidator →
TimeFrame → ValueLimit → (optional policies) → ACPActionPolicy → wallet implementation →
factory → burn the implementation's initializer with `initialize(0xdead, address(0))`.

Toolchain: `solc 0.8.26` · `evm_version = cancun` · `via_ir = true` ·
`optimizer_runs = 833`. **Do not change `foundry.toml`.** `optimizer_runs` is pinned at 833
to match the setting `smartsessions` is built and audited at upstream — at the PRD's
original 99999, `SmartSession` compiles to 28,737 B and exceeds EIP-170.
`evm_version = cancun` is required: `ACPActionPolicy._slice` uses `MCOPY`, and lowering the
target breaks at deploy time rather than compile time.

## Architecture

```
AgentWalletFactory ──clones──▶ PushAgentWallet  (ONE per user, holds funds)
   salt = keccak256(owner)        │
   idempotent                     ├─ installs ──▶ SmartSession        [adopted, type 1]
                                  │                 ├─ PushSessionValidator  [ours, type 7]
                                  │                 ├─ ACPActionPolicy       [ours, MANDATORY]
                                  │                 ├─ TimeFramePolicy       [adopted, MANDATORY]
                                  │                 └─ ValueLimitPolicy      [adopted, MANDATORY]
                                  │
                                  ├─ grantMandate / revoke / reconfigure / purge   [owner]
                                  ├─ guardianPause / guardianRevoke*               [guardian]
                                  └─ calls ──────▶ UniversalGatewayPC (external, not ours)
```

Four contracts are ours; everything under `lib/` is adopted and deployed **unmodified**.

### The central invariant

`UniversalGatewayPC` stamps `msg.sender` into its outbound event, and that determines
which CEA executes on the destination chain. Because the **wallet** is the caller — never
the provider agent — the provider cannot be the beneficiary. `ACPActionPolicy` is what
enforces that structurally. If you change who calls the gateway, you have broken the
entire custody model.

### Rule 2: one wallet per user, and what it cost

The factory salt is `keccak256(abi.encode(owner))` with **no mandate input**, so a user has
one wallet forever and therefore one CEA per external chain. A mandate is a SmartSession
*session*, not a contract.

**Isolation therefore changed species: structural → configured.** v1's claim — "one
mandate's session cannot reach another's wallet, because they are different contracts" — is
**WITHDRAWN**. Do not restate it anywhere, including in docs.

The v2 guarantee is the **Mandate Bound** (PRD §C.6): a table of caps readable from policy
state. It rests entirely on SmartSession keying every policy config by

```
ConfigId = keccak256(account, keccak256(PermissionId, actionId))
```

**If that keying assumption is ever broken, v2's isolation fails silently.** It is pinned by
`test_T57_exhaustingOneMandateLeavesTheOtherIntact` — never delete that test.

Not covered, stated honestly: idle wallet balances are fungible across mandates. Total user
exposure is the sum of every `maxAmountTotal`, each personally signed.

### Three things that are unusual and will confuse you

**1. There is no ERC-4337 EntryPoint on Push Chain.** `executeWithSession` is a
native-AA entry point that does the EntryPoint's job itself: it builds a
`PackedUserOperation` in memory purely as the ABI shape SmartSession expects, then
unpacks the returned `ValidationData` by hand. No EntryPoint ever consumes that struct.

Replay protection, expiry, and hash binding are **entirely ours**. Two traps:

- `_computeOpHash` binds eight fields. Every omitted field is a replay class — domain,
  chainid, account, validator, mode, payload hash, nonce key, nonce seq. Do not drop one.
- In `ValidationData`, `validUntil == 0` means **no expiry**, not "expired at epoch 0".

Because every gas field in that in-memory struct is zero, **`SimpleGasPolicy` must never be
attached** — it would compute a zero cost, pass everything forever, and still satisfy
SmartSession's one-policy floor while *appearing* in the session as a gas control. Use
`ValueLimitPolicy` for gas budgeting.

**2. `executeWithSession` is deliberately callable by anyone.** Authorization is the
signature checked inside, not `msg.sender` (the provider pays gas, and a relayer works later
with no contract change). This is not a missing access control.

**3. Upstream `enableSessions` is silent on everything that matters.** It accepts a duplicate
`PermissionId` without complaint — `$enabledSessions.add` is idempotent and
`ConfigLib.enable` re-runs `initializeWithMultiplexer`, whose `_store` resets `spent` to zero
and replaces every cap. That is a mandate-laundering vector, and closing it is why
`grantMandate` exists at all rather than the SDK calling `enableSessions` directly.

### The grant guards — do not weaken these

`grantMandate` and `reconfigureMandate` both run `_requireBoundedSession` and
`_requireSafeActions` before touching SmartSession:

| Guard | Closes |
|---|---|
| `salt != 0` | An unnamed mandate slot |
| SmartSession installed | The grant-before-install brick |
| duplicate `PermissionId` rejected | Silent cap reset (see above) |
| TimeFramePolicy present, `validUntil != 0` | A permanent unrevoked key (zero means NO expiry upstream) |
| exactly ONE action | Two entries for one target collapse to one ConfigId; the looser wins by array position |
| target != `address(1)` | The fallback ActionId, whose policies apply to *every* unregistered call |
| target != SmartSession | The session key reaching `enableSessions` / `removeSession` |
| target == the gateway | v2.0 scope lock (see F-25 below) |
| both ACP and ValueLimit attached | Upstream needs only *one* policy, so a TimeFrame-only action bypasses every ACP rule |

`TimeFramePolicy` initData is `abi.encodePacked(uint48 validUntil, uint48 validAfter)` —
12 bytes, `validUntil` in the **HIGH** 6. Our guard reads `d[0:6]`. `test_T16b` pins that
against the policy's own getter — **never delete it**, or the expiry guard could become
vacuous at a future pin bump.

### Policy layering

`ACPActionPolicy.checkAction` walks **two** nesting levels, which is easy to conflate:

- SmartSession destructures ERC-7579 batches and calls `checkAction` **once per action**,
  so the policy never iterates the outer batch.
- It **does** iterate the inner multicall inside `req.payload` — a different nesting
  level. Rules R6–R9 and R11 all operate there.

Rules in `src/` are **R1–R14, non-sequential, and are never renumbered** — existing tests and
audit notes reference them by number. New rules append.

Two config-time checks live in `_store`, not `checkAction`, and therefore fire on **every**
path that stores a config — `grantMandate`, `reconfigureMandate`, and the owner's
`callValidator` escape hatch alike:

- **CV-1** — an `approve` / `increaseAllowance` entry must pin its spender
  (`hasBeneficiary`, `beneficiaryOffset == 4`, non-zero `expectedArg`). Without it the
  mandatory destination-chain approval has a completely unchecked spender, and a compromised
  key can hand the CEA's balance to an attacker via `transferFrom` (A-15).
- **CV-2** — `expectedCEA` may not be zero, because `expectedArg == address(0)` is the
  sentinel meaning "the wallet's own CEA"; a zero CEA collapses that sentinel.

**Beneficiary offsets are configuration, and a wrong one fails silently** — it reads the
wrong 32-byte word and passes on an attacker-controlled address. Aave v3 is offset 68,
Morpho Blue 228, ERC-20 `approve` 4. Adding any protocol to `allowedCalls` requires both a
T-64-style positive test and a T-65-style **negative control**; without the negative, the
positive can pass vacuously.

## Tests

**282 tests across 16 suites, all passing.** Names carry their PRD id (`U-`, `S-`, `V-`,
`P-`, `I-`, `F-`, `N-`, and v2's `T-`) and attack ids (`A-01`…`A-16`) are embedded —
`test_T52_A14_allThreeWildcardsDeniedAtGrant` demonstrates A-14 is prevented. Keep that
convention; it is how the spec is traced.

Integration tests run against the **real** `SmartSession` and adopted policies, not mocks.

`test/helpers/MandateFixture.sol` holds the canonical §C.5 session template. Build sessions
through it rather than by hand, so the template lives in one place.

### Tests marked "never delete"

These are alarms, not decoration. Each one fails if a specific guarantee regresses:

| Test | Guards |
|---|---|
| `test_T57` | The ConfigId keying that IS v2's isolation model |
| `test_T16b` | Our `validUntil` decode against the policy's own getter |
| `test_T43` | R7-ext holds *even when the CEA is allowlisted* — proves it is structural |
| `test_T31` | The wallet is not permanently brickable by `emergencyRevokeAll` |
| `test_T10` | Our `_permissionId` tracks `IdLib.toPermissionId` |
| `test_CV1_unpinnedApprovalEntryReverts` | A-15's config is unconstructible |
| `test_T66` | Records the F-25 gateway-only constraint in code |

**Mutation-test any guard you add.** Break the contract, confirm the test fails, restore. A
passing test proves nothing until you have seen it fail.

### Three test-writing traps specific to this repo

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

**`via_ir` hits Yul's stack limit easily in test helpers.** Encoding a `Config` inline or
passing many flat parameters both trigger "too deep in the stack". Split the function or use
a params struct — **do not change compiler settings** to work around it.

**Ed25519 tests use a mocked USV** (`vm.etch` at `0xEC00…0001`). The real-precompile fork
test (V-11) is **still not written** — see below.

## Known problems — do not "fix" these silently

Read `docs-internal/DEVIATIONS.md` and `docs-internal/TBD_pointers_v1.md` before changing
any of these.

**🔴 The USV fork test (V-11) is the highest-value open gap.** Every Ed25519 path runs
against a `vm.etch`'d mock. This matters because v1's C-1 critical bug existed *precisely
because* a mock hid an on-chain precompile revert: a high-level interface call inserts an
`extcodesize` check that reverts on a codeless target. The fix is in (`PushSessionValidator`
uses a raw `staticcall`) but has never touched real hardware. Needs a known-good
`(pubKey, message, signature)` vector from the node team. **Should block mainnet.**

**F-25 — the gateway is the ONLY permitted session action target.** That is the tightest
closure of the wildcard-action hazard and correct for v2.0's entry-only scope. The cost: the
wallet is an immutable clone, so admitting a second session action type later needs a new
implementation *and* factory. If ERC-8183 ever needs agent-initiated session-path calls to
the kernel, this is the constraint that blocks it — revisit before mainnet, not after.
Recorded in code by `test_T66`.

**Deliberate redundancy that must not be "simplified":**

- **A-04 has three independent defences** — SmartSession's own `InvalidSelfCall`, our R7,
  and the wallet's `onlyOwner`. None may be removed as redundant.
- **R7's first three members** (account, policy, gateway) are defence-in-depth; the fourth
  (`expectedCEA`) is load-bearing on its own — an inner CEA self-call satisfies the CEA's own
  self-call check and is the designed exit path.
- **`maxAmountPerCall` and `maxAmountTotal`** are deliberately both present: per-call bounds
  single-transaction blast radius, cumulative bounds lifetime exposure.
- **`emergencyRevokeAll` semantics never change** (it skips callbacks so a hostile module
  cannot resist removal). `guardianRevokeAll` is the non-bricking variant.

**Also easy to regress:** the single-active-hook rule, the cumulative spend cap (R5b), R12
and R13 bounding the pooled PC gas budget, and `ExecutionLib.decodeBatch`'s bounds checks.

## Dependencies

`smartsessions` resolves its own dependencies through **npm, not git submodules**, so the
exact transitive closure needed to build it is vendored under `lib/vendor/` at pinned
versions recorded in `README.md`. `smartsessions` itself is pinned at
`f5aaf867f7e22f3b9d746ce6f404f3a56833757f` — it is AGPL-3.0 and security-critical, so an
unpinned dependency is not acceptable. **Never fork it**: a fork of an audited contract looks
audited and is not. Treat any upgrade as a migration.

> ⚠ `base_prd_v2.md` cites the SmartSession pin as `7e1f08f5…`. **That is wrong** — it is
> this repository's own "v1 fixes" commit, copy-pasted by mistake. `lib/smartsessions` is
> vendored as plain files, not a submodule, so the hash cannot be read back from git.
> `README.md` is the authority for the real upstream pin.

`UniActionPolicy` and `ArgPolicy` are **deliberately excluded** — both are `pragma
^0.8.27` and will not compile under the 0.8.26 pin. `ACPActionPolicy` supersedes them.
`ERC20SpendingLimitPolicy` is deployed for tests but **not in the live session path**; the
cumulative asset cap lives in `ACPActionPolicy.maxAmountTotal`.

Interfaces for Push Chain contracts (`IUniversalGatewayPC`, `IUSigVerifier`) are declared
locally in `src/interfaces/` with only the signatures we call, to avoid a cross-repo build
dependency. `IUSigVerifier` is **documentation only** — the validator uses a raw
`staticcall`. `ISmartSessionMandate` is our narrow four-function slice of SmartSession.
`PushWalletTypes.sol` mirrors `TypesUGPC.sol` and `Types.sol` field-for-field — if those
change upstream, these must be updated in lockstep, since they decode by ABI position.

## Storage layout

`PushAgentWallet` storage order is fixed and **must not be reordered**:
`owner`+`_initialized` (slot 0, packed), `_hook` (1), `_modules` (2), `_nonces` (3),
`guardian`+`sessionsPaused` (slot 4, packed). Slots 0–3 are byte-identical to v1 — the
guardian was **appended**, never inserted. Verify with
`forge inspect PushAgentWallet storageLayout`.

Five values are `immutable`, not storage: `SMART_SESSION`, `UNIVERSAL_GATEWAY_PC`,
`ACP_ACTION_POLICY`, `TIMEFRAME_POLICY`, `VALUE_LIMIT_POLICY`. They live in the
implementation's code and are shared by every clone, which is what makes the grant guards
tamper-proof — a storage-based policy address could be rewritten later to disarm them.

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
