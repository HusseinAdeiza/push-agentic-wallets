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

A user grants an AI agent a **session key** on a dedicated smart account
(`PushAgentWallet`) owned by their existing UEA. The agent can compose and submit
cross-chain transactions, but every action must survive a chain of policy checks — spend
cap, time window, target allowlist, and an action policy that forces the beneficiary of
any deposit to be the wallet's own CEA. Because the **wallet** is always `msg.sender` at
the gateway, the resulting position is always owned by the user. The agent moves value
without ever custodying it, and the owner can revoke everything instantly.

## Conventions

Diagrams are Mermaid and render natively on GitHub. Colour is consistent throughout:

- **green** — contracts we build, and successful paths
- **blue** — adopted or external components, and neutral structure
- **red** — failure paths and attacker-controlled attempts
- **yellow** — existing Push Chain infrastructure
