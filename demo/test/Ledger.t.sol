// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

/**
 * @title  LedgerTest
 * @notice Pins the two `vm` behaviours `Ledger` depends on, and the zero-value rule that follows.
 *
 * @dev    ── THE BUG THIS EXISTS TO PREVENT, AND IT WAS REAL ──
 *
 *         `90_StopAll` marked a mandate revoked by writing `permissionId = 0`. `Ledger.has()` only
 *         asked whether the KEY EXISTED, so it answered true — and `word()`, which treats zero as
 *         missing, then reverted. Every script that branches on `has()` before reading walked
 *         straight into it: `just state` and `just preflight` both died, on a ledger that looked
 *         perfectly fine.
 *
 *         The rule is therefore: **`has()` and the typed reads must agree on what "absent" means.**
 *
 *         ── WHY THESE TESTS USE THEIR OWN FILE ──
 *
 *         `Ledger.PATH` is a constant pointing at the real rehearsal ledger, and forge runs tests
 *         in parallel against one filesystem. An earlier version of this file drove `Ledger`
 *         directly and the tests clobbered each other — and once left a live ledger reduced to
 *         `{"nonceSeq":0}`.
 *
 *         Adding a path parameter to `Ledger` purely so it could be tested would be design for the
 *         test rather than the demo. Instead these assert the CHEATCODE BEHAVIOURS the library is
 *         built on, against a file of their own, in one test so nothing races. The library's own
 *         behaviour on those primitives is verified live: injecting a zeroed `permissionId` into
 *         the real ledger and confirming `just state` and `just preflight` both recover.
 */
contract LedgerTest is Test {
    string internal constant PATH = "demo/state/_ledger_test.json";

    /// @dev One test, because parallel tests sharing a file race. Each stage is labelled.
    function test_theBehavioursLedgerReliesOn() public {
        // ── a zeroed word parses to exactly 32 zero bytes ──
        vm.writeFile(PATH, "{}");
        vm.writeJson(vm.toString(bytes32(0)), PATH, ".zeroed");
        bytes memory raw = vm.parseJson(vm.readFile(PATH), ".zeroed");
        assertEq(raw.length, 32, "a zeroed word is 32 bytes");
        assertEq(abi.decode(raw, (bytes32)), bytes32(0), "and they are all zero");
        assertTrue(vm.keyExistsJson(vm.readFile(PATH), ".zeroed"), "keyExists says PRESENT");
        // ^ THE TRAP: the key exists, so a naive `has()` returns true while `word()` reverts.

        // ── a real word is distinguishable ──
        vm.writeJson(vm.toString(keccak256("real")), PATH, ".real");
        assertTrue(
            abi.decode(vm.parseJson(vm.readFile(PATH), ".real"), (bytes32)) != bytes32(0), "a real value is non-zero"
        );

        // ── writing `null` sets the value to JSON null, and PARSES TO 32 ZERO BYTES ──
        // The key still EXISTS, so `keyExistsJson` alone cannot tell cleared from present. But a
        // null and a zeroed value parse identically, so the single 32-zero-bytes check in `has()`
        // covers both — which is why `clear()` can write `null` and needs no separate branch.
        vm.writeJson("null", PATH, ".zeroed");
        assertTrue(vm.keyExistsJson(vm.readFile(PATH), ".zeroed"), "the key still exists");
        assertEq(
            abi.decode(vm.parseJson(vm.readFile(PATH), ".zeroed"), (bytes32)),
            bytes32(0),
            "a null parses to 32 zero bytes, exactly like a zeroed value"
        );

        // ── and later writes still work afterwards ──
        // An empty string does NOT: it leaves a value `writeJson` refuses to insert alongside,
        // which is why `clear()` writes `null` rather than "".
        vm.writeJson(vm.toString(uint256(7)), PATH, ".after");
        assertEq(vm.parseJsonUint(vm.readFile(PATH), ".after"), 7, "the file is still writable");

        // ── other keys survive a targeted write ──
        assertTrue(vm.keyExistsJson(vm.readFile(PATH), ".real"), "unrelated keys are preserved");

        vm.removeFile(PATH);
    }
}
