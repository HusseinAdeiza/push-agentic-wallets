#!/usr/bin/env bash
# Pins PushAgentWallet.execute() to its audited source text at commit 67929f2.
#
# execute() is the owner door: it must read nothing but the immutable-args owner and its calldata.
# The UniversalMarketplace change adds two sibling doors to the same contract; this check proves the
# owner door itself was not edited — not a byte, not a comment. A Foundry test cannot do this: the
# repo grants fs_permissions read on out/ only, never src/.
#
# The extracted span is `function execute(bytes32 mode` through the first line that is exactly
# four spaces and a closing brace — the function's own closing brace at contract indentation.
set -euo pipefail

readonly EXPECTED_SHA256="9d7c4c8da373b3476d8d7714427a6a6abf9b0f1991b9950d0170accfbbb083f2"
readonly SOURCE="src/PushAgentWallet.sol"

actual="$(awk '/function execute\(bytes32 mode/{f=1} f{print; if ($0 == "    }") exit}' "$SOURCE" | shasum -a 256 | cut -d' ' -f1)"

if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    echo "check-execute: FAILED — PushAgentWallet.execute() differs from 67929f2" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  actual   $actual" >&2
    exit 1
fi
echo "check-execute: OK — execute() is byte-identical to 67929f2"
