# Push Agentic Wallet v3 — build conventions

**`docs-internal/v3-architecture-docs/README.md` is the single entry point. Read it, and the reading plan it sets out, before writing any code.** This file is conventions only; it does not restate the architecture.

## Standing build rules

1. **One phase at a time.** Stop at the gate, report, wait for acknowledgement before proceeding.
2. **One contract per phase, its tests in the same phase.** No contract ships without its suite.
3. **The PRDs are locked.** A PRD error is *reported with evidence and waited on* — never fixed in place, never coded around.
4. **`src/libraries/` and `src/interfaces/` may change only via a diff proposed at the start of the phase that needs it.** Never edited opportunistically.
5. **Branch `pushAgenticWallet_v3`.** All build work lives there. **Zaryab alone commits and pushes** — prepare the change, report what is ready, and print the commands; never run `git commit` or `git push`. Never commit local deployment records (`deployments/*.json`), `out/`, `cache/`, or `.env`.
6. **Gate report format:** what was built · what was verified and how · what deviated and why · what you are unsure of · `forge test` and `forge build --sizes` output verbatim.

## Standing test rules

1. **Every negative test names its expected error.** Two documented exceptions only: UCEP gate 4 case (d) (correct-length, malformed-offset body) and validator P-05 — both assert "reverts" because both fail at the same un-named `abi.decode` step.
2. **A mock may be the OBSERVER, never the ORACLE.** A mock that supplies the behaviour under test can make a dead branch look live — that is how this repo's one shipped critical bug survived review.
3. **Gas assertions carry a number.** "Within a sane budget" is not assertable; a test that cannot fail is worse than no test.
4. **Nothing marked ⚠️ NEVER-DELETE is ever deleted or weakened.** Nine such tests exist: T-01, W-01, W-02, U-01, U-02, U-09, U-21, P-04, S-01.

## Build order

| Phase | Deliverable |
|---|---|
| 0 | Baseline: build green, harness, size gate |
| 1 | `UCEP` (`src/policies/UCEP.sol`) |
| 2 | `PushSessionValidator` — `validateConfig` addition + full suite |
| 3 | `PushAgentWallet` |
| 4 | `AGWFactory` |
| 5 | Integration + deploy script |

## Toolchain pins (facts, not preferences)

- `solc 0.8.26` · `optimizer_runs = 833` · `evm_version = "cancun"` · `via_ir = true`
- OpenZeppelin 5.7.0 · forge-std 1.16.2 · SmartSession fork `7dc20e4`
- **forge: use STABLE, never nightly** (`foundryup -i stable`). Runtime bytecode is a function of
  solc + optimizer + via_ir + evm_version + metadata — all pinned in `foundry.toml` — so the forge
  binary does not change the sizes S-06 gates on. It does change how `--sizes` reports, how
  remappings resolve, and how `forge script` broadcasts, which is where a nightly actually bites.
  `foundry.toml` has no key for the driver version: **record the exact `forge --version` in every
  gate report.** That is the reproducibility mechanism — do not invent a config key for it.
  CI uses `foundry-toolchain` with an explicit `version:` matching the recorded line.

  **Recorded at Gate 0:** `forge 1.5.1-stable` (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`,
  2025-12-22). Confirmed on this version: SmartSession runtime 22,581 B / +1,995 margin —
  byte-identical to the figure measured on 1.6.0-nightly, which is the evidence that the driver
  does not move bytecode.

**`optimizer_runs` and `evm_version` are load-bearing.** The vendored engine exceeds EIP-170 above ~833 runs and becomes undeployable; `cancun` is required for `MCOPY` in UCEP's slice helper. A local `anvil` deploy will not catch the size problem — anvil does not enforce EIP-170.

## Layout

| Path | Contents |
|---|---|
| `src/policies/` | `UCEP.sol` |
| `src/validators/` | `PushSessionValidator.sol` (shipped, v3-current) |
| `src/` (root) | `PushAgentWallet.sol`, `AGWFactory.sol` |
| `src/interfaces/` | `IUCEP`, `IPushSessionValidator`, `IAGWFactory`, `IPushAgentWallet`, gateway + module interfaces |
| `src/libraries/` | `PushWalletTypes` (authoritative gateway struct mirror), `ModeLib`, `ExecutionLib`, `PushWalletErrors` |
| `test/Base.t.sol` | Shared harness — every suite extends `BaseTest` |
| `test/unit/` | Per-contract suites |
| `test/integration/` | End-to-end flows |
| `script/` | Deployment scripts |
| `deployments/` | `<chainId>.json` records — **never committed** |

## Commands

```
make build    # forge build
make test     # forge test -vv
make sizes    # forge build --sizes — the S-06 gate, exits non-zero over 24,576 B
```

`make sizes` is the size gate. It runs `--sizes` twice — once for the build, once for the vendored engine explicitly. That is deliberate: **which contracts the default table covers is forge-version-dependent** (1.5.1-stable includes `lib/`; 1.6.0-nightly did not), and SmartSession has the smallest margin in the build. The gate must not rest on a reporting default that has already changed once.
