// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

import { IURP } from "../../src/interfaces/IURP.sol";

import { Amounts } from "./Amounts.sol";
import { DemoLog } from "./DemoLog.sol";
import { NativeRequest } from "./NativeRequest.sol";

/**
 * @title  NativeGauntlet
 * @notice Submits a deliberately-broken request, asserts the NAMED refusal, and narrates it.
 *
 * @dev    TWO REFUSAL PATHS, AND THE DISTINCTION IS THE WHOLE POINT OF THIS FILE.
 *
 *         A native mandate binds `(target, selector)` into the engine's ACTION ID. So a request
 *         naming a different target or a different function does not reach URP at all — the engine
 *         finds no matching action and refuses first. Only requests that DO match an action reach
 *         the policy, and only those come back wrapped.
 *
 *           · `refuseGate(innerSelector)` — URP gates (G3, G4, G5, G7, G8). The engine truncates
 *             policy revert data to 32 bytes and rewraps it as `PolicyCheckReverted(bytes32)`, so
 *             this path asserts the outer selector is the wrapper and then compares the INNER one.
 *           · `refuseRaw(selector)` — the engine and the wallet (G1, G2, G6, 4b, 4e). These are
 *             NOT wrapped; they arrive bare.
 *
 *         A single-path port of `demo/lib/Gauntlet.sol` is BROKEN for half this demo's gauntlet:
 *         its `_layer1` asserts the wrapper unconditionally and would report every engine and
 *         wallet refusal as `NotWrappedByEngine`.
 *
 * @dev    A LOW-LEVEL CALL, NOT `vm.expectRevert`. `expectRevert` is a test cheatcode; it does not
 *         belong in a broadcast script, and this form additionally hands back the raw bytes so the
 *         selector can be READ rather than merely matched — which is what lets the amber line on
 *         screen carry values that were actually asserted.
 */
library NativeGauntlet {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `PolicyCheckReverted(bytes32)`, the engine's wrapper. DERIVED, never pasted.
    bytes4 internal constant POLICY_CHECK_REVERTED = bytes4(keccak256("PolicyCheckReverted(bytes32)"));

    error ExpectedRefusalButSucceeded(string what);
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error NotWrappedByEngine(bytes4 outer);
    error UnexpectedRawRefusal(bytes4 expected, bytes4 actual);
    error NoRevertData();

    /**
     * @notice A refusal that comes from URP, wrapped by the engine.
     *
     * @param title    What the agent attempted, in plain language.
     * @param expected The URP error selector this attempt must produce.
     * @param lesson   One sentence on what would have happened without the gate.
     * @param req      The mutated request.
     */
    function refuseGate(string memory title, bytes4 expected, string memory lesson, NativeRequest.Built memory req)
        internal
    {
        DemoLog.kv("Attempt", title);
        DemoLog.blank();

        bytes memory ret = _submitExpectingFailure(expected, req);

        bytes4 outer = bytes4(ret);
        if (outer != POLICY_CHECK_REVERTED) revert NotWrappedByEngine(outer);

        bytes32 embedded = abi.decode(_slice(ret, 4), (bytes32));
        bytes4 inner = bytes4(embedded);
        if (inner != expected) revert WrongRefusal(expected, inner);

        DemoLog.ok("engine", "wrapped URP's refusal, selector intact");
        DemoLog.refused(_urpErrorName(expected), "the policy refused it before anything moved");
        _printTruncatedArgument(expected, embedded);

        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing moved. The refusal is on-chain, atomic and costs only gas.");
    }

    /**
     * @notice A refusal that comes from the ENGINE or the WALLET, unwrapped.
     *
     * @dev    `expected` here is a full error selector — `ISmartSession.NoPoliciesSet.selector`,
     *         `PushWalletErrors.InvalidNonce.selector`, `ISmartSession.InvalidPermissionId.selector`
     *         — not a URP gate.
     */
    function refuseRaw(
        string memory title,
        bytes4 expected,
        string memory who,
        string memory lesson,
        NativeRequest.Built memory req
    ) internal {
        DemoLog.kv("Attempt", title);
        DemoLog.blank();

        bytes memory ret = _submitExpectingFailure(expected, req);

        bytes4 outer = bytes4(ret);
        if (outer == POLICY_CHECK_REVERTED) {
            // It reached the policy. For G1/G2 that would mean the action id MATCHED, which is the
            // opposite of what the act claims — so this is a real failure, not a near miss.
            revert UnexpectedRawRefusal(expected, outer);
        }
        if (outer != expected) revert UnexpectedRawRefusal(expected, outer);

        DemoLog.ok(who, "refused it before any policy ran");
        DemoLog.refused(_rawErrorName(expected), string.concat("URP never executed - ", who, " stopped it first"));

        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing moved. The refusal is on-chain, atomic and costs only gas.");
    }

    // ──────────────────────────────── internals ────────────────────────────────

    /// @dev Submit and require failure. Returns the raw revert data for the caller to decode.
    function _submitExpectingFailure(bytes4 expected, NativeRequest.Built memory req) private returns (bytes memory) {
        (bool ok, bytes memory ret) = req.wallet.call(NativeRequest.encodeSubmit(req));

        if (ok) revert ExpectedRefusalButSucceeded(_anyErrorName(expected));
        if (ret.length < 4) revert NoRevertData();
        return ret;
    }

    /**
     * @dev Report what the 32-byte truncation ACTUALLY preserves — which is less than it looks.
     *
     *      ⚠️ MEASURED ON A LIVE RUN, NOT ASSUMED. `PolicyLib.callPolicy` uses `_maxCopy: 32`, so
     *      the engine keeps only the FIRST 32 BYTES of URP's revert data. Those 32 bytes are URP's
     *      own 4-byte selector followed by just the FIRST 28 BYTES of argument 1 — and a `uint256`
     *      is RIGHT-ALIGNED in its word, so a demo-sized number lives entirely in the last 4 bytes,
     *      which are exactly the bytes thrown away.
     *
     *      SO THE NUMBER IS UNRECOVERABLE HERE, and printing a decoded "0.00 dUSDC" would be worse
     *      than printing nothing: it states a false fact with the authority of a chain read. The
     *      first live run of this demo did exactly that, which is why this function no longer tries.
     *
     *      WHAT SURVIVES IS THE SELECTOR — which gate fired, named — and that is the claim the
     *      gauntlet actually makes. The REQUESTED values are printed by each script from its own
     *      inputs, where they are known exactly.
     *
     *      An address pin is the one partial exception: an address occupies bytes 12..31 of its
     *      word, so truncation keeps its leading 16 bytes. Enough to see a mismatch, not enough to
     *      reconstruct — so it is shown as a partial, labelled as one.
     */
    function _printTruncatedArgument(bytes4 expected, bytes32 embedded) private view {
        if (expected == IURP.ArgPinMismatch.selector) {
            // Strip URP's selector; what remains is the first 28 bytes of the offending word.
            DemoLog.kv("  received word (partial)", vm.toString(bytes32(uint256(embedded) << 32)));
            DemoLog.note("      truncated by the engine to 32 bytes - the selector survives whole,");
            DemoLog.note("      the argument does not. The full value is in the script's own output.");
        } else {
            DemoLog.note("      the engine truncates policy reverts to 32 bytes: the GATE is named");
            DemoLog.note("      exactly, the argument is not recoverable. Requested values above.");
        }
    }

    /// @dev Names for the URP gates this demo exercises.
    function _urpErrorName(bytes4 s) private pure returns (string memory) {
        if (s == IURP.ArgPinMismatch.selector) return "ArgPinMismatch";
        if (s == IURP.NativeAmountExceedsCap.selector) return "NativeAmountExceedsCap";
        if (s == IURP.TotalNativeAmountExceeded.selector) return "TotalNativeAmountExceeded";
        if (s == IURP.ValueExceedsCap.selector) return "ValueExceedsCap";
        if (s == IURP.CallLimitReached.selector) return "CallLimitReached";
        if (s == IURP.MandateExpired.selector) return "MandateExpired";
        if (s == IURP.TargetMismatch.selector) return "TargetMismatch";
        if (s == IURP.SelectorMismatch.selector) return "SelectorMismatch";
        return "a URP gate";
    }

    /// @dev Names for engine and wallet errors. Selectors are DERIVED from their signatures so this
    ///      file does not have to import the engine's interface for a string.
    function _rawErrorName(bytes4 s) private pure returns (string memory) {
        if (s == bytes4(keccak256("NoPoliciesSet(bytes32)"))) return "NoPoliciesSet";
        if (s == bytes4(keccak256("InvalidPermissionId(bytes32)"))) return "InvalidPermissionId";
        if (s == bytes4(keccak256("InvalidNonce(uint192,uint64,uint64)"))) return "InvalidNonce";
        return "a refusal";
    }

    function _anyErrorName(bytes4 s) private pure returns (string memory) {
        string memory urp = _urpErrorName(s);
        if (keccak256(bytes(urp)) != keccak256(bytes("a URP gate"))) return urp;
        return _rawErrorName(s);
    }

    /// @dev `bytes` slice from `start` to the end.
    function _slice(bytes memory data, uint256 start) private pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }
}
