.PHONY: build test sizes

build:
	forge build

test:
	forge test -vv

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
