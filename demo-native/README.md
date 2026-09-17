# The Push-Native Agentic Demo

**One chain. One transaction per action. No bridge, no relay, no waiting.**

A user on Push Chain funds a small wallet, hands an autonomous agent a narrow written mandate, and
the agent does useful work with the user's money — while the contracts, not the agent's honesty,
guarantee it can do **only** what the mandate says.

> **Status: built, not yet run.** Every script compiles and the unit suite is green, but no act has
> been executed against Donut. `NATIVE_DEMO_MANUAL.md` is deliberately absent until after the first
> dry run — a manual written from a plan documents intentions; one written from a run documents
> facts.

---

## How this differs from `demo/`

`demo/` is the **cross-chain** demo: Bob is an Ethereum EOA who never touches Push, acting through a
UEA, and the agent's action is bridged to Sepolia and executed by a CEA. It proves **reach**.

This one proves the **permission system**, with nothing in the way:

| | `demo/` (cross-chain) | `demo-native/` (this) |
|---|---|---|
| Chains | Sepolia + Push Donut | **Push Donut only** |
| Bob | Ethereum EOA, never touches Push | **Push EOA, acts directly** |
| Identity chain | EOA → UniversalAccountId → UEA → AGW; CEA on Sepolia | **EOA → AGW. That's it.** |
| Mandate type | `UNIVERSAL` | `NATIVE` |
| Configs per mandate | 1 | **1 per action** |
| Agent's target | the gateway, always | **the contract itself** |
| Payload nesting | 4 layers | **1** |
| Request `value` | protocol fee + gas swap, live-quoted | **0** |
| Beneficiary check | `expectedCEA`, gate 15 | **`ArgPin` at offset 4, gate N7** |
| Settlement | ~20–90 s, TSS relay | **same transaction** |
| Staked asset | PRC20 USDC | **`dUSDC`, deployed for the demo** |

**Neither supersedes the other.** The native demo is the better opener for a technical audience; the
cross-chain demo is the better closer.

---

## Quick start

```bash
cd demo-native

just preflight        # green/red checklist — run at T-1h AND T-5min
just setup            # deploy dUSDC + StakeDummy, mint, fund the pool   (T-1 hour, off camera)
#   ⚠️ paste the two printed addresses into
#      deployments/address-book-v2/native_demo.json before continuing

just act1             # Bob arrives, funds, approves, grants  — 1d is the opening beat
just state            # between every act

just act2             # THE CENTRAL BEAT — the agent stakes
just g1 g2 g3 g4 g5   # the gauntlet: five refusals, each with a named error
just g6               # the replay — run BEFORE act 3b
just stake 25         # act 3b
just stake 10         # act 3c — lands exactly on the lifetime cap
just g7               # the budget runs out under the run's own weight

just act4a-grant      # a second mandate, for one job
just act4a            # the agent withdraws — to the WALLET
just g8               # a second unstake, refused at the call ceiling
just act4b            # the agent tries to take the money — refused
just act4c            # Bob takes it back, instantly
just act4d            # stop everything
just act4e            # THE CLOSING BEAT — a banked request dies with the mandate
just act4f            # the unpinned-approve demonstration (optional, five steps)

just reset            # after any rehearsal
```

---

## The three beats that carry the demo

**1d — the mandate.** The thesis on one screen: *this agent key may call one function on one
contract, only ever crediting Bob's wallet, up to 25 dUSDC per action and 60 in total, at most four
times, for seven days.* Every number is read back from URP, not printed from a constant.

**G3 — the agent stakes to itself.** One word of calldata differs from Act 2. It is refused, and the
reason is worth stating in full: `StakeDummy.unstake()` pays `msg.sender`, so had this succeeded the
agent could have called `unstake()` **from its own EOA, under no mandate at all**, and walked away
with principal plus reward. The pin is what stops it.

**4f — where the guarantee ends.** An `approve` mandate that forgets to pin the spender is a
*valid* mandate. The agent uses it to approve an accomplice, who drains the wallet — and nothing
refuses it. Then the same mandate with the spender pinned refuses the identical request.
**The system enforces the mandate as written; the SDK is what refuses to write a bad one.**

---

## What this demo deliberately does not prove

- **Not cross-chain anything.** No gateway, no CEA, no Sepolia. That is `demo/`.
- **Not that the agent is intelligent.** It is a signing key running a script.
- **Not that `StakeDummy` is a good staking contract.** No owner, no pause, no supply accounting.
- **Not that URP refuses a badly written mandate.** It proves the opposite, on purpose, in 4f.

---

## Layout

```
contracts/   DemoUSDC (new) · StakeDummy (copied byte-for-byte from demo/)
lib/         AddressBook · Amounts · Ledger · OwnerDoor · NativeIds ·
             NativeMandate · NativeRequest · NativeGauntlet
             AgentSigning · DemoLog · Keys  ← copied VERBATIM from demo/lib/
script/      00_setup · 01_bob · 02_agent · 03_gauntlet · 04_boundary · 05_inspect · 99_reset
test/        AgentSigning · NativeIds · NativeMandate · StakeDummy
state/       ledger.json (gitignored, per-run)
```

**`AgentSigning.sol` is byte-identical to `demo/lib/AgentSigning.sol`, and a test asserts it.** That
is a claim about the architecture, not this folder: the agent-authorisation layer is
mode-independent, so a native request and a cross-chain request are signed by the same code. If it
ever needs forking, the two modes have diverged somewhere they should not have.

---

## Two things that will bite you

**The address book ships zeroed.** `DemoUSDC` and `StakeDummy` are `0x0` until you paste the
deployed addresses in. That is the never-zero rule working: a script run before setup fails with a
named `MissingAddress` naming the script that writes it, rather than proceeding against `address(0)`
and failing three acts later with nothing on screen.

**Nonce lanes are per wallet, and there are four mandates across two wallets.** Bob's wallet uses
lane 0 (stake) and lane 1 (unstake); the throwaway wallet uses its own lane 0 and 1. Every signing
script reads `wallet.getNonce(lane)` immediately before signing — **nothing caches a sequence
number**, which is the bug the cross-chain demo shipped.

---

## Tests

```bash
FOUNDRY_PROFILE=demo-native forge test
```

A **separate profile**, not a change to the default `test` path: `forge test` must keep running
exactly the v3 suite, which is the contracts' specification.
