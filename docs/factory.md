# AgentWalletFactory

`src/AgentWalletFactory.sol` · deterministic deployer

---

## 1. What this contract does

`AgentWalletFactory` creates `PushAgentWallet` accounts. That is its entire job.

It holds no funds, has no admin, and exposes no configuration. The wallet implementation
address is fixed at construction and can never change. Beyond deployment it keeps one
piece of state: a registry mapping `(owner, mandateId)` to the wallet that was created for
it.

It is the smallest contract in the system, and that is deliberate — a factory with admin
powers would be a permanent lever over every wallet it ever created.

## 2. Why it matters

Three properties that the rest of the system depends on.

**The caller is always the owner.** `deployAgentWallet` takes the owner from `msg.sender`
and never as a parameter. There is no `deployFor(address owner, ...)` variant and one must
never be added — it would let an attacker deploy a wallet on a user's behalf, potentially
pointing at an implementation the user never chose.

**Addresses are known before deployment.** Because deployment is `CREATE2` with a salt
derived from `(owner, mandateId)`, the address can be computed in advance. This is what
makes the whole inbound flow work as a single signed payload: the SDK computes where the
wallet *will* be, then builds one transaction that deploys it, configures it, and funds it.

**One wallet per mandate.** The salt includes `mandateId`, so each mandate gets a separate
account with separate funds and its own CEA on the destination chain.

## 3. Role in the system

```mermaid
graph TB
    UEA["User's UEA<br/>(the caller)"] -->|"deployAgentWallet(mandateId)"| F["AgentWalletFactory"]
    F -->|"cloneDeterministic(salt)"| W["PushAgentWallet clone"]
    F -->|"initialize(msg.sender)"| W
    F -->|"records"| REG["walletOf[owner][mandateId]"]
    IMPL["implementation<br/>(immutable, set at construction)"] -.->|"clones delegate to"| W

    style F fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style W fill:#1e3a5f,stroke:#3b82f6,color:#e8f1fb
```

## 4. Address derivation

```
salt    = keccak256(abi.encode(owner, mandateId))
address = CREATE2(factory, salt, EIP-1167 proxy bytecode for implementation)
```

Both inputs matter. Changing either produces a completely different address:

```mermaid
graph LR
    subgraph inputs["Inputs"]
        O1["owner = Bob"]
        M1["mandate = 'yield'"]
        O2["owner = Bob"]
        M2["mandate = 'trading'"]
        O3["owner = Alice"]
        M3["mandate = 'yield'"]
    end

    O1 --> S1["salt A"] --> W1["0xbobagw"]
    M1 --> S1
    O2 --> S2["salt B"] --> W2["0xbobagw2"]
    M2 --> S2
    O3 --> S3["salt C"] --> W3["0xalicagw"]
    M3 --> S3

    style W1 fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style W2 fill:#1e3a5f,stroke:#3b82f6,color:#e8f1fb
    style W3 fill:#3f3a1e,stroke:#eab308,color:#fbf7e8
```

The same mandate id under two different owners yields two unrelated wallets, so mandate
ids need not be globally unique — only unique per user.

## 5. Deployment flow

```mermaid
sequenceDiagram
    participant U as Owner UEA
    participant F as AgentWalletFactory
    participant W as New clone

    U->>F: deployAgentWallet(mandateId)

    Note over F: already deployed for this pair?
    alt already exists
        F-->>U: revert WalletAlreadyDeployed
    else fresh
        Note over F: salt = keccak256(owner, mandateId)
        F->>W: cloneDeterministic(salt)
        F->>W: initialize(msg.sender)
        Note over W: owner set permanently
        Note over F: walletOf[owner][mandateId] = wallet
        F-->>U: wallet address
    end
```

Creation and initialization happen in the **same transaction**. This is what makes the
wallet's unguarded `initialize` safe: the address holds no code until `cloneDeterministic`
returns, and by the time the transaction ends the owner is already set. There is no window
for anyone to claim it.

## 6. Why counterfactual addresses matter

The user signs **once**, on their origin chain. Everything on Push Chain has to be
composed in advance from that single signature, which is only possible if the wallet's
address is known before it exists.

```mermaid
sequenceDiagram
    participant SDK
    participant F as Factory
    participant Chain as Push Chain

    Note over SDK: before anything is deployed
    SDK->>F: computeAgentWallet(owner, mandateId)
    F-->>SDK: 0xbobagw (does not exist yet)

    Note over SDK: build ONE payload that:<br/>deploys · configures · funds 0xbobagw

    SDK->>Chain: submit the whole thing
    Note over Chain: address matches the prediction exactly
```

Without this, funding would need a second transaction after deployment, and the user would
have to sign twice.

## 7. The registry

```solidity
mapping(address owner => mapping(bytes32 mandateId => address wallet)) public walletOf;
```

Two purposes. It makes deployment idempotent-by-rejection — a repeat call for the same
pair reverts with `WalletAlreadyDeployed` and reports the existing address, rather than
failing opaquely at the `CREATE2` level. And it gives off-chain consumers a direct lookup
without needing to replay the address derivation.

`isDeployed` is the convenience predicate over the same map.

## 8. Function reference

| Function | Access | Purpose |
|---|---|---|
| `deployAgentWallet(bytes32 mandateId)` | anyone; caller **is** the owner | Deploy and initialize a wallet |
| `computeAgentWallet(address owner, bytes32 mandateId)` | view | Predict the address before deployment |
| `isDeployed(address owner, bytes32 mandateId)` | view | Whether that pair has a wallet |
| `walletOf(address owner, bytes32 mandateId)` | view | The wallet address, or zero |
| `WALLET_IMPLEMENTATION()` | view | The immutable implementation |

### Events and errors

| Name | Meaning |
|---|---|
| `AgentWalletDeployed(wallet, owner, mandateId)` | A wallet was created |
| `WalletAlreadyDeployed(owner, mandateId, existing)` | That pair already has a wallet |
| `ZeroAddress` | Construction was attempted with a zero implementation |

## 9. Operational notes

**The implementation must be sealed.** After deploying the implementation contract, it
should immediately be initialized to a burn address. Otherwise the logic contract sits
uninitialized and anyone could claim ownership of it directly. Clones are unaffected by
the implementation's own storage, so sealing costs nothing functionally. The deployment
script does this and asserts a second initialization attempt reverts.

**The factory is not upgradeable and holds no privileges.** Once deployed it can only ever
mint clones of the one implementation it was constructed with. Pointing at a new
implementation means deploying a new factory; existing wallets are untouched by that, which
is the intended property — nobody can change the logic under funds that already exist.

## 10. Related documents

- [architecture.md](./architecture.md) — how the whole system fits together
- [agent-wallet.md](./agent-wallet.md) — the contract this factory deploys
- [modules.md](./modules.md) — what gets installed into a wallet after deployment
