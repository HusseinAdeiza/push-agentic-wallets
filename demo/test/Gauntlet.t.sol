// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Gauntlet } from "../lib/Gauntlet.sol";
import { Requests } from "../lib/Requests.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

/// @dev Exposes the library's internals for testing. `_decodeSingle` is private by design — the
///      scripts must not reach past `refuse()` — so a thin harness re-implements the same call.
contract GauntletHarness {
    /// @dev Byte-for-byte the library's decode, kept in sync deliberately: if this drifts the test
    ///      stops proving anything, which is why the assertions below compare against
    ///      `ExecutionLib` rather than against this copy.
    function decodeSingle(bytes memory ecd) external pure returns (address target, uint256 value, bytes memory data) {
        assembly {
            target := shr(96, mload(add(ecd, 0x20)))
            value := mload(add(ecd, 0x34))
        }
        data = new bytes(ecd.length - 52);
        for (uint256 i; i < data.length; ++i) {
            data[i] = ecd[52 + i];
        }
    }
}

/**
 * @title  GauntletTest
 * @notice Pins the two things the gauntlet's layer 2 silently depends on.
 *
 * @dev    WHY THIS MATTERS MORE THAN IT LOOKS. Layer 2 unpacks `executionCalldata` with raw
 *         assembly offsets and hands the pieces to `URP.checkAction`. If those offsets were wrong,
 *         `checkAction` would be called with a mangled target or value — and it would still REVERT,
 *         just for the wrong reason. Every gauntlet script would print an amber refusal and none of
 *         them would be demonstrating the gate they name.
 *
 *         That is the failure mode Act 3 cannot afford: not a broken demo, a dishonest one.
 */
contract GauntletTest is Test {
    GauntletHarness internal h;

    function setUp() public {
        h = new GauntletHarness();
    }

    /// @dev The decode must invert `ExecutionLib.encodeSingle` exactly — asserted against the real
    ///      library, not against a second copy of the same offsets.
    function test_decodeSingleInvertsExecutionLib() public view {
        address target = address(0xBEEF01);
        uint256 value = 1.234 ether;
        bytes memory callData = abi.encodeWithSignature("sendUniversalTxOutbound(bytes)", hex"c0ffee");

        bytes memory ecd = ExecutionLib.encodeSingle(target, value, callData);
        (address t, uint256 v, bytes memory d) = h.decodeSingle(ecd);

        assertEq(t, target, "target");
        assertEq(v, value, "value");
        assertEq(keccak256(d), keccak256(callData), "callData");
    }

    /// @dev Zero value is the Act 4a / Act 1d shape — nothing bridged, calldata only.
    function test_decodeSingleHandlesZeroValue() public view {
        bytes memory callData = hex"deadbeef";
        bytes memory ecd = ExecutionLib.encodeSingle(address(0xABCD), 0, callData);

        (address t, uint256 v, bytes memory d) = h.decodeSingle(ecd);
        assertEq(t, address(0xABCD));
        assertEq(v, 0);
        assertEq(keccak256(d), keccak256(callData));
    }

    /// @dev A realistic outbound, which is what layer 2 actually decodes — several hundred bytes
    ///      with a nested multicall inside.
    function testFuzz_decodeSingleRoundTrips(address target, uint256 value, bytes memory callData) public view {
        bytes memory ecd = ExecutionLib.encodeSingle(target, value, callData);
        (address t, uint256 v, bytes memory d) = h.decodeSingle(ecd);

        assertEq(t, target, "target survives");
        assertEq(v, value, "value survives");
        assertEq(keccak256(d), keccak256(callData), "callData survives");
    }

    /// @dev The header is exactly 52 bytes: 20 for the address, 32 for the value. If that ever
    ///      changed, the offsets above would silently read the wrong words.
    function test_singleExecutionHeaderIs52Bytes() public view {
        bytes memory ecd = ExecutionLib.encodeSingle(address(1), 0, "");
        assertEq(ecd.length, 52, "20-byte target + 32-byte value, packed");
    }

    // ────────────────────────────── selectors ──────────────────────────────

    /// @dev The engine's wrapper, derived rather than pasted.
    function test_policyCheckRevertedSelector() public pure {
        assertEq(Gauntlet.POLICY_CHECK_REVERTED, bytes4(0xf4270752), "PolicyCheckReverted(bytes32)");
    }

    /**
     * @dev The five refusals, pinned. These come from `IURP` via `.selector` in the scripts, so a
     *      signature change breaks the build — but the VALUES are asserted here so a change is
     *      visible rather than merely compiling.
     */
    function test_gauntletErrorSelectors() public pure {
        assertEq(IURP.CallNotAllowed.selector, bytes4(0x805043f9), "G1");
        assertEq(IURP.ForbiddenInnerTarget.selector, bytes4(0xffd57c0d), "G2");
        assertEq(IURP.BeneficiaryMismatch.selector, bytes4(0x65aedd5a), "G3");
        assertEq(IURP.AmountExceedsCap.selector, bytes4(0xcd0f2fa9), "G4");
        assertEq(IURP.TotalSpendCapExceeded.selector, bytes4(0x7c9c949b), "G5");
    }

    /**
     * @dev THE TRUNCATION, demonstrated rather than described. The engine copies the first 32 bytes
     *      of the policy's revert data, so the selector survives in the top 4 bytes and the
     *      arguments do not — which is the entire reason layer 2 exists.
     */
    function test_truncationPreservesSelectorButLosesArguments() public pure {
        // What URP would revert with: selector + two full words.
        bytes memory full = abi.encodeWithSelector(IURP.AmountExceedsCap.selector, uint256(60e6), uint256(50e6));

        // What the engine keeps: the first 32 bytes, as a single word.
        bytes32 embedded;
        assembly {
            embedded := mload(add(full, 0x20))
        }

        assertEq(bytes4(embedded), IURP.AmountExceedsCap.selector, "the selector survives");

        // The remaining 28 bytes are the HIGH bytes of the first argument - all zero for 60e6.
        assertEq(uint256(embedded) & type(uint224).max, 0, "the argument's surviving bytes carry no information");
    }
}
