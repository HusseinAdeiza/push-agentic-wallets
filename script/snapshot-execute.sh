#!/usr/bin/env bash
# A WARNING, never a gate: compares the owner-door (execute) tests' gas against the 67929f2 baseline
# in .gas-snapshot-execute and flags any that moved by more than TOLERANCE gas.
#
# Adding functions to the wallet shifts the selector dispatcher and the code size, so gas moves with
# execute() itself untouched. MEASURED when the owner-intent doors were added: test_AccountId, a
# constant view, moved 172 gas; the owner-door tests moved 223-794. The tolerance is set above that
# noise floor. The binding pins on execute() are script/check-execute.sh and
# test_W_execute_readsNoStorage — never this. `forge snapshot --tolerance` is a percentage, which is
# why this is a script and not a flag.
set -euo pipefail

readonly BASELINE=".gas-snapshot-execute"
readonly TOLERANCE=1000
# SurvivesDegradedMatrix is excluded: it deploys wallets and hostile modules, so it measures deployment.
readonly OWNER_DOOR_TESTS="OwnerPath_RejectsNonOwner|OwnerPath_BubblesInnerRevert|OwnerDoor_|W23_Events_Attribution_OwnerDoor"
current="$(mktemp)"
trap 'rm -f "$current"' EXIT

forge snapshot --match-contract PushAgentWalletTest --snap "$current" >/dev/null

awk -v tol="$TOLERANCE" -v doors="$OWNER_DOOR_TESTS" '
    function gas(line) { if (match(line, /gas: [0-9]+/)) return substr(line, RSTART + 5, RLENGTH - 5); return "" }
    function name(line) { sub(/ \(gas:.*$/, "", line); return line }
    NR == FNR { base[name($0)] = gas($0); next }
    {
        n = name($0); g = gas($0)
        if (n !~ doors) next
        if (!(n in base) || base[n] == "" || g == "") next
        d = g - base[n]; if (d < 0) d = -d
        if (d > tol) { printf "WARN %s moved %d gas (%s -> %s)\n", n, d, base[n], g; warned = 1 }
    }
    END { if (!warned) print "snapshot-execute: all owner-door tests within " tol " gas of 67929f2" }
' "$BASELINE" "$current"
