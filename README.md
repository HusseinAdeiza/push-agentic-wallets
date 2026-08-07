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
| `PushAgentWallet` | ERC-7579 account | 6,594 B | Holds funds; native-AA entry point |
| `ACPActionPolicy` | `IActionPolicy` | 5,034 B | **The anti-custody boundary** |
| `PushSessionValidator` | Stateless validator (type 7) | 1,581 B | secp256k1 + Ed25519 via USV |
| `AgentWalletFactory` | Factory | 1,050 B | Deterministic per-mandate clones |
| `SmartSession` (adopted) | Session engine | 22,581 B | Pinned upstream, deployed unmodified |

### Key security properties

- **No provider custody** — `ACPActionPolicy` R9 forces the beneficiary of every inner
  deposit to equal the wallet's own committed CEA.
- **No self-call escalation** — R7 forbids inner calls back into the account.
- **Full replay binding** — `opHash` binds domain, chain id, account, validator, mode,
  payload hash, and a 2D nonce.
- **Two spend ceilings** — a per-call cap bounds single-transaction blast radius; a
  cumulative cap bounds lifetime mandate exposure.
- **Owner is root** — the UEA can uninstall any module or revoke any session at any time,
  and is never constrained by session policies.

---

## Toolchain

`solc 0.8.26` · `evm_version = cancun` · `via_ir = true` · `optimizer_runs = 833`

`optimizer_runs = 833` matches the setting `smartsessions` is built and audited at
upstream. Raising it pushes `SmartSession` over the EIP-170 limit and makes it
undeployable — `test_allDeployedContractsFitUnderEIP170` guards this.

`evm_version = cancun` is **required**: `ACPActionPolicy._slice` uses `MCOPY`. Lowering
the EVM target breaks the build at deploy time rather than at compile time.

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

282 tests, all passing. `forge test` and `grep -rhoE "function (test|invariant)[A-Za-z0-9_]*" test/ | wc -l` both report 282.

| Suite | Tests | Covers |
|---|---|---|
| `test/unit/PushAgentWallet.t.sol` | 45 | U-01 … U-26 |
| `test/unit/ACPActionPolicy.t.sol` | 45 | P-01 … P-28 |
| `test/unit/ExecuteWithSession.t.sol` | 22 | S-01 … S-16 |
| `test/unit/PushSessionValidator.t.sol` | 19 | V-01 … V-12 |
| `test/integration/FullFlow.t.sol` | 18 | I-01 … I-13 (real SmartSession) |
| `test/unit/Libraries.t.sol` | 17 | shared libraries, decodeBatch bounds |
| `test/fuzz/PushWallet.fuzz.t.sol` | 12 | F-01 … F-05 |
| `test/invariant/PushWallet.invariant.t.sol` | 6 | N-01 … N-05, N-02b |
| `test/unit/Attacks.t.sol` | 5 | A-01, A-13 |
| `test/integration/SpendingLimit.t.sol` | 3 | adopted policy in isolation (see file header) |
| `test/unit/ContractSize.t.sol` | 2 | EIP-170 guard |

Integration tests run against the **real** `SmartSession` and adopted policies, not
mocks. Every attack in PRD §12 (A-01 … A-16) has a test demonstrating prevention.

---

## Review status

Senior review found two critical defects, both now fixed:

- **Ed25519 reverted on-chain** — the precompile was called through a high-level
  interface, which inserts an `extcodesize` check and reverts on a codeless target. Now a
  raw staticcall, mirroring the audited `UEA_SVM`.
- **No cumulative spend cap** — the mandate ceiling was per-call only, so an agent could
  drain the wallet across repeated in-cap calls. `ACPActionPolicy` now accumulates.

`docs-internal/DEVIATIONS.md` records the full resolved/open split. Four items remain open, none
blocking code: coverage justification, the V-11 fork test, deployment addresses, and an
escalation to the gateway team about freezing the CEA implementation setter.

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
