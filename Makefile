.PHONY: build test sizes

build:
	forge build

test:
	forge test -vv

# The S-06 size gate. `forge build --sizes` exits non-zero when any runtime exceeds
# EIP-170's 24,576 bytes.
#
# NOTE: `forge build --sizes` alone reports src/ only. The vendored SmartSession lives in
# lib/ and has the smallest margin in the build (22,581 B / +1,995), so it must be sized
# explicitly or the gate would miss the one contract most at risk.
sizes:
	forge build --sizes
	forge build --sizes --contracts lib/smartsessions/contracts/SmartSession.sol
