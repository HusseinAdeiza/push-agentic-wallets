# UX brief — what Bob chooses

**For:** design team
**What this covers:** the choices a user makes when hiring an AI agent, and what is fixed by the protocol so you don't design screens for it.
**What this is not:** a technical spec. No code here.

---

## The situation in four lines

Bob is on Ethereum. He has 102 USDC. He wants an AI agent to find the best lending vault and deposit 100 USDC for him.

He has never used Push Chain and never will — it happens underneath.

**He signs once.** Everything below is configured before that signature, in our UI. There is no second chance to correct it.

The agent can spend within the limits Bob sets. It can never take his money.

---

## What Bob chooses

### 1. Which agent

Show a ranked list. Each agent needs:

- Name
- Reputation score (0–10,000 — display as a rating or percentage, not the raw number)
- Jobs completed and success rate
- Fee
- How long they take (SLA)
- **Key type badge** — see note below

**Key type badge.** Some agents are "Solana-native." This is worth surfacing because no other wallet can do it, but don't use the words `Ed25519` or `secp256k1` in the UI. A small badge is enough. It costs Bob nothing and changes nothing about his flow.

### 2. How much money

Three separate numbers. They do different jobs and users conflate them, so label carefully.

| Choice | What it means to Bob | Sensible range |
|---|---|---|
| **Total for this mandate** | The most the agent can ever spend, across every job | 10–500 USDC |
| **Max per transaction** | The most it can move in one go | 10 USDC – the total |
| **Gas budget** | Small amount for network fees | 1–50, default 5 |

**Design note.** "Max per transaction" is the one people skip. It exists so that if an agent is compromised, it can't drain everything in a single action — Bob gets a chance to notice and revoke. Worth one line of helper text.

Gas budget should probably be hidden behind "advanced" with a good default. Nobody wants to think about it.

### 3. How long

- **Expires in** — 1 to 72 hours, default 24
- **Max executions** — 1 to 20, default 5

When it expires, the agent simply stops. No transaction, no cost, no action from Bob.

### 4. Where the agent may deposit

A checklist of lending protocols. Today:

- Aave v3
- Morpho Blue
- Spark

Show current yield next to each. Bob ticks the ones he's comfortable with; the agent picks among them.

**Constraint:** Bob cannot type in his own protocol address. Only protocols we have verified can appear. Design this as a fixed checklist, never a free-text field.

---

## Presets

Most people should never see a slider. Lead with three options:

| Preset | Total | Per transaction | Duration | Protocols | Executions |
|---|---|---|---|---|---|
| **Conservative** | 50 USDC | 10 USDC | 6 hours | Aave only | 3 |
| **Balanced** *(default)* | 100 USDC | 100 USDC | 24 hours | Aave + Morpho | 5 |
| **Custom** | — | — | — | — | — |

"Custom" opens everything above. Expect fewer than 1 in 10 users to touch it.

---

## What Bob does NOT choose

Design nothing for these. They are decided by the protocol, and offering them would be misleading.

| Not a choice | Why |
|---|---|
| **Where deposits land** | Always Bob's own account, calculated from his identity. The agent cannot change it — this is the core safety property |
| **Which modules to install** | There is exactly one, it installs silently. A "choose your modules" screen would offer one real option |
| **What the agent may call** | Exactly one function. Not configurable |
| **Technical addresses** | Calculated for him. Show them read-only for reassurance; never editable |

---

## What to tell Bob, and how

The single most important thing to communicate:

> **The agent gives instructions. It never holds your money.**

Everything else is detail. If a user comes away understanding only that, the design worked.

Three promises worth stating plainly on the review screen:

- **Revoke any time** — one signature, takes effect immediately
- **Withdraw yourself** — Bob can always get his money out, with or without the agent
- **Expires on its own** — no action needed when the time runs out

Avoid: "escrow", "policy", "session key", "mandate", "module", "validator". All internal words. Bob is *hiring an agent with a spending limit*.

---

## Screens and states to design

**Happy path**

1. Connect wallet and describe what you want
2. Pick an agent
3. Set limits (preset or custom)
4. Review and sign — one signature
5. Working — agent is doing the job
6. Done — here's your position

**Also needed**

- **No agents available** for what Bob asked
- **Not enough USDC** — needs the amount plus the fee
- **Signature rejected** — nothing happened, nothing lost, try again
- **Job failed** — money never left Bob's control, fee refunded
- **Active mandate** — a place to see what's running and revoke it
- **Expired** — what it looks like afterwards, and how to renew

---

## One open question for engineering

There is currently no way to list "all mandates Bob has created" without knowing their names in advance. If the design calls for a dashboard of active mandates — and it probably should — flag it early. It needs building.

---

## Reference — for engineers reading this

Each choice maps to one contract field, in case you need to trace something:

| UI control | Contract field |
|---|---|
| Total for mandate | `maxAmountTotal` |
| Max per transaction | `maxAmountPerCall` |
| Gas budget | `maxPCPerCall` |
| Expires in | `TimeFramePolicy.validUntil` |
| Max executions | `UsageLimitPolicy.limit` |
| Protocol checklist | `allowedCalls[]` |
| Agent choice | `sessionValidatorInitData` |
