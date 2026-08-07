# Documentation

How the Push Agentic Wallet contracts work, and the role each one plays.

These documents describe the contracts as they currently exist and are maintained
alongside them — when a contract changes, its document changes in the same pull request.

## Read in this order

| # | Document | Covers |
|---|---|---|
| 1 | **[architecture.md](./architecture.md)** | **Start here.** The problem, the design, the full system diagram, and the end-to-end flow showing which contract is touched at each step |
| 2 | [agent-wallet.md](./agent-wallet.md) | `PushAgentWallet` — the account that holds funds and performs every action |
| 3 | [factory.md](./factory.md) | `AgentWalletFactory` — deterministic one-per-owner deployment |
| 4 | [modules.md](./modules.md) | `ACPActionPolicy`, `PushSessionValidator`, plus the adopted `SmartSession` engine and limit policies |
| 5 | [libraries-and-types.md](./libraries-and-types.md) | Encoding libraries, mirrored Push Chain structs, shared errors, interfaces |

## The one-paragraph version

A user has **one** smart account (`PushAgentWallet`), owned for life by their existing UEA.
They grant an AI agent a **mandate**: a session key on that account, scoped and expiring.
The agent can compose and submit cross-chain transactions, but every action must survive a
chain of policy checks — per-call and lifetime spend caps, a time window, a gas budget, a
target allowlist, and an action policy that forces the beneficiary of any deposit to be the
wallet's own CEA. Because the **wallet** is always `msg.sender` at the gateway, the
resulting position is always owned by the user. The agent moves value without ever
custodying it; the owner can revoke everything at any time, and a designated **guardian**
can pause every session in a single Push transaction.

## What changed in v2

v1 gave each mandate its own wallet. That meant a new CEA on every external chain per
mandate, which fragmented protocol rewards, approvals and identity. **v2 collapses the fleet
into one wallet per user**, and a mandate becomes a session rather than a contract.

The consequence is worth stating plainly, because it changes how you should read these docs:
**isolation is now configured, not structural.** v1 could say "two mandates cannot touch each
other because they are different contracts." That claim is withdrawn. The replacement is the
**Mandate Bound** — a table of caps readable directly from policy state, described in
[architecture.md §8.1](./architecture.md#81-one-wallet-per-user).

## Conventions

Diagrams are Mermaid and render natively on GitHub. Colour is consistent throughout:

- **green** — contracts we build, and successful paths
- **blue** — adopted or external components, and neutral structure
- **red** — failure paths and attacker-controlled attempts
- **yellow** — existing Push Chain infrastructure
