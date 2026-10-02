#!/usr/bin/env bash
# Pins AGW.execute() to its reviewed source text: the B2 checkpoint revision
# (docs-internal/sdk-first-changes/B2-checkpoints_prd.md), which added one checkpoint per call to
# the text at commit 67929f2 (+ the nomenclature change's AGWErrors rename).
#
# execute() is the owner door: it reads no module, policy or engine state; its only side effect
# besides the calls is one checkpoint write per call to the wallet's own slot 0, which cannot
# revert. This check proves the owner door was not edited — not a byte, not a comment. A Foundry
# test cannot do this: the repo grants fs_permissions read on out/ only, never src/.
#
# The extracted span is `function execute(bytes32 mode` through the first line that is exactly
# four spaces and a closing brace — the function's own closing brace at contract indentation.
set -euo pipefail

readonly EXPECTED_SHA256="09b35358ddbd29d942e44e48116ce63da71de5a21307fd929d79c4144b6976f7"
readonly SOURCE="src/AGW.sol"

actual="$(awk '/function execute\(bytes32 mode/{f=1} f{print; if ($0 == "    }") exit}' "$SOURCE" | shasum -a 256 | cut -d' ' -f1)"

if [[ "$actual" != "$EXPECTED_SHA256" ]]; then
    echo "check-execute: FAILED — AGW.execute() differs from its pinned text (the B2 checkpoint revision)" >&2
    echo "  expected $EXPECTED_SHA256" >&2
    echo "  actual   $actual" >&2
    exit 1
fi
echo "check-execute: OK — execute() is byte-identical to its pinned text (the B2 checkpoint revision)"
