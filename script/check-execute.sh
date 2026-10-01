#!/usr/bin/env bash
# Pins AGW.execute() to its audited source text: the text at commit 67929f2 with one rename
# applied by the nomenclature change (docs-internal/sdk-first-changes/N-nomenclature_prd.md) —
# `PushWalletErrors.` became `AGWErrors.` on its two revert lines. No other byte differs.
#
# execute() is the owner door: it must read nothing but the immutable-args owner and its calldata.
# The UniversalMarketplace change adds two sibling doors to the same contract; this check proves the
# owner door itself was not edited — not a byte, not a comment. A Foundry test cannot do this: the
# repo grants fs_permissions read on out/ only, never src/.
#
# The extracted span is `function execute(bytes32 mode` through the first line that is exactly
# four spaces and a closing brace — the function's own closing brace at contract indentation.
set -euo pipefail

readonly EXPECTED_SHA256="d10169cb8d55cb5948fc723344468826794cb1760eca60ff17fe335041e4e9ae"
readonly SOURCE="src/AGW.sol"

actual="$(awk '/function execute\(bytes32 mode/{f=1} f{print; if ($0 == "    }") exit}' "$SOURCE" | shasum -a 256 | cut -d' ' -f1)"

if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    echo "check-execute: FAILED — AGW.execute() differs from its pinned text (67929f2 + the nomenclature rename)" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  actual   $actual" >&2
    exit 1
fi
echo "check-execute: OK — execute() is byte-identical to its pinned text (67929f2 + the nomenclature rename)"
