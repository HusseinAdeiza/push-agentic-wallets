.PHONY: build test sizes check-execute snapshot-execute e2e

build:
	forge build

test: check-execute
	forge test -vv

# execute() — the owner door — must stay byte-identical to its reviewed text (the B2 checkpoint
# revision). The binding pins are this source hash and test_W_execute_touchesOnlyTheCheckpointSlot
# (wallet storage access to slot 0 only, no engine access).
check-execute:
	./script/check-execute.sh

# A WARNING, never a gate. Adding functions to the wallet shifts the selector dispatcher, so the
# execute() tests' gas can move by a few tens of units with execute() itself untouched. Tolerance is
# 100 gas; a larger move is worth a look, not a failure. The baseline in .gas-snapshot-execute was
# regenerated from the B2 checkpoint revision.
snapshot-execute:
	./script/snapshot-execute.sh

# The S-06 size gate. `forge build --sizes` exits non-zero when any runtime exceeds
# EIP-170's 24,576 bytes.
#
# The second line is deliberate redundancy, not duplication. Which contracts the default
# table covers is FORGE-VERSION-DEPENDENT: on 1.5.1-stable it includes lib/ (41 rows,
# SmartSession among them); on 1.6.0-nightly it reported src/ only (5 rows) and the engine
# was absent. SmartSession has the smallest margin in the whole build (22,581 B / +1,995),
# so it is sized explicitly and unconditionally. Keep both lines: the gate must not depend
# on a reporting default that has already changed once.
sizes:
	forge build --sizes
	forge build --sizes --contracts lib/smartsessions/contracts/SmartSession.sol

# The UniversalMarketplace E2E deploys the core repo's own build artifacts, so core is built first —
# test_E2E_13 fails on a stale artifact, and this target is what keeps it from being stale.
#
# `git submodule update --init --recursive` inside core: a fresh submodule checkout has an EMPTY lib/, and
# core's own OZ 5.3 and forge-std must be present for its build (and for the artifact to be the shipped one).
e2e:
	cd lib/push-chain-core-contracts && git submodule update --init --recursive && forge build
	@echo "The Marketplace E2E is parked (test/integration/24_marketplaceE2E.t.sol.parked) pending its rewrite against core's new marketplace surface."; exit 1
