# Modules

The validator, the policies, and the session engine — everything that decides whether a
delegated action is allowed.

- `src/policies/ACPActionPolicy.sol` — built by us
- `src/validators/PushSessionValidator.sol` — built by us
- `SmartSession` and five limit policies — adopted unmodified

---

## 1. The module landscape

The wallet itself deliberately knows nothing about sessions, spend caps, or expiry. All of
that lives in modules, so the account stays small and the enforcement layer can evolve
without touching the contract that holds the money.

```mermaid
graph TB
    W["PushAgentWallet"] -->|"installed as type 1"| SS["SmartSession<br/>the session engine"]

    SS -->|"who signed this?"| PSV["PushSessionValidator<br/>type 7 · stateless"]
    SS -->|"is this action allowed?"| ACP["ACPActionPolicy"]
    SS -->|"within limits?"| LIM["ERC20SpendingLimit<br/>TimeFrame · ValueLimit<br/>UsageLimit · ContractWhitelist"]

    PSV -->|"Ed25519"| USV["USV precompile<br/>0xEC00...0001"]

    style ACP fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style PSV fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style SS fill:#1e3a5f,stroke:#3b82f6,color:#e8f1fb
    style LIM fill:#1e3a5f,stroke:#3b82f6,color:#e8f1fb
```

| Module | Origin | Question it answers |
|---|---|---|
| `SmartSession` | adopted | Is there a valid session, and does every check pass? |
| `PushSessionValidator` | **ours** | Did the session key actually sign this hash? |
| `ACPActionPolicy` | **ours** | Is this specific cross-chain action permitted? |
| `ERC20SpendingLimitPolicy` | adopted | Has the cumulative spend cap been exhausted? |
| `TimeFramePolicy` | adopted | Are we inside the session's validity window? |
| `ValueLimitPolicy` | adopted | Is the native value within bounds? |
| `UsageLimitPolicy` | adopted | Has the session been used too many times? |
| `ContractWhitelistPolicy` | adopted | Is the target on the allowlist? |

Adopted contracts are deployed **unmodified** and pinned to an exact upstream commit. They
are audited upstream; forking them would discard that.

---

# Part I — `ACPActionPolicy`

## 2. What it does

`ACPActionPolicy` authorises exactly one kind of action: the wallet calling
`UniversalGatewayPC.sendUniversalTxOutbound`.

It decodes the outbound request, walks the multicall payload that will run on the
destination chain, and enforces that every inner call is on the allowlist and that the
beneficiary of any deposit is **the wallet's own CEA**.

## 3. Why it matters

This is the contract that makes provider custody structurally impossible.

Every other policy limits *how much* or *how often*. This one limits *where the value ends
up*. Without it, an agent operating entirely within its spend cap and time window could
still deposit the user's funds into a position owned by the agent.

```mermaid
graph LR
    subgraph without["Without the beneficiary check"]
        A1["agent composes<br/>supply(asset, amount, onBehalf = AGENT)"] --> A2["within spend cap ✓<br/>within timeframe ✓"] --> A3["position owned<br/>by the agent"]
    end

    subgraph with["With rule R9"]
        B1["agent composes<br/>supply(asset, amount, onBehalf = AGENT)"] --> B2["beneficiary != committed CEA"] --> B3["revert<br/>BeneficiaryMismatch"]
    end

    style A3 fill:#4a1d1d,stroke:#ef4444,color:#fbe8e8
    style B3 fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
```

## 4. Configuration

Each `(configId, multiplexer, account)` triple gets its own config, set when the owner
grants the session:

| Field | Meaning |
|---|---|
| `destChainHash` | Destination chain identifier, e.g. `keccak256("eip155:1")` |
| `expectedCEA` | The wallet's CEA on that chain — **the required beneficiary** |
| `asset` | The only PRC20 token this session may move |
| `maxAmountPerCall` | Ceiling on a single call's amount |
| `allowedCalls[]` | Exhaustive allowlist of permitted inner calls |

Each `allowedCalls` entry is a `(target, selector, beneficiaryOffset, hasBeneficiary)`
tuple: which contract, which function, where the beneficiary sits in the calldata, and
whether it has one at all (`approve`, for instance, does not).

## 5. The eleven rules

`checkAction` applies these in order, cheapest first.

```mermaid
flowchart TD
    R1["R1 · config initialized?"] --> R2["R2 · target == UniversalGatewayPC?"]
    R2 --> R3["R3 · selector == sendUniversalTxOutbound?"]
    R3 --> R4["R4 · req.token == configured asset?"]
    R4 --> R5["R5 · req.amount <= cap?"]
    R5 --> R10["R10 · revertRecipient == the account?"]
    R10 --> R6["R6 · payload is a multicall?"]

    R6 --> LOOP["for each inner call"]
    LOOP --> R7["R7 · target is not the account,<br/>the policy, or the gateway"]
    R7 --> R8["R8 · (target, selector) on the allowlist?"]
    R8 --> R9["R9 · beneficiary == expectedCEA?"]
    R9 --> LOOP
    LOOP --> R11["R11 · summed inner value <= forwarded value"]
    R11 --> OK["VALIDATION_SUCCESS"]

    style OK fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style R9 fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
    style R7 fill:#3f3a1e,stroke:#eab308,color:#fbf7e8
```

Three of these carry most of the security weight.

**R9 — the beneficiary check.** Reads the beneficiary out of the inner calldata and
requires it to equal the committed CEA. This is what stops redirection.

**R7 — forbidden inner targets.** An inner call may not target the account itself, the
policy, or the gateway. The account is the important one: the wallet permits calls from
itself, so without R7 an agent could route a call back into the wallet and reach
`installModule`, taking control of the whole account.

**R10 — revert recipient.** If the cross-chain transaction fails, funds return to the
account, never to a third party.

## 6. Reading the beneficiary

The policy extracts the beneficiary by reading a 32-byte word at a configured byte offset
and taking its low 20 bytes.

```mermaid
graph LR
    subgraph cd["Aave v3 supply(address,uint256,address,uint16)"]
        S["selector<br/>4 bytes"] --> A["asset<br/>32"] --> AM["amount<br/>32"] --> OB["onBehalfOf<br/>32 ← offset 68"] --> RC["referral<br/>32"]
    end

    style OB fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
```

| Protocol | Signature | Beneficiary | Offset | Derivation |
|---|---|---|---|---|
| Aave v3 / Spark | `supply(address,uint256,address,uint16)` | `onBehalfOf` | **68** | `4 + 32 + 32` |
| Morpho Blue | `supply(MarketParams,uint256,uint256,address,bytes)` | `onBehalf` | **228** | `4 + 160 + 32 + 32` |
| ERC-20 | `approve(address,uint256)` | none | — | `hasBeneficiary = false` |

Morpho's `MarketParams` is five static fields encoded inline, hence 160 bytes.

Two things follow from this design. The offset is read before the word, so it is
bounds-checked — reading past the end of a short blob would return adjacent memory. And
because offsets are **configuration**, every protocol added to an allowlist needs a test
asserting its offset extracts the right address from a real encoded call. A wrong offset
reads the wrong word and would pass silently.

## 7. Where the policy sits in the nesting

```mermaid
graph TB
    OUTER["ERC-7579 batch<br/>SmartSession splits this<br/>and calls checkAction per action"]
    OUTER --> ACTION["one action:<br/>call the gateway"]
    ACTION --> REQ["UniversalOutboundTxRequest"]
    REQ --> INNER["req.payload — the multicall<br/>ACPActionPolicy walks THIS"]
    INNER --> C1["approve(...)"]
    INNER --> C2["supply(..., onBehalf)"]

    style INNER fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
```

The policy never iterates the outer batch — SmartSession has already destructured it. Its
own loop is over the inner multicall, the instructions destined for the other chain.

---

# Part II — `PushSessionValidator`

## 8. What it does

A stateless validator answering one question: **did this key sign this hash?**

It supports two signature schemes:

- **secp256k1 (ECDSA)** — standard EVM signing, verified with `ecrecover`
- **Ed25519** — Solana-style keys, verified through the USV precompile

## 9. Why it matters

This is what makes a Solana-keyed agent a first-class operator on an EVM account. An agent
holding only an Ed25519 keypair can drive a Push Chain smart account without ever
possessing an EVM key — no bridging of identity, no wrapper key, no custody of a secondary
secret.

```mermaid
graph LR
    subgraph keys["Agent key types"]
        K1["secp256k1<br/>EVM-native"]
        K2["Ed25519<br/>Solana-native"]
    end

    K1 -->|"ecrecover"| V["PushSessionValidator"]
    K2 -->|"precompile call"| V
    V --> R["true / false"]

    style V fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
```

## 10. How it is configured

The session config carries `abi.encode(uint8 scheme, bytes key)`:

| Scheme | Value | Key format |
|---|---|---|
| ECDSA | `0` | 20-byte signer address |
| Ed25519 | `1` | 32-byte raw public key |

Signature lengths are enforced: 65 bytes for ECDSA, 64 for Ed25519.

## 11. Verification flow

```mermaid
flowchart TD
    IN["validateSignatureWithData(hash, sig, data)"] --> DEC["decode (scheme, key)"]
    DEC --> SW{"scheme"}

    SW -->|"0 · ECDSA"| E1{"key is 20 bytes?"}
    E1 -->|no| ER1["revert MalformedConfig"]
    E1 -->|yes| E2{"sig is 65 bytes?"}
    E2 -->|no| F1["return false"]
    E2 -->|yes| E3["tryRecover"]
    E3 --> E4{"recovered == key?"}
    E4 -->|yes| T["return true"]
    E4 -->|no| F2["return false"]

    SW -->|"1 · Ed25519"| D1{"key is 32 bytes?"}
    D1 -->|no| ER2["revert MalformedConfig"]
    D1 -->|yes| D2{"sig is 64 bytes?"}
    D2 -->|no| F3["return false"]
    D2 -->|yes| D3["USV.verifyEd25519RawMessage"]
    D3 --> T

    SW -->|"other"| ER3["revert UnsupportedScheme"]

    style T fill:#0b3d2e,stroke:#10b981,color:#e7f9f1
```

Three details worth knowing.

**It is completely stateless.** Every parameter arrives as calldata and the contract holds
no storage, so a single deployment serves every account on the chain.

**Recovery failures return `false` rather than reverting.** A revert inside validation is
indistinguishable from a policy rejection, which makes debugging much harder.

**It uses the raw-message Ed25519 variant.** The precompile offers two methods; the other
verifies over the ASCII of a hex string, which is oriented toward wallet display. A
headless agent signing with a standard library produces a raw-bytes signature, so the raw
variant is the correct one.

## 12. USV precompile notes

Fixed at `0xEC00000000000000000000000000000000000001`, chain-level.

- Public keys must be **raw 32 bytes** — the precompile casts directly, so base58 fails
- Signatures must be 64 bytes
- Each verification costs 4,000 gas

---

# Part III — Adopted modules

## 13. SmartSession

The session engine, adopted unmodified from `erc7579/smartsessions` at a pinned commit.

It is installed into the wallet as a type-1 validator and owns the entire session
lifecycle: enabling sessions, storing which policies apply to which actions, and running
them when a session-signed operation arrives.

```mermaid
sequenceDiagram
    participant W as Wallet
    participant SS as SmartSession
    participant PSV as PushSessionValidator
    participant P as Policies

    W->>SS: validateUserOp(op, opHash)
    SS->>PSV: validateSignatureWithData(opHash, sig, keyConfig)
    PSV-->>SS: true / false

    Note over SS: destructure the ERC-7579 batch
    loop each action
        SS->>P: checkAction(configId, account, target, value, data)
        P-->>SS: success / revert
    end

    SS-->>W: packed ValidationData
```

Only **USE mode** is exercised: sessions are always granted by the owner in advance, never
enabled inline by the agent as part of its own transaction. The agent can therefore never
widen its own permissions.

## 14. The limit policies

Five adopted policies, each enforcing an orthogonal constraint. They compose — a session
typically installs several.

| Policy | Constrains | Typical use |
|---|---|---|
| `ERC20SpendingLimitPolicy` | Cumulative ERC-20 spend | "at most 500 USDC in total" |
| `TimeFramePolicy` | Validity window | "expires in 30 days" |
| `ValueLimitPolicy` | Native value per use | Caps gas forwarded per action |
| `UsageLimitPolicy` | Number of uses | "at most 10 operations" |
| `ContractWhitelistPolicy` | Target address | Restricts which contracts are reachable |

The spend limit is worth highlighting because it is **cumulative**, not per-call: it tracks
what has already been spent, so an agent cannot make repeated small transfers that
individually pass but collectively exceed the mandate.

```mermaid
graph LR
    C["cap: 100 USDC"]
    T1["transfer 60<br/>total 60 ✓"] --> T2["transfer 60<br/>total 120 ✗"]
    T2 --> REV["revert"]

    style REV fill:#4a1d1d,stroke:#ef4444,color:#fbe8e8
```

Two upstream policies, `UniActionPolicy` and `ArgPolicy`, are deliberately **not** adopted:
both require a newer compiler than this project pins, and `ACPActionPolicy` supersedes
their functionality for our use case.

## 15. How a session is granted

Sessions are always established by the owner, in advance.

```mermaid
sequenceDiagram
    participant O as Owner UEA
    participant W as Wallet
    participant SS as SmartSession
    participant P as Policies

    O->>W: installModule(1, SmartSession)
    O->>W: callValidator(enableSessions(sessions))
    Note over W: wallet forwards, so SmartSession<br/>sees msg.sender == the account
    W->>SS: enableSessions(...)
    SS->>P: initializeWithMultiplexer(account, configId, initData)
    Note over P: per-session config stored<br/>(cap, window, allowlist, expectedCEA)
    SS-->>W: permissionId
```

The `permissionId` returned identifies the session; the agent includes it in every
signature it produces.

Revocation is the reverse and equally available to the owner at any time — either by
removing the individual session, or by `emergencyRevokeAll` on the wallet, which detaches
the whole engine at once.

## 16. Related documents

- [architecture.md](./architecture.md) — how the whole system fits together
- [agent-wallet.md](./agent-wallet.md) — the account these modules are installed into
- [factory.md](./factory.md) — how accounts are created
- [libraries-and-types.md](./libraries-and-types.md) — the structs these modules decode
