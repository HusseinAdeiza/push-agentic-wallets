# Multi-Asset Rules Review

`push-agentic-wallet · UniversalRulesPolicy · branch multi-asset-grantRule`

One cross-chain rule can now list 1 to 8 tokens, each with its own per-call limit, lifetime limit and spend
counter. "On Ethereum, move 1000 USDC and 500 USDT, using Fluid and Aave" is one rulesId. Only URP changed,
and it still fits on-chain.

A prototype for review, built from the v2 AGW contract changes (§4c), SDK §1.b and the follow-up
confirmation. It is built and tested, not deployed. Try it, then decide whether rules stay single-token or
become multi-token.

| Base commit | Status | Tests | URP margin | Mutants |
|---|---|---|---|---|
| `e704d5b` | Not deployed | 592 pass · 0 fail | 223 B | 12 of 12 killed |

**On this page:** [1 · What was built](#1--what-was-built) · [Verification](#verification) ·
[2 · Deviations from the v2 docs](#2--where-this-deviates-from-the-v2-docs) ·
[3 · Open questions](#3--open-questions) · [4 · Edge cases](#4--edge-cases-as-built) ·
[5 · Pending and risks](#5--pending-unclear-or-not-secure-enough) · [6 · Try it](#6--try-it)

---

## 1 · What was built

### The rule shape

The terms the owner passes in `grantRules`. The envelope is unchanged: `abi.encode(string chainNamespace, bytes body)`.

```solidity
uint256 constant MAX_ASSETS = 8;

struct AssetCap {            // one token the rule may move
    address token;           // the PRC20 on Push (e.g. USDC.eth), never the Ethereum address
    uint256 maxPerCall;      // per request; 0 = may route a request, never moves
    uint256 maxTotal;        // lifetime amount sent out; max-uint = unlimited, 0 = nothing
}

struct UniversalTerms {      // EVM destination
    uint48        validUntil;
    address       expectedCEA;
    AssetCap[]    assets;          // 1..MAX_ASSETS
    uint256       maxGasPerCall;   // renamed from maxPCPerCall
    AllowedCall[] allowedCalls;    // unchanged, shared by every listed token
}

struct SvmTerms {            // Solana destination: the same two fields replace the old four
    uint48 validUntil; bytes32 expectedCEA; bytes32 gatewayProgram;
    AssetCap[] assets; uint256 maxGasPerCall;
    bytes32[] ceaAccounts; AllowedProgram[] programs; SvmAccountPin[] pins; SvmDataPin[] dataPins;
}
```

URP stores each token as `AssetCapState { token, maxPerCall, maxTotal, spent }`. In the stored `Config` and
`SvmConfig`, `maxGasPerCall` and `AssetCapState[] assets` replace `asset`, `maxAmountPerCall`,
`maxAmountTotal`, `maxPCPerCall` and `spent`.

ABI tuple for SDK encoders (EVM):

```
(uint48,address,(address,uint256,uint256)[],uint256,(address,bytes4,uint16,bool,uint256)[])
```

The example from the follow-up, as one rule:

```
chain:         "eip155:1"
assets:        [ { token: USDC.eth, maxPerCall: 1000e6, maxTotal: 1000e6 },
                 { token: USDT.eth, maxPerCall:  500e6, maxTotal:  500e6 } ]
maxGasPerCall: 1 PC
expectedCEA:   the wallet's account on Ethereum
allowedCalls:  [ Fluid functions…, Aave functions…, USDC.approve, USDT.approve ]
→ one rulesId
```

### What URP checks when the rule is granted

Both families (EVM and Solana) run the same checks, in this order. Every counter starts at zero; the caller
cannot set one.

| Check | Error |
|---|---|
| 1 to 8 tokens | `AssetListOutOfRange(length)` |
| No token listed twice (every pair compared) | `DuplicateAsset(token)` |
| **Every** token has code and answers `SOURCE_CHAIN_NAMESPACE()` | `InvalidAsset(token)`; a zero token fails here too |
| **Every** token's source chain equals the rule's chain | `ChainMismatch(declared, assetChain)` |
| `expectedCEA` is not zero (EVM) | `InvalidConfigField()` |

### What URP checks on every agent call

| Gate | What it checks |
|---|---|
| 5 | `req.token` is one of the listed tokens, **on every request, amount 0 included**. Error: `AssetNotAllowed(token)` |
| 6 | The amount is within that token's per-call limit |
| 7 | That token's spent plus the amount is within its lifetime limit |
| 8 | `msg.value` is within `maxGasPerCall`; the error name is unchanged (`PCValueExceedsCap`) |
| S6b | Solana only: the amount fits in u64 (unchanged) |

After every gate passes, only the matched token's counter moves. The event is
`OutboundMetered(id, multiplexer, account, token, amount)`. Every other gate is unchanged.

### Spend, credits, reads

- **`assertSpent(id, account, uint256[] expectedSpent)`** expects one value per listed token, in list order,
  and compares them exactly. A wrong count reverts `SpentLengthMismatch`; a wrong value reverts
  `AssetSpentMismatch(token, expected, actual)`. It is still the race guard at the start of an update
  (assert, revoke, grant). The native overload is unchanged.
- **`creditRevert(id, account, outboundTxId, token, amount)`** names the token. A misrouted credit (a ghost
  config, or an unlisted token) reverts, and the revert leaves the outbound id uncredited, so it can be
  retried. The token is resolved before the idempotency check, so an already-credited id sent with an
  unlisted token reports the token. The credit saturates per token and never lowers another token's
  counter. It is still not wired up on the executor-module side.
- **Reads:** `getConfig` and `getSvmConfig` return `assets` with each token's `spent`. There is no separate
  spent view.
- `version()` is `3.0.0`.

### Solana specifics

- **The value-holding list holds up to 16 accounts** (`MAX_CEA_ACCOUNTS`, was 8): the CEA, one token account per
  listed token (up to 8) and up to 7 swap-output accounts. A listed account may appear in a request only where
  the matched rule pins it; a listed account no rule pins can never be passed. The change costs no bytes; S18
  gas grows with the number of accounts actually listed (6,041 gas per extra listed account on a 10-account
  request, cold).
- **URP cannot check that every listed token's account is on that list.** It cannot derive Solana token
  accounts and does not know a PRC20's mint, so the SDK must list them.
- **One input per instruction.** Each (program, instruction) has exactly one rule, and each position one pinned
  key. If a swap rule pins its input to the USDC account, USDT can never be that instruction's input: at the
  pinned position it fails S17, anywhere unpinned it fails S18. Using several tokens through one instruction
  means leaving the input unpinned and those token accounts unlisted, protected only by the output and price
  pins. Multi-asset on Solana works best when different tokens are used by different instructions.

### What did not change

- `AGW`, `AGWFactory`, `AgentValidator` and SmartSession are untouched. The wallet passes the terms through
  as bytes.
- The native (Push-side) rulebook.
- The envelope shape `(string chainNamespace, bytes body)`. There is no version field yet.

### Files

| File | Change |
|---|---|
| `src/libraries/Types.sol` | `MAX_ASSETS`, `AssetCap`, `AssetCapState`; new `UniversalTerms`, `Config`, `SvmTerms`, `SvmConfig` |
| `src/policies/UniversalRulesPolicy.sol` | Grant-time list checks, gates 5–8 in both families, `assertSpent`, `creditRevert`, storage copy; `MAX_CEA_ACCOUNTS` 8 → 16 |
| `src/interfaces/IUniversalRulesPolicy.sol` | Events carry `token`; new `assertSpent` and `creditRevert` signatures |
| `src/libraries/Errors.sol` | Added `AssetListOutOfRange`, `DuplicateAsset`, `AssetNotAllowed`, `AssetSpentMismatch`, `SpentLengthMismatch`; removed `AssetMismatch` |
| `test/unit/28_multiAsset.t.sol` | New suite, 18 tests |
| `test/unit/9_svmRulebook.t.sol` | 7 new Solana tests: multi-asset, the 16-account list, the one-input limit, S18 gas |
| 15 other test files and `test/Base.t.sol` | One-token lists in place of the old fields; updated expected errors |
| `docs/`, `CLAUDE.md` | Updated to the new shape; this review is `docs/multi-asset-review.md` |

### Tests

New, in `28_multiAsset.t.sol`. **Keep** marks a test that must never be deleted.

| Test | Proves |
|---|---|
| MA01 | Two tokens stored in order, with their caps, every counter at zero |
| MA02 | **Keep.** An empty list is refused |
| MA03 | Eight tokens accepted, nine refused; `MAX_ASSETS == 8` |
| MA04 | A duplicate token is refused, even when not adjacent |
| MA05 | **Keep.** Every token is chain-checked: a Sepolia rule whose second token is Arbitrum's is refused |
| MA06 | A codeless or zero token is refused at any position |
| MA07 | **Keep.** An unlisted token is refused at amount 0; a listed token at amount 0 passes and writes nothing |
| MA08 | Each token is metered on its own counter; the event names the token |
| MA09 | The per-call limit is the matched token's |
| MA10 | Exhausting one token leaves the others usable |
| MA11 | A zero per-call token routes but never moves |
| MA12 | Max-uint means unlimited; a zero total means nothing moves |
| MA13 | Limit 1000, 600 sent, 300 returned: 400 left, not 700 |
| MA14 | `assertSpent` is exact per token and refuses a prefix or an extra entry |
| MA15 | `creditRevert` touches only its token; an unlisted token does not burn the outbound id |
| MA16 | Fuzz: spending one token never moves another's counter |
| MA17 | Through the real wallet and engine: one rulesId moves USDC and USDT; an unlisted token dies at gate 5 |
| MA18 | Gas: gate 5 costs 2,402 gas per listed token ahead of the match (cold); budget asserted |

Solana, in `9_svmRulebook.t.sol`:
- two tokens metered separately;
- **Keep.** an unlisted token refused at amount 0;
- an empty list refused and every token chain-checked;
- `creditRevert` per token;
- the value-holding list accepts 16 accounts and refuses 17;
- the one-input-per-instruction limit: a second token's listed account fails S17 at the pinned input and S18
  anywhere unpinned;
- gas: S18 costs 6,041 per extra listed account (cold); budget asserted.

Existing tests whose expectations changed. Every one still names its exact error:

| Test | Before | Now |
|---|---|---|
| Zero-token tests (`test_init_rejectsZeroAssetAndZeroCEA`, `test_W24_…`, `test_svmInit_identityFieldsMustBeSet`) | `InvalidConfigField` / `InvalidSvmConfigField` | `InvalidAsset(0)` |
| Spend assertions (`test_U16_*`, `test_W10_*`, `test_svm_assertSpentReadsTheSvmCounter`) | `SpentMismatch` | `AssetSpentMismatch(token, …)` |
| `test_U03_gate5_AssetMismatch` | `AssetMismatch` | `AssetNotAllowed` (name kept) |
| The frozen-layout test | Old layout | New `Config`, `SvmConfig`, `AssetCapState` layouts pinned |
| The raw-slot test in `8_e2e` | Old slot | New slot of `assets[0].spent` |

---

## Verification

| What | Result |
|---|---|
| `make test` | `execute()` pin OK; **592 passed, 0 failed**, 2 skipped (the live-deployment tests, unchanged) |
| `forge fmt --check` | Clean |
| Compiler and lint warnings | 4 fewer than the base commit, none new |
| Gate-5 scan cost | 2,402 gas per listed token ahead of the match, cold. With 8 tokens, matching the last one costs about 16.8k more than the first; an unlisted token scans all 8 (about 19k) before it is refused. |
| Solana S18 cost | 6,041 gas per extra listed value-holding account on a 10-account request, cold (4,041 warm). Listing all 16 instead of 3 adds about 78.5k gas. |
| Mutation testing | **12 of 12 hand mutants killed**, each run against the full suite in a scratch copy. One survived the first run and was killed after a precedence check was added. |
| `forge --version` | `1.5.1-stable` |

### URP size against the 24,576-byte limit

| | Runtime size | Share of the limit | Bytes left |
|---|---|---|---|
| Before | 23,673 B | 96.33% | 903 B |
| This branch | 24,353 B | 99.09% | 223 B |

AGW, the factory, the validator and the engine are unchanged.

### Mutation results

| Mutant | Change made to URP | Killed by |
|---|---|---|
| M1 | EVM gate 5 skipped when the amount is 0 | MA07, MA17, MA18 |
| M2 | Solana gate 5 skipped when the amount is 0 | Solana unlisted-token test |
| M3 | Empty token list allowed | MA02, Solana empty-list test |
| M4 | Duplicate check removed | MA04 |
| M5 | Only the first token chain-checked | MA05, MA06, Solana chain-check test |
| M6 | Token lookup always returns the first entry | 15 tests, incl. MA07, MA08, MA09, MA16 |
| M7 | "Already credited" checked before the token lookup | MA15. Survived the first run: a revert rolls the flag back either way, so order only decides which error wins. A precedence check was added and the NatSpec corrected. |
| M8 | `assertSpent` length check removed | MA14 |
| M9 | Storage swaps `maxPerCall` and `maxTotal` | 14 tests, incl. MA01, MA09, MA10 |
| M10 | EVM spend written to entry 0 instead of the matched token | 6 tests, incl. MA08, MA10, MA14, MA16 |
| M11 | `MAX_ASSETS` bound off by one | MA03 |
| M12 | `OutboundMetered` names entry 0's token | MA08 |

---

## 2 · Where this deviates from the v2 docs

| # | v2 docs (§4c) said | Built | Why |
|---|---|---|---|
| D1 | `assets` may be empty: "call contracts, move nothing" | **1 to 8 tokens, never empty.** Move-nothing is one token with `maxPerCall: 0`. | The gateway picks the destination chain from `req.token` and rejects token 0. With no token pinned, an agent could name any chain's token at amount 0 and run the rule's calls on a chain the owner never approved. |
| D2 | "The token *being moved* must be one of `assets`" | **Checked on every request, amount 0 included** | The same hole: a zero-amount request moves nothing but still picks the chain. |
| D3 | `maxTotal: 0` = no cap | **Max-uint = unlimited; 0 = nothing moves** | 0 meaning unlimited turns a forgotten field into unlimited spend, and clashes with the native rulebook, which uses max-uint. The SDK can still let users omit the field and fill in max-uint. |
| D4 | `bytes32 expectedCEA` in `UniversalTerms` | **Kept `address`** | The EVM beneficiary check compares addresses. It looks copied from `SvmTerms`; the change wasn't listed. |
| D5 | `_spent[configId]` becomes `mapping(token => spent)` | **`spent` lives on each stored token entry** | `_spent` doesn't exist; spend lived inside `Config`. A mapping inside `Config` would make `getConfig` impossible to return. One entry per token keeps caps and spend in one read. |
| D6 | `assertSpent` "returns the per-token totals" | **Still an assertion** (array, exact); totals come from `getConfig` | It is the race guard at the start of an update. A getter would silently drop the guard. |
| D7 | `uint8 constant MAX_ASSETS = 8` | `uint256`, file-level | Same form as `MAX_PINS`, which the SDK also reads. |
| D8 | `creditRevert` not mentioned | **Takes a `token`** | With per-token counters it must know which one to credit. |
| D9 | "`SvmTerms` takes the same fields", written against the §4b sketch | Applied to the Solana rulebook as built | The §4b sketch is not the shipped Solana rulebook. |

Followed as written: the `maxGasPerCall` rename, `MAX_ASSETS = 8`, the `AssetCap` field names and the field
order. The earlier call described "one grant per token, URP unchanged"; the written confirmation (one
rulesId for several tokens) supersedes it, so this branch builds the doc's version.

---

## 3 · Open questions

Questions that need an answer before this could ship.

- **Q1 · Name of `maxGasPerCall`.** It caps `msg.value` in PC wei, which pays the protocol fee and the gas
  swap. "Gas" usually means gas units, and the request already has a `gasLimit` in units. Keep the name, or
  go back to `maxPCPerCall`?
- **Q2 · Solana token accounts. Resolved (option A):** the value-holding list now holds 16 accounts, enough
  for all 8 tokens plus 7 outputs; the SDK must list every token's account; the one-input-per-instruction
  limit is documented (see "Solana specifics").
- **Q3 · The marketplace (core repo).** `UniversalMarketplaceTerms.verifySession` copies the old struct and
  checks that the rule's asset is the job's token and its total equals the job's payment. Should it require
  exactly one token, the job's token, with `maxTotal` equal to the payment? Otherwise extra tokens come
  along with no job-level limit.
- **Q4 · `creditRevert`.** Wire it now, or remove it (item 6)? If kept, the executor module must pass the
  token, and URP has to trust it as much as the amount.
- **Q5 · Duplicate rules in the SDK.** SDK §1.b refuses two rules for the same agent on the same chain
  (`DUPLICATE_RULE`), and the agent-side lookup (§2.a) assumes at most one match. The follow-up says users
  can still create separate rules. Which wins? The contract allows duplicates either way.
- **Q6 · SDK `Spent` type** (§3.b) still has one `amountSpent` for cross-chain rules. It needs one entry per
  token, in list order.
- **Q7 · Envelope version** (item 5) is not in this branch. Shape `(uint16 version, string chainNamespace,
  bytes body)`, version first, anything but 1 refused at grant? Mind the 223-byte margin.
- **Q8 · No combined limit.** Limits are per token; "1500 dollars across USDC and USDT" can't be expressed
  without an oracle. Acceptable?
- **Q9 · Protocols are shared across tokens.** One rule can't say "USDC only to Aave, USDT only to Fluid";
  that takes two rules. Acceptable?
- **Q10 · Is 8 the right maximum?** Each extra token ahead of the match costs about 2.4k gas per agent call.
- **Q11 · Solana repatriation.** The agent can bring back only listed tokens, never what it bought. Is
  listing the swap output as a second token a wanted and safe way to allow that?

---

## 4 · Edge cases, as built

| Case | Behaviour | Test |
|---|---|---|
| Listed token, amount 0 | Passes, nothing metered (redeploying capital already at the destination) | MA07 |
| Unlisted token, amount 0 | Refused, `AssetNotAllowed` | MA07, svm |
| Token with `maxPerCall: 0` | May route a request, never moves | MA11 |
| `maxTotal: 0` | Nothing can move | MA12 |
| `maxTotal` = max-uint | Unlimited | MA12 |
| `maxPerCall` greater than `maxTotal` | Allowed; the total binds first | unchanged |
| One token exhausted | The others keep working | MA10 |
| Money comes back to the wallet | Room is not restored: limit 1000, 600 out, 300 back leaves 400 | MA13 |
| A failed outbound bounces back | Only `creditRevert` restores room, per token, saturating; not wired yet | MA15 |
| Credit names an unlisted token | Reverts; the outbound id stays uncredited and retryable | MA15 |
| `assertSpent` with too few or too many entries | Reverts `SpentLengthMismatch` | MA14 |
| Token order | Significant: `assertSpent` is positional, so the SDK must keep the order it granted | MA14 |
| Two tokens in one agent action | Not possible: one gateway request carries one token, so it takes two agent calls | gateway |
| Two different PRC20s that are both "USDC" on one chain | Treated as different tokens; listing both is allowed | design |
| Right chain, wrong token | URP checks the chain, not which token; picking USDC.eth vs USDT.eth is the SDK's job | design |
| `maxGasPerCall` | Applies per request, whatever the token | unchanged |
| Changing a rule | Still revoke plus grant; every counter restarts at zero | unchanged |
| Solana: a second token through the same instruction | Refused while its account is listed: S17 at the pinned input, S18 anywhere unpinned | svm one-input test |

---

## 5 · Pending, unclear, or not secure enough

> **Do not upgrade the existing Donut URP proxy to this implementation.**
> The stored `Config` and `SvmConfig` layouts changed, which is fine for a fresh deployment. Upgrading a
> proxy that already holds rules would make URP read old data in the wrong places.

### Risks in this build

| Severity | Risk |
|---|---|
| High | **Size.** URP has 223 bytes left. Almost any further URP feature (the envelope version, more Solana checks) will not fit without a plan. Options: delete code kept only for upgrades from older versions (the `destChainHash` relic, the legacy mode fallback); a lower optimizer setting for URP alone; or splitting URP, which collides with the rule that URP's agent-call check makes no external calls. |
| High | **The marketplace breaks** until the core repo updates its copy of the struct and its job check (Q3). |
| Medium | **Right chain, wrong token** is not caught on-chain. If the SDK resolves pUSDC where the user meant pUSDT, the grant succeeds. |
| Medium | **Shared allow-list.** Any listed token can be sent to any allowed protocol. |
| Medium | **`creditRevert`** trusts both `token` and `amount` from the executor module, and it is still unwired. |
| Medium | **Solana:** the SDK must list every token's account (URP can't check it), and one instruction can take only one pinned input token. Both documented; see "Solana specifics". |
| Low | **Naming footgun.** Someone who sets `maxGasPerCall` to a gas-units number (e.g. 300000) gets 300000 wei of PC, so every call fails. That fails safe, but it is confusing (Q1). |

### Unchanged risks

Listed so nobody assumes this branch fixed them. Zero-amount agent calls are not limited in number; each can
spend up to `maxGasPerCall` in fees, bounded only by the wallet's PC balance.

### Not done in this branch

- The SDK changes: per-token `Spent`, the `assertSpent` array, and encoding `assets`.
- The marketplace changes (core repo).
- The envelope version (item 5) and `ref` on `grantRules` (item 3).
- A deployment.

### Not verified

The gateway's routing-by-token rule was read from a local gateway checkout (branch `pc20Metadata_removal`).
The newer six-field gateway was not available to check, though nothing suggests routing changed.

---

## 6 · Try it

```
git checkout multi-asset-grantRule
forge test --match-path test/unit/28_multiAsset.t.sol -vv   # the multi-asset suite
forge test --match-test test_svm_MA_ -vv                     # the Solana multi-asset tests
make test                                                    # check-execute + the full suite
make sizes                                                   # the 24,576-byte gate
```

---

The same notes are published as a review page:
https://claude.ai/code/artifact/abc11dda-af04-4214-882b-5a467db3ac2a
