# Push Agentic Wallet — smart contracts

Per-user, per-mandate ERC-7579 smart accounts on Push Chain that let an autonomous agent
execute bounded, cross-chain actions on a user's behalf **without ever taking custody of
their funds**.

Implements `PRD-push-agentic-wallet-contracts.md` v1.0.

---

## What this is

A `PushAgentWallet` is an ERC-7579 modular smart account owned by the user's existing
**UEA**. It hosts the adopted, audited **SmartSession** engine plus two purpose-built
modules. The provider agent gets a scoped session key; the wallet — never the provider —
is the `msg.sender` at `UniversalGatewayPC`, which is what determines the CEA that
executes on the destination chain.

```
AgentWalletFactory ──clones──▶ PushAgentWallet  (ERC-7579 account)
                                  │
                                  ├─ installs ──▶ SmartSession          [adopted]
                                  │                  ├─ PushSessionValidator   [built]
                                  │                  ├─ ACPActionPolicy        [built]
                                  │                  ├─ ERC20SpendingLimit     [adopted]
                                  │                  └─ TimeFrame / Value / …  [adopted]
                                  │
                                  └─ calls ──────▶ UniversalGatewayPC
```

### Contracts we build

| Contract | Type | Runtime size | Purpose |
|---|---|---|---|
| `PushAgentWallet` | ERC-7579 account | 8,870 B | Holds funds; native-AA entry point |
| `ACPActionPolicy` | `IActionPolicy` | 6,894 B | **The anti-custody boundary** |
| `PushSessionValidator` | Stateless validator (type 7) | 2,067 B | secp256k1 + Ed25519 via USV |
| `AgentWalletFactory` | Factory | 1,401 B | Deterministic per-mandate clones |

### Key security properties

- **No provider custody** — `ACPActionPolicy` R9 forces the beneficiary of every inner
  deposit to equal the wallet's own committed CEA.
- **No self-call escalation** — R7 forbids inner calls back into the account.
- **Full replay binding** — `opHash` binds domain, chain id, account, validator, mode,
  payload hash, and a 2D nonce.
- **Owner is root** — the UEA can uninstall any module or revoke any session at any time,
  and is never constrained by session policies.

---

## Toolchain

`solc 0.8.26` · `evm_version = cancun` · `via_ir = true` · `optimizer_runs = 99999`

```bash
forge build
forge test
forge coverage --no-match-coverage "(test/|script/|lib/)" --ir-minimum
```

---

## Dependency inventory — resolved commits

Per PRD §3.3, every dependency is pinned. `smartsessions` is AGPL-3.0 and
security-critical, so it is **vendored at an exact commit** rather than floating.

### Git submodule-style dependencies (`lib/`)

| Dependency | Version | Resolved commit |
|---|---|---|
| `foundry-rs/forge-std` | — | `c179529c064588ede54a0661ec3cc98219460d07` |
| `OpenZeppelin/openzeppelin-contracts` | 5.7.0 | `c5fe13895dc8f4b2986f69d23d813c5329d3724e` |
| `erc7579/smartsessions` | 1.0.0 | `f5aaf867f7e22f3b9d746ce6f404f3a56833757f` |

### Vendored transitive sources (`lib/vendor/`)

`smartsessions` resolves its own dependencies through npm rather than git submodules.
The exact transitive closure required to build `SmartSession` and the five adopted
policies (64 files) is vendored at these pinned versions:

| Package | Version |
|---|---|
| `@ERC4337/account-abstraction` | 0.7.0 |
| `@rhinestone/modulekit` | 0.4.10 |
| `@rhinestone/module-bases` | 0.0.1 |
| `@rhinestone/flatbytes` | 0.0.1 |
| `erc7579` | 0.3.1 |
| `solady` | 0.0.240 |
| `excessively-safe-call` | 0.0.1-rc.1 |

### Adopted contracts (deployed unmodified)

`SmartSession`, `ERC20SpendingLimitPolicy`, `TimeFramePolicy`, `ValueLimitPolicy`,
`UsageLimitPolicy`, `ContractWhitelistPolicy`.

`UniActionPolicy` and `ArgPolicy` are **deliberately excluded** — both are `pragma
^0.8.27` and will not compile under the `0.8.26` pin (PRD §4.1). Their functionality is
superseded by `ACPActionPolicy`.

---

## Tests

149 tests, all passing.

| Suite | Tests | Covers |
|---|---|---|
| `test/unit/PushAgentWallet.t.sol` | 40 | U-01 … U-23 |
| `test/unit/ExecuteWithSession.t.sol` | 22 | S-01 … S-16 |
| `test/unit/ACPActionPolicy.t.sol` | 34 | P-01 … P-20 |
| `test/unit/PushSessionValidator.t.sol` | 17 | V-01 … V-10 |
| `test/integration/FullFlow.t.sol` | 16 | I-01 … I-11 (real SmartSession) |
| `test/integration/SpendingLimit.t.sol` | 3 | I-08 (real spend-limit policy) |
| `test/fuzz/PushWallet.fuzz.t.sol` | 10 | F-01 … F-04 |
| `test/invariant/PushWallet.invariant.t.sol` | 5 | N-01 … N-05 |
| `test/unit/Libraries.t.sol` | 10 | shared libraries |
| `test/unit/ContractSize.t.sol` | 2 | EIP-170 guard |

Integration tests run against the **real** `SmartSession` and adopted policies, not
mocks. Every attack in PRD §12 (A-01 … A-16) has a test demonstrating prevention.

---

## ⚠ Read `DEVIATIONS.md` before review

Six items are recorded there. Three need a human decision:

- **D-3** — the wallet→self config path in §5.7 / Stage B is unreachable: `execute` and
  `installModule` are both `nonReentrant`, so the self-call reverts.
- **D-4** — `ExecutionLib.decodeBatch` silently no-ops on mode/encoding mismatch, so a
  batch-mode call over single-encoded calldata succeeds having done nothing.
- **D-5** — **blocker.** `SmartSession` is 28,737 B at the mandated
  `optimizer_runs = 99999`, i.e. 4,161 B over EIP-170. It fits (22,581 B) at upstream's
  `runs = 833`. §3.2 and §4.1 cannot both hold as written.

---

## Deployment

```bash
NETWORK=<network> forge script script/DeployCore.s.sol:DeployCore \
  --rpc-url <RPC> --private-key <PK> --broadcast

NETWORK=<network> UNIVERSAL_GATEWAY_PC=<addr> \
  forge script script/DeployModules.s.sol:DeployModules \
  --rpc-url <RPC> --private-key <PK> --broadcast
```

`DeployCore` initializes the implementation to `0xdead` and asserts it cannot be
re-initialized (attack A-13). Both scripts write resolved addresses to
`deployments/<network>.json`.

Deployment inputs live in `script/config/donut.json` and are **not** hardcoded in
contracts, except `UNIVERSAL_GATEWAY_PC`, which is immutable-at-construction in
`ACPActionPolicy`.
