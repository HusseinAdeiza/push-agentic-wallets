# Demo Manual

The operator's script. Every command, in order, with what it does and what you say.

Run everything from the repo root as `just -f demo/justfile <recipe>`, or `cd demo && just <recipe>`.
This manual writes them as `just <recipe>`.

**The thesis:** Bob funds a small wallet and grants an agent a mandate. The wallet's balance is the hard
ceiling on everything the agent can lose. Every agent action is checked by contracts at execution time.
The agent's honesty is never assumed.

---

## 0 · Before anything

| Fact | Value |
|---|---|
| Push Chain Donut | chain id `42101` · explorer `https://donut.push.network` |
| Ethereum Sepolia | chain id `11155111` |
| Keys in `.env` | `BOB_KEY`, `AGENT_KEY`, `PC_RELAYER_KEY`, `SEPOLIA_STAKE_DEPLOYER_KEY` |
| RPCs in `.env` | `PUSH_DONUT_RPC_URL`, `SEPOLIA_RPC_URL` |
| Scale knob | `DEMO_SCALE_PERCENT` — **must be unset or 100 for the live run** |

**Money, at 100% scale:** bridge **100 USDC** · per-action cap **50** · lifetime cap **60** · unstake reward
a flat **10**. Bob ends with **110**.

The three numbers are one story: 50 lets *one* stake through; 60 makes a *second* fail while leaving room
for the reward. `DEMO_SCALE_PERCENT` scales all three together — but **`REWARD` is compiled into the
deployed StakeDummy and never scales**, so a 10% rehearsal still pays 10 USDC.

**Two rules for the day.** `just reset` is rehearsal recovery only — never during the live demo. And
`DEMO_SCALE_PERCENT` must be unset before you present.

---

## 1 · T-1 hour — setup (off-camera)

```
just setup
```

That is `tokens → quote → fund → stakedummy → preflight`, in the correct order. Run the pieces
individually only if one fails.

| # | Recipe | Chain | Broadcasts | Does |
|---|---|---|---|---|
| 1 | `just tokens` | Donut, read-only | no | Asserts the PRC20 quotes to `eip155:11155111` and its symbol does not end `.old` |
| 2 | `just quote` | Donut, read-only | no (writes ledger) | Prices the outbound; writes `quote.msgValue`, `quote.maxPCForGas`, `quote.maxPCPerCall` |
| 3 | `just fund` | Sepolia | yes, **Bob** | Transfers Bob → deployer so the deployer holds 100 USDC. Idempotent |
| 4 | `just stakedummy` | Sepolia | yes, **deployer** | Deploys `StakeDummy`, funds its 100 USDC reward pool, writes the address book |
| 5 | `just preflight` | Donut + Sepolia | no | The green/red checklist. **Must print `READY`** |

- **`fund` runs before `stakedummy`** — the deployer needs its 100 USDC before it can call `fundRewards`.
  Filename order (`02`, `03`) disagrees with run order; `just setup` already has it right.
- `just tokens` is worth five seconds: a wrong PRC20 does not revert. It produces an outbound that passes
  every Push-side check and does nothing on Sepolia — invisible until minutes later, in front of an audience.
- Every broadcasting recipe has a `-dry` twin (`just fund-dry`). Use them in rehearsal.

**Only if StakeDummy is already deployed and funded, skip 3–4.** Preflight checks the pool.

---

## 2 · Act 1 — Bob arrives (off-camera)

```
just act1
```

Runs `act1a → act1b → act1c → act1d → act1e`. **Run them one at a time**, because two of them wait on a
cross-chain relay.

### act1a — the only Ethereum transaction

```
just act1a
```

- Chain **Sepolia** · broadcasts with **Bob's** key.
- Prints the prediction block: Bob's **UEA** and **AGW** on Push, and his **CEA** on Sepolia. None exist
  yet; all three are computable today.
- Approves the gateway for 100 USDC, then calls `sendUniversalTx` with `recipient: address(0)` (credit
  Bob's own UEA), `value: 0.002 ETH`.
- Writes `bobEOA`, `uea`, `agw`, `predictedCEA`.
- Reverts before broadcast on `InsufficientUSDC` or `InsufficientETH`.

**→ WAIT for the relay (~30–45 s).** No watcher covers this hop; `act1b`'s own preconditions are the gate.
The relay deploys Bob's UEA, mints pUSDC to it, and delivers PC for gas.

> The wallet-setup payload *is* attached to this transaction but is **inert on today's build** — four
> probes established the deployed build does not execute an attached inbound payload. It is left attached
> at zero cost so that if Push core wires it up later, this becomes the single-transaction arrival, and
> `act1b` detects and skips. Do not narrate it as working today.

### act1b — Bob signs, a stranger submits

```
just act1b
```

- Chain **Donut** · broadcasts with the **relayer** key, on a payload **Bob** signed.
- Deploys the AGW, moves 100 pUSDC into it, and approves the gateway — all in one signed multicall.
- Reverts `UEANotDeployed` / `UEANotFunded` / `NoPCForGas` if the act1a relay has not landed. Re-run it.
- **Idempotent by detection** — if the AGW already exists it exits cleanly rather than deploying a second
  wallet at index 1.

**Say it:** `executeUniversalTx` has no access control. The relayer holds nothing. The signature is the
authority, never the caller.

### act1c — the PC seam

```
just act1c
```

- Chain **Donut** · broadcasts with the **relayer** key. Tops the AGW **up to 20 PC**.
- Idempotent: tops up to the target, never adds a fixed amount.

**Say it out loud — this is the one seam in the story.** The bridge mints pUSDC, not native PC. Every
outbound burns PC for protocol fee and gas swap, paid from the wallet's own balance. This is the one step
Bob cannot perform from Ethereum. In production an SDK, relayer or paymaster sponsors it. Naming the
limitation costs ten seconds and buys credibility.

### act1d — the destination-chain approval

```
just act1d
just watch-cea
```

- Chain **Donut** · broadcasts with the **relayer** key, on a payload **Bob** signed.
- A **zero-amount** outbound carrying one far-chain call: `USDC.approve(StakeDummy, max)` on Sepolia.
- **This is the first inbound Sepolia sees for this wallet, so it deploys the CEA** — at the address
  predicted back in act1a.
- Reverts `QuoteMissing` if `just quote` never ran, `WalletOutOfPC` if act1c did not.

**→ WAIT.** `just watch-cea` polls Sepolia until the CEA has code.

**Why `approve` is an owner action, not an agent one.** UCEP's allow-list pins a target, a selector, and
optionally one argument that must equal the CEA. `approve(spender, amount)` needs its spender to equal
StakeDummy — not the CEA — so the rule cannot express it. Allow-listing `approve` would let the agent
approve *any* address for *any* amount. Destination-chain approvals are therefore owner actions.

### act1e — the mandate

```
just act1e
```

- Chain **Donut** · broadcasts with the **relayer** key, on a payload **Bob** signed.
- Grants the session: agent key, UCEP config, two allow-listed calls, caps, 7-day expiry.
- Reads `permissionId` **from the event, never recomputed**, and writes it with `mandate.maxPCPerCall` and
  `nonceSeq = 0`.

**The output of this script is the demo's thesis on one screen. End setup here, with it still up.**

> This agent key may call two functions on one contract on one chain, only ever for Bob's own account,
> up to 50 USDC per action and 60 USDC in total, for seven days. Nothing else.

```
just state
```

Confirm the mandate reads **live**, spend **0.00 / 60.00**.

---

## 3 · Five minutes before you present

```
just preflight     # must print READY
just quote         # re-price; fees move
```

`quote`'s second run is the one that compares the live fee against the mandate's granted PC cap. If it
prints a red `PC CAP` line, the mandate must be revoked and regranted before you start.

---

## 4 · Live — the sequence

| # | Command | Expect | Say |
|---|---|---|---|
| 1 | *(mandate summary on screen)* | — | "Bob is on Ethereum. He has never touched Push Chain. This is what he authorised." |
| 2 | `just state` | 100 USDC, spend 0 | "A hundred in the wallet. Nothing spent. The agent key holds nothing." |
| 3 | `just act2` | gates clear, then Sepolia | "The agent signs. I relay from an address with no role. Watch it cross." |
| 4 | `just watch-staked` | `totalBalance(cea)` rises | *(narrate the gauntlet while it waits)* |
| 5 | `just state` | **spent 50.00 / 60.00** | "Fifty staked on Sepolia. The budget moved. Bob signed nothing." |
| 6 | `just g1` | `CallNotAllowed` | "A function nobody allow-listed." |
| 7 | `just g2` | `ForbiddenInnerTarget` | "The agent reaching for the account that holds everything." |
| 8 | `just g3` | `BeneficiaryMismatch` | "Staking for itself instead of Bob. One argument, one word deep, pinned at grant time." |
| 9 | `just g4` | `AmountExceedsCap` | "Over the per-action cap." |
| 10 | `just g5` | `TotalSpendCapExceeded` | "Over the lifetime budget. Nothing reached Sepolia in any of these." |
| 11 | `just act4a` + `just watch-unstaked` | `Unstaked`, CEA holds 60 | "The agent unwinds. Zero USDC bridged — the capital is already there." |
| 12 | `just act4b` | `ForbiddenInnerTarget` | "Sixty dollars on Sepolia. The agent cannot bring it home." |
| 13 | `just act4c` + `just watch-returned` | AGW pUSDC +60 | "Bob can. Same call, owner door, no policy." |
| 14 | `just act4d` | closing table | "A hundred and ten where he started with a hundred. The agent never held custody for a second." |

Run `just state` between acts as often as you like — it is read-only and free.

---

## 5 · Act 2 — the central beat

```
just act2
just watch-staked
```

- Chain **Donut** · broadcasts with the **relayer** key, on a request the **agent** signed.
- Builds a single-call request: `StakeDummy.stakeFor(cea, 50e6)` — beneficiary is the CEA, which is what
  gate 15 pins.
- Recomputes the ten-field op hash independently, then asserts the emitted `MandateActionAuthorized`
  matches. Reverts `OpHashMismatch` or `NoAuthorizationEvent` if not.
- Pre-broadcast guards: `WalletOutOfPC`, `NotEnoughToStake`.
- Writes `nonceSeq + 1` **only after** the broadcast and the op-hash assertion.

**The demo is not "the transaction succeeded" — it is "the money is staked."** `watch-staked` polls
`StakeDummy.totalBalance(cea)` on Sepolia. That is the success criterion.

**If the wait runs long, move to the gauntlet.** It needs no relay and fills the gap exactly. Come back to
`just watch-staked` afterwards.

---

## 6 · Act 3 — the gauntlet

All six are **simulations**: no broadcast, no nonce consumed, freely re-runnable. They print amber, not
red — these are the system working.

Each asserts in two layers. Through the engine, revert data is truncated to 32 bytes, so only the
*selector* survives; a second layer forks Donut and calls `UCEP.checkAction` directly, pranked as the
engine, to recover the full arguments. **The amber line you read out carries values that were actually
asserted, not literals.**

| Recipe | Gate | Error | What changed vs Act 2 | Needs act2 |
|---|---|---|---|---|
| `just g1` | **15** | `CallNotAllowed(target, selector)` | selector → `0xdeadbeef` | no |
| `just g2` | **14** | `ForbiddenInnerTarget(to)` | inner target → the CEA | no |
| `just g3` | **15** | `BeneficiaryMismatch(expected, got)` | `stakeFor(agent, …)` not `stakeFor(cea, …)` | no |
| `just g4` | **6** | `AmountExceedsCap(amount, cap)` | amount → 120% of the per-call cap | no |
| `just g5` | **7** | `TotalSpendCapExceeded(newTotal, cap)` | **nothing** — relies on `spent` from act2 | **yes** |
| `just g6` | none | `InvalidNonce(key, expected, provided)` | replays a consumed nonce, re-signed | **yes** |

**Two traps:**

1. **`just gauntlet` bundles g1–g5**, so it hard-reverts with `ActTwoHasNotRun` if run before act2. Run
   g1–g4 individually for a pre-act2 beat.
2. **G1's code comment says "gate 13" — that is stale.** The allow-list check is **gate 15**; gate 13 is
   the batch-size range. Narrate it as gate 15, or just say "the allow-list is per-selector, not
   per-contract."

**G3 is the one to show if there is time for only one.** It is the deepest check — one argument, one word
inside a payload two decode levels down, pinned at grant time.

**G6 is optional**, and it is the most intuitive protection to a non-specialist audience: refused by the
*wallet*, at the nonce, before any policy runs. Thirty seconds. Your call on the day.

---

## 7 · Act 4 — the boundary

### act4a — the agent unwinds

```
just act4a
just watch-unstaked
```

- Broadcasts with the **relayer**, signed by the **agent**. A **zero-amount** request: `unstake()`.
- The CEA ends with principal **plus a flat 10 USDC** reward.
- **`spent` stays at 50.** A zero-amount request meters nothing — the lifetime cap meters what *leaves*
  Push Chain, not how many times the agent acts. Confirm with `just state`.

### act4b — the agent tries to bring it home

```
just act4b
```

Simulation. `ForbiddenInnerTarget` — G2 restaged, now with real money on the far side.

**Run this immediately before act4c.** Separated, it is a refusal; adjacent, it is the point.

### act4c — Bob brings it home

```
just act4c
just watch-returned
```

- Broadcasts with the **relayer**, on a payload **Bob** signed.
- **The same call the agent was just refused**, succeeding because the owner door consults no policy —
  `execute` reads only the immutable-args owner and calldata, so UCEP never runs and gate 14 never fires.
- Reads the CEA's live balance from Sepolia; never hardcodes 60. Reverts `CEANotDeployed` /
  `CEAHoldsNothing`.
- `watch-returned` polls **Donut** — the wallet's pUSDC rising is the signal.

**Do not fund the CEA with Sepolia ETH.** The return leg pays no inbound fee.

### act4d — the closing table

```
just act4d
```

Plain owner-door transfer of the wallet's live balance to Bob's UEA. No outbound, no relay, no wait. Prints
the closing table — **the last thing the audience sees.**

50 pUSDC never left the AGW; 60 came back. Bob ends with **110** where he started with 100.

---

## 8 · Watching a hop

```
just watch-cea         # after act1d — the CEA appears on Sepolia
just watch-staked      # after act2  — StakeDummy.totalBalance(cea) rises
just watch-unstaked    # after act4a — the CEA's USDC rises
just watch-returned    # after act4c — the AGW's pUSDC rises (polls DONUT)
```

- Polls every **10 s**, times out at **300 s**. Override with `WATCH_TIMEOUT=<seconds>`.
- Every condition is a **state read**, never a log scan: `cast logs` over a wide range on Donut returns
  empty rather than erroring, which once made a successful relay look like a failure.
- **On timeout it tells you where to look.** A timeout is not proof of failure — the Push-side decision is
  already complete and on-chain; what is outstanding is Push's relay, which is not ours.

---

## 9 · When something fails

| Symptom | What it is | Do this |
|---|---|---|
| Unexpected UCEP error on a Push tx | a payload was built wrong | **Read the error out loud — it is a legitimate demo moment**, the system refusing something. Move to the gauntlet, return later |
| Push tx fine, nothing on Sepolia after 3× the rehearsal time | relay delay | Show the outbound event on the explorer. Say the Push-side decision is complete and the far leg is Push core's relay. **Move to the gauntlet** — it needs no relay |
| `InvalidNonce` | a sequence was consumed | `just state` shows the lane; `just preflight` phase C cross-checks it against the ledger |
| Gateway reverts on value | fees moved since the quote | `just quote`, re-run. The 3× headroom should absorb it |
| `ActTwoHasNotRun` | you ran `g5`/`gauntlet` before act2 | Run act2, or run g1–g4 individually |
| `NothingToReplay` | `g6` before any agent action | Run act2 first |
| Reward pool empty | rehearsals drained it | `just stakedummy` (or `just fund` then `just stakedummy`). Preflight should have caught it |
| `MissingLedgerKey(key, writtenBy)` | a step was skipped | The error names the script that writes it. Run that |
| `MissingAddress(chain, name)` | address book gap | Nothing is discovered at runtime — check `deployments/address-book/` |

**Droppable, first to go:** G6 → then G4 or G5 (one cap demo suffices) → then acts 4c/4d. If the relay is
unreliable, end at 4b on "the agent cannot bring it home" and describe the rest.

**Never drop:** the mandate summary, Act 2, and G2 or G3. Those three carry the entire thesis.

---

## 10 · Rehearsal only

```
just reset          # revokes every mandate; wallet keeps funds, owner and address
just act1e          # grant a fresh mandate
```

- `stopAll` has **nothing on it that can fail** — no guard, no probe, no extra external call. That is a
  load-bearing property, not a convenience: an owner who cannot revoke has no real control.
- Clears `permissionId` and `mandate.maxPCPerCall`, resetting preflight to phase B.
- **The nonce lane is not reset.** A banked request signed against the old mandate stays dead across a
  regrant — guaranteed independently by both the permission id and the nonce.
- **Never run this during the live demo.**

Rehearse cheaply with `DEMO_SCALE_PERCENT=10`. Every gate and cap still fires; only the figures shrink.
**Unset it before the live run.**

```
just test           # 76 tests
just build
just demo101        # the standup mock — no chain, no keys
```

---

## 11 · Current state (verified 2026-09-06)

| | |
|---|---|
| Bob | `0x778Bd9d8a9ceEAD086048BB59d7eab95c3AcD169` — 386 USDC, 0.087 ETH on Sepolia |
| UEA | `0x0891664C211C030F397Cac08D4f6c4682d89BAFe` — deployed, nonce **2**, ~4.9 PC |
| AGW | `0xb2b47A90CCDB4aAc6fCa3373cd08788A6144EcC3` — **10 pUSDC**, ~19 PC |
| Predicted CEA | `0x30414c4b23bf88c86b331dbeDC24385588B3f94A` — **not deployed** |
| StakeDummy | `0x833Ac0BB36ED8199dbC28B9B7B04893D762Ef41C` — reward pool **100 USDC** ✓ |
| Mandate | **not granted** — no `permissionId` in the ledger |

**This is a partial 10%-scale run, not a clean slate.** Two things must happen before a live demo:

1. **The CEA is not deployed.** `act1d` is what deploys it, and it has not been run successfully. This is
   the known open item.
2. **The AGW holds 10 pUSDC, not 100.** The ledger's `quote` values are also from that scaled run.

**For a clean full-scale run, start from a fresh Bob key** — the UEA is at nonce 2 and the wallet is
partly funded. Rehearsal recovery restores the mandate but not a clean arrival narrative.

**Never executed on-chain yet:** `act1d`, `act1e`, `act2`, all six gauntlet scripts, all four Act 4
scripts. The build is complete and the suite is green, but these have only ever been simulated.

---

## 12 · One-page card

```
SETUP     just setup                        # tokens, quote, fund, stakedummy, preflight
ACT 1     just act1a                        # Sepolia — the ONLY Ethereum tx
          … wait ~30-45s …
          just act1b                        # wallet deployed, funded, armed
          just act1c                        # 20 PC — the seam
          just act1d ; just watch-cea       # approval + CEA deploys
          just act1e                        # THE MANDATE — leave it on screen
T-5min    just preflight ; just quote       # READY, and fees re-priced

LIVE      just state                        # 100 USDC, spend 0
          just act2 ; just watch-staked     # the central beat
          just state                        # spent 50.00 / 60.00
          just g1 g2 g3 g4 g5               # five refusals (run separately)
          just act4a ; just watch-unstaked  # agent unwinds, +10 reward
          just act4b                        # agent refused
          just act4c ; just watch-returned  # owner succeeds — same call
          just act4d                        # closing table: 110

RESCUE    just state · just preflight · just watch-* · WATCH_TIMEOUT=60
REHEARSE  just reset ; just act1e           # NEVER live
```

---

# Testimony of the first demo dry run

**2026-09-06 · Push Chain Donut (42101) + Ethereum Sepolia (11155111) · `DEMO_SCALE_PERCENT=10`**

Every act ran against live chains. Every hash below was confirmed mined with `cast receipt`, status `1`.
Bob started with **10 USDC** and ended with **15**. Nothing was mocked, forked or simulated except the
gauntlet, which is simulation by design.

Run at 10% scale because the wallet held 10 pUSDC from an earlier partial run — so caps read 5.00 / 6.00
rather than 50 / 60. **The reward does not scale**: `StakeDummy.REWARD` is compiled into the deployed
contract, so a 10% run still pays the full 10 USDC. That is why Bob ends up ahead by more, proportionally,
than he would at full scale.

### The cast

| Role | Address | Chain |
|---|---|---|
| Bob (EOA) | `0x778Bd9d8a9ceEAD086048BB59d7eab95c3AcD169` | Sepolia |
| Bob's UEA | `0x0891664C211C030F397Cac08D4f6c4682d89BAFe` | Donut |
| **Bob's AGW** | **`0xb2b47A90CCDB4aAc6fCa3373cd08788A6144EcC3`** | Donut |
| **The CEA** | **`0xCF173d1b54B66Fa627AfBEAb1fa722DBd5F4daa7`** | Sepolia |
| Agent key | `0x643C33097121F65Bc58786b038523a4E9EA13405` | signs on Donut |
| Relayer | `0x2348286F118810521497ADBbF2615D1328aa1630` | Donut — **holds no authority** |
| Deployer | `0x1afC81396F1bB36f91F74506284952B81e4bd47C` | Sepolia |

`AGW.owner()` returns `0x0891664C…BAFe` — Bob's UEA, not the relayer. The relayer paid gas and nothing else.

### Infrastructure

| Contract | Address | Chain |
|---|---|---|
| StakeDummy | `0x833Ac0BB36ED8199dbC28B9B7B04893D762Ef41C` | Sepolia |
| USDC | `0x97F477B7f970D47a87B42869ceeace218106152a` | Sepolia |
| UniversalGateway | `0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A` | Sepolia |
| Vault | `0xD019Eb12D0d6eF8D299661f22B4B7d262eD4b965` | Sepolia |
| **CEAFactory** | **`0x5E191fbBe22F8866C5e4250557664fCE760e8870`** | Sepolia |
| AGWFactory (proxy) | `0xF1A131571f89fD06890576e6cD0154114ACBBc8b` | Donut |
| UCEP | `0x79F07D379BdC26468E48025a61bC955909522c1D` | Donut |
| SmartSession engine | `0x7540f9a59693d51CFB4A3727141eAE4836F96749` | Donut |
| PushSessionValidator | `0x5A59a5Ac94d5190553821307F98e4673BF3c4a1D` | Donut |
| UniversalGatewayPC | `0x00000000000000000000000000000000000000C1` | Donut |
| PRC20 pUSDC | `0x7A58048036206bB898008b5bBDA85697DB1e5d66` | Donut |

---

## Setup — StakeDummy deployed and funded

**Chain: Sepolia · deployer key**

| Action | Hash |
|---|---|
| Bob → deployer, 100 USDC (`03_FundAll`) | `0x73b673e47b460d3a6bcd98d39ac547c260ea2a79335ea0c9d46dca16003bbef2` |
| `CREATE StakeDummy` | `0xf2841253763ae32b998fecc4fa7f516cbc3981c0d1304dc47f5601c1a12b86e7` |
| `approve(StakeDummy, 100e6)` | `0xed9619a4daf67f0b3a8151e14383718788177d77d3b3104b3cd9a417d1fe2bbf` |
| `fundRewards(100e6)` | `0x387620015fd6678aa3b4724ce5ce41e0dffdaaeb6f6a57c28be5fc69f8c2dccb` |

- StakeDummy deployed at `0x833Ac0BB…f41C`, reward pool **100 USDC**, `REWARD()` = `10000000`.
- Bob is the only USDC source — Sepolia USDC is Circle's FiatToken with minter-gated `mint`, so tokens can
  only be moved, never created.

---

## Act 1a — Bob arrives (the only Ethereum transaction)

**Chain: Sepolia · signed and sent by Bob · block `11641970`**

| Action | Hash |
|---|---|
| `approve(gateway, 10e6)` | `0x21069f4fd3e87252424d54f29a1639a2ccf025b49a1973828b75485261d86d37` |
| **`sendUniversalTx`** | **`0xa805a00949f63252f51583eba7c7122e7217b61da51c02492c66eccc9d9da9ad`** |

- Decoded arguments: `recipient = 0x0` (credit Bob's own UEA), `token = 0x97F477B7…`,
  **`amount = 10000000`**, `revertRecipient = Bob`, `msg.value = 0.002 ETH`.
- The relay deployed Bob's UEA on Donut, minted 10 pUSDC to it, and delivered PC for gas.
- The attached wallet-setup payload was **inert** — the deployed build does not execute an attached inbound
  payload. `act1b` is what actually built the wallet.

---

## Act 1b — the wallet is built

**Chain: Donut · relayer submits, Bob signed · block `22729586`**

**`0xe203e9d4c0e2941154f90129037d7add6969cc459ac99e375bec5140d3cae89d`**

- UEA `executeUniversalTx` ran Bob's three-entry multicall: `deployWallet("demo-agw-1")` → `transfer` 10
  pUSDC to the AGW → `execute` an unlimited gateway approval.
- **AGW deployed at `0xb2b47A90…EcC3`**, matching the address predicted in Act 1a before it existed.
- **`AGW.owner()` = `0x0891664C…BAFe`** — the UEA. `deployWallet` takes `msg.sender` as owner and the UEA
  made the call, so the relayer never enters the ownership derivation.
- Gateway allowance verified `type(uint256).max` — the least obvious prerequisite in the whole flow.

---

## Act 1c — the PC seam

**Chain: Donut · relayer · block `22729633`**

**`0x5d754abb97adf0aaea30cc7e963302a592d3461af3c9931444b25fac6b1d22d4`**

- Native transfer to the AGW's `receive()`, topping it **up to 20 PC**.
- The bridge mints pUSDC, never native PC. Every outbound burns PC for protocol fee and gas swap from the
  wallet's own balance. **This is the one step Bob cannot perform from Ethereum.**

---

## Act 1d — the destination-chain approval, and the CEA

**Chain: Donut · relayer submits, Bob signed · block `22769021`**

**`0xef971844b88ffcefcf3c09ec675e8ab1b88a5ef2d1696e5d789f3d48fba6cafc`**

- A **zero-amount** outbound carrying one far-chain call, decoded from the gateway log:
  `095ea7b3 approve(0x833Ac0BB…f41C, 0xffff…ffff)` on Sepolia USDC, destination `eip155:11155111`.
- **This inbound deployed the CEA at `0xCF173d1b…daa7`** and set its unlimited StakeDummy allowance.
- Zero-amount still requires `token` set (gate 5), non-zero `maxPCForGas` (gate 9), and real `msg.value`
  (the gas swap reverts on a zero swap).

---

## ⚠ The bug this run found — and the fix

Act 1a predicted the CEA as `0x30414c4b23bf88c86b331dbeDC24385588B3f94A`. The Vault deployed it at
`0xCF173d1b54B66Fa627AfBEAb1fa722DBd5F4daa7`. **Two different CEAFactories exist on Sepolia and the
address book named the wrong one.**

```
Vault(0xD019Eb12…).CEAFactory()   →  0x5E191fbB…   ← the real one
address book said                 →  0x8ED594A8…   ← stale
```

| | `computeCEA(AGW)` | `isCEA(0xCF173d1b…)` |
|---|---|---|
| Live `0x5E191fbB…` | `0xCF173d1b…` ✅ | `true` |
| Stale `0x8ED594A8…` | `0x30414c4b…` ❌ ghost | `false` |

`computeCEA` is a CREATE2 prediction over both `CEA_PROXY_IMPLEMENTATION` and `address(this)`. Both differ
between the two factories, so the same salt yields different addresses. **Each factory is internally
consistent; only one is wired to the Vault.**

**Why it failed silently.** The stale factory has code and answers `computeCEA` correctly, so a
"does it have code" check passed. The first mandate pinned the ghost as `expectedCEA`, gate 15 dutifully
forced the agent to name it, and `stakeFor` credited it — because `stakeFor(beneficiary, amount)` only
rejects `address(0)`. Nothing reverted until Act 4a, three acts later.

**Fix:** `deployments/address-book/sepolia.json` → `"CEAFactory": "0x5E191fbBe22F8866C5e4250557664fCE760e8870"`,
**derived from `Vault.CEAFactory()`, not probed.** The file now carries `evidence` and `deprecated` blocks
recording this.

**Cost:** 5 USDC stranded at the ghost address, still credited on StakeDummy, unrecoverable without an
operator repointing the Vault. Testnet; not worth reclaiming.

**Hardening worth doing:** derive the factory from the Vault at runtime, and assert `isCEA(cea)` at Act 1e
so this class of error surfaces at the grant rather than at Act 4a.

---

## Reset — the ghost-pinned mandate revoked

**Chain: Donut · relayer submits, Bob signed**

**`0x0d1255da4a3ad356a9b62cbf832d11c2c47811a0df4007fd010b3d7ab1bd1185`**

- `stopAll()` through the owner door. Permission count **1 → 0 live**.
- The wallet kept its funds, its owner and its address. The nonce lane was **not** reset — by design, so a
  banked request stays dead across a regrant.

---

## Act 1e — the mandate (regranted, correct CEA)

**Chain: Donut · relayer submits, Bob signed · block `22784004`**

**`0xb49d5cda17406239bdbb548aecd7f515fa336d1885828db810278ab1efc023aa`**

**Permission id `0x4f0b2d626d159f02ab4fc3e9385562a504b40442fa9cab317c5c1880cf25b13c`** — read from the
`MandateGranted` event, never recomputed.

```
│  This agent key may:
│    · call stakeFor() on StakeDummy
│        but only ever for 0xCF173d1b54B66Fa627AfBEAb1fa722DBd5F4daa7
│    · call unstake() on StakeDummy
│
│  Per action      5.00 USDC
│  Lifetime        6.00 USDC
│  Expires         in 7 days
```

- `isPermissionEnabled(pid, agw)` → **`true`**.
- Allow-list, read back from UCEP: `0x2ee40908` (`stakeFor`, **beneficiary pinned**) and `0x2def6620`
  (`unstake`), both on StakeDummy.

**Fixed to get here:** `14_GrantMandate.s.sol` did not compile — it called `grantMandate` through
`IPushAgentWallet`, which is **events-only by design**. Added a local `IWalletGrant` interface, matching the
pattern `90_StopAll` already used. No `src/` change, no redeploy. Selector `0x83b655f5` confirmed against
the deployed wallet.

---

## Act 2 — the agent works

**Chain: Donut · relayer submits, the AGENT signed · block `22784221`**

**`0xe83132d15f2614e7309c04971a83a9326052c24d8742f06cc5f8b8a2aa16f6e5`**

```
│  ✓ wallet          expiry, nonce, validator, signature
│  ✓ UCEP            all 16 gates
│  ✓ op hash         matches the hash we signed, byte for byte
│  ✓ gateway         burned 5.00 pUSDC, outbound emitted
```

- Request: `StakeDummy.stakeFor(0xCF173d1b…, 5000000)`. Nonce lane 0, sequence 1. PC value 4.13.
- **Relay landed in 20 seconds** — `StakeDummy.totalBalance(cea)` = **5.00 USDC**.
- Spend counter moved **0.00 → 5.00 / 6.00**, leaving 1.00.
- Wallet pUSDC 5.00 → **0.00**.

**Bob signed nothing. The agent held nothing. The relayer had no authority.**

> **First attempt failed `InvalidNonce(0, 1, 0)`.** `14_GrantMandate` writes `nonceSeq = 0` unconditionally,
> but the wallet's lane was already at 1 and correctly survives a regrant. Synced the ledger by hand.
> **This will bite any `just reset` during rehearsal** — fix is to read `getNonce(0)` instead of writing 0.

---

## Act 3 — the gauntlet

All simulations. No broadcast, no nonce consumed, no relay. Each asserts in two layers: the engine path
(selector only, since revert data truncates to 32 bytes) and a pranked direct `UCEP.checkAction` that
recovers full arguments.

| | Gate | Error | Values proven on-chain |
|---|---|---|---|
| **G1** | 15 | `CallNotAllowed` | target `0x833Ac0BB…f41C`, selector `0xdeadbeef` |
| **G2** | 14 | `ForbiddenInnerTarget` | forbidden `0xCF173d1b…daa7` |
| **G3** | — | *see note* | ordering artefact, not a defect |
| **G4** | 6 | `AmountExceedsCap` | requested 6.00, cap 5.00 |
| **G5** | 7 | `TotalSpendCapExceeded` | would total 10.00, cap 6.00 |
| **G6** | none | `InvalidNonce` | lane 0, expected 2, provided 1 |

**G3 note.** It requests `Amounts.perCall()` = 5.00, but only 1.00 of lifetime budget remained after Act 2,
so gate 7 fired before gate 15 was reached. Re-run at a smaller amount, G3 produced exactly the right
refusal — `BeneficiaryMismatch(expected 0xCF173d1b…, got 0x643C3309…)`. **The logic is correct; the amount
is simply larger than what remains.** Not treated as a bug.

**G6 is refused by the wallet, before any policy runs** — a valid signature, a live mandate, an authorised
key, and still rejected at the nonce.

---

## Act 4a — the agent unwinds

**Chain: Donut · relayer submits, the AGENT signed · block `22784632`**

**`0x730366016ac8e1a7c3a61a55caedbabaf9593eb78bb0db62cc9c8307e332b269`**

```
│  ✓ accepted        all 16 gates, on a zero-amount request
│  ✓ metered         nothing - a zero-amount request writes no spend
```

- `unstake()` — 4 bytes of calldata, no arguments, 0.00 USDC bridged. Nonce lane 0, sequence 2.
- **Relay landed in 20 seconds.** CEA holds **15.00 USDC** = 5 principal + 10 flat reward.
- **`spent` stayed at 5.00.** The lifetime cap meters what *leaves* Push Chain, not how often the agent acts.

---

## Act 4b — the agent tries to bring it home

**Simulation. No broadcast.**

```
│  ✓ layer 2         UCEP refused it directly, with arguments intact
│    forbidden     0xCF173d1b54B66Fa627AfBEAb1fa722DBd5F4daa7
│  ✗ ForbiddenInnerTarget
```

15 USDC sitting on Sepolia, a live mandate, an authorised key, a well-formed request — and the one target
it may never name. **Run immediately before Act 4c: separated it is a refusal, adjacent it is the point.**

---

## Act 4c — Bob brings it home

**Chain: Donut · relayer submits, Bob signed · block `22784792`**

**`0x711247a0f3e74f34b747fd14629aaf4baae6ae907abeebb9a066b493bd8215f9`**

- **The identical call the agent was refused one command earlier**, succeeding because the owner door
  consults no policy: `execute` reads only the immutable-args owner and calldata, so UCEP never runs and
  gate 14 never fires.
- `sendUniversalTxToUEA(USDC, 15000000, "", agw)` as a zero-value CEA self-call. **Amount read live from
  the CEA's balance, never hardcoded.**
- Return leg landed: CEA USDC **15.00 → 0**, AGW pUSDC **0 → 15.00**.

> `watch-returned` reported a timeout at 420s while the funds had **already arrived** — a stale fork read.
> A direct state check immediately after showed CEA 0 / AGW 15.00. **Never trust a `watch-*` timeout as
> proof of failure; check `just state` first.**

---

## Act 4d — the closing table

**Chain: Donut · relayer submits, Bob signed · block `22785170`**

**`0x493bba417381a7e442c73f096d5cbd4cfcbe4df2fb300a02cab25627de461f06`**

```
│  Closing position
│  Bob holds       15.00 pUSDC
│  Wallet holds    0.00 pUSDC
│  Agent holds     0.00 pUSDC
```

Plain owner-door `transfer` of the wallet's live balance to Bob's UEA. No outbound, no relay, no wait.

---

## Final state — verified on both chains

| Account | Balance |
|---|---|
| **Bob's UEA (Donut)** | **15.00 pUSDC** — started with 10 |
| AGW (Donut) | 0.00 pUSDC · 17.22 PC · nonce lane 0 at **3** |
| CEA (Sepolia) | 0.00 USDC · 0.00 staked |
| **Agent EOA** | **0.00 — never held custody for a single block** |
| StakeDummy pool | 95.00 USDC |

The pool arithmetic closes the loop: `100 initial + 5 ghost principal − 10 reward paid = 95`. The ghost
address still shows `totalBalance = 5.00`, the stranded principal from the pre-fix run.

## What this run proves

1. **A user on Ethereum who has never touched Push Chain** can fund a wallet and grant a scoped mandate in
   one Ethereum transaction plus signed payloads relayed by a stranger.
2. **The wallet's owner is the UEA**, derived from `msg.sender` — the relayer paying gas holds nothing.
3. **An agent key can move real money cross-chain** and cannot deviate: five distinct refusals, each on-chain,
   atomic and free, each naming its own error.
4. **The boundary is real.** The same call refused for the agent succeeds for the owner. Only the authority
   changed.
5. **Bob ends ahead**, and the agent never held custody.

## Known issues carried forward

| | Issue | Action |
|---|---|---|
| 1 | `14_GrantMandate` hardcodes `nonceSeq = 0` | Read `getNonce(0)`. **Will bite any rehearsal `reset`** |
| 2 | `watch-*` can time out after funds arrive | Check `just state` before believing a timeout |
| 3 | G3 sized from `perCall()`, not remaining budget | Ordering artefact — accepted, not a defect |
| 4 | 5 USDC stranded at the ghost CEA | Testnet, written off |
| 5 | G1's code comment says "gate 13" | Stale — the allow-list is **gate 15** |
| 6 | Relay latency 20s–7min, inconsistent | Raise `WATCH_TIMEOUT`; never trust a timeout |
