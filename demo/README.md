# The cross-chain agentic demo

A user on Ethereum owns an agent wallet on Push Chain without ever holding a Push Chain key, grants
it a mandate narrow enough to fit on one screen, and watches an agent move real capital across a
chain boundary — while five different attacks die on-chain.

**The specification is `docs-internal/demo_prep.md`.** This file is how to run it.

## Run it

```
cd demo && just            # list every recipe
```

```
just preflight             # T-1 hour, and again five minutes before presenting
just setup                 # tokens, quote, funding, StakeDummy
just act1                  # off-camera: the only Ethereum tx, and the longest relay wait
just state                 # ← run this between every act

just act2                  # the central beat
just g1 g2 g3 g4 g5        # the gauntlet
just act4a act4b act4c act4d
```

**Every broadcasting recipe has a `-dry` variant.** Use them in rehearsal — a dry run costs nothing
and catches a bad payload before it costs an act.

## What to know before running it

**`just preflight` detects its own phase.** Checks that are not yet applicable print grey, never
red; a preflight that goes red because Act 1 has not run is one you learn to ignore. It exits
non-zero on any real failure.

**`just quote` must run again immediately before Act 2.** `maxPCPerCall` is frozen into the mandate
at grant time, so if fees move past it every agent request is refused by gate 8 — and the only
remedy is a regrant. The quote warns while there is still time.

**The gauntlet needs no relay.** All six are simulations: no broadcast, no nonce consumed, freely
re-runnable. If a cross-chain hop is slow, run them while waiting — that is what they are for.

**`just g5` must run after `just act2`.** Its refusal depends on the spend counter having moved. It
asserts that and fails with a message naming Act 2 rather than a confusing selector mismatch.

**`DEMO_SCALE_PERCENT=10` runs the whole thing on a tenth of the capital.** Every ratio the gauntlet
depends on is preserved. The live run must be at full scale.

## What is where

| path | holds |
|---|---|
| `contracts/StakeDummy.sol` | the far-chain target. Demo only, never mainnet |
| `lib/` | address book, ledger, logging, signing, request builders |
| `script/00_setup/` | tokens, quote, StakeDummy, funding, the forwarding probes |
| `script/01_bob/` | Act 1 — arrival, the wallet, the PC seam, the approval, the mandate |
| `script/02_agent/` | Act 2 — the stake |
| `script/03_gauntlet/` | Act 3 — six refusals |
| `script/04_boundary/` | Act 4 — unstake, the refusal, the owner's repatriation, the withdrawal |
| `script/05_inspect/` | state dumps |
| `script/Preflight.s.sol` · `Watch.s.sol` | the checklist, and the cross-chain wait |
| `ref_contracts/` | Push core's DEPLOYED source. Read this, not our assumptions |
| `state/ledger.json` | per-run state. Gitignored |

## Three things that cost a debugging session each

**`gasFee` is denominated in the GAS TOKEN, not PC.** `protocolFee` is in PC. Two currencies in one
return tuple. Sizing a PC budget from `gasFee` undersizes the swap by the pETH/PC price — ~2,460× on
Donut — and it fails as an opaque Uniswap `STF`. `lib/GasSwap.sol` prices it from the pool.

**`maxPCForGas` caps what reaches the swap; the rest is refunded.** Raising `msg.value` alone changes
nothing. A zero there means *uncapped*, which makes owner-path scripts pass while every agent-path
call fails — because gate 9 requires a non-zero cap.

**The deployed contracts differ from `-audit-main-fixes`.** Three measured divergences are recorded
in the spec's §3.10. `ref_contracts/` holds the branches that are actually deployed; read those.

## Where our responsibility ends

The Push-side transaction completing is the whole of what these contracts control. Delivery to the
far chain is an off-chain TSS committee. A slow far leg is not a bug in the mandate — every
Push-side decision is already final and verifiable on the explorer. `just watch-*` says exactly that
on timeout, and points at the gauntlet, which needs no relay.
