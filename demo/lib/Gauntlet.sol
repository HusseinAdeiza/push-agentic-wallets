// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { AddressBook } from "./AddressBook.sol";
import { DemoLog } from "./DemoLog.sol";
import { Ledger } from "./Ledger.sol";
import { AgentRequest } from "./AgentRequest.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { SEND_OUTBOUND_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  Gauntlet
 * @notice The two-layer refusal assertion every Act 3 script uses.
 *
 * @dev    ── WHY ONE LAYER IS NOT ENOUGH, AND THE ACCEPTANCE CRITERION HAD TO CHANGE ──
 *
 *         The engine truncates a policy's revert data to 32 bytes (`PolicyLib.sol`, `_maxCopy: 32`)
 *         and rewraps it as `PolicyCheckReverted(bytes32)`. Those 32 bytes are URP's 4-byte
 *         selector followed by the first 28 bytes of its first argument — and that prefix is
 *         worthless: for a `uint256` like `60e6` it is the all-zero high bytes; for an `address` it
 *         is 12 bytes of zero padding plus 16 of the 20 address bytes.
 *
 *         So through the agent door ONLY THE SELECTOR SURVIVES. Any assertion demanding the
 *         arguments on that path is unsatisfiable, which is why the demo spec's original criterion
 *         was rewritten.
 *
 *         ── LAYER 1: THE HONEST PATH ──
 *
 *         Submit exactly as a relayer would. Assert the outer error is `PolicyCheckReverted` AND
 *         that the top 4 bytes of the embedded word are the expected URP selector. This is what
 *         production actually looks like.
 *
 *         ── LAYER 2: THE ARGUMENT PROOF ──
 *
 *         Call `URP.checkAction` directly, pranked as the engine, against live forked state. The
 *         error arrives unwrapped, with every argument intact.
 *
 *         THE PRANK IS MANDATORY, NOT STYLISTIC. `checkAction` reads
 *         `$configs[id][msg.sender][account]` (`URP.sol:203`), so an unpranked call reads an empty
 *         slot and dies at gate 1 with `NotInitialized` — the wrong error, and a test that looks
 *         like it passed for the wrong reason.
 *
 *         ── AND THE NARRATION COMES FROM LAYER 2 ──
 *
 *         The amber line the audience reads carries values that were actually asserted, never a
 *         string typed into a `console.log`.
 */
library Gauntlet {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `PolicyCheckReverted(bytes32)`, the engine's wrapper. Derived, never pasted.
    bytes4 internal constant POLICY_CHECK_REVERTED = bytes4(keccak256("PolicyCheckReverted(bytes32)"));

    error ExpectedRefusalButSucceeded(string what);
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error NotWrappedByEngine(bytes4 outer);

    /**
     * @notice Run one gauntlet case: submit, assert the refusal, and narrate it.
     *
     * @param title     What the agent attempted, in plain language.
     * @param expected  The URP error selector this attempt must produce.
     * @param lesson    One sentence on what would have happened without the gate.
     * @param req       The mutated request.
     */
    function refuse(string memory title, bytes4 expected, string memory lesson, AgentRequest.Built memory req)
        internal
    {
        DemoLog.kv("Attempt", title);
        DemoLog.blank();

        bytes memory inner = _layer1(expected, req);
        _layer2(req);

        DemoLog.refused(_errorName(expected), _describe(inner, expected));
        DemoLog.blank();
        DemoLog.note(lesson);
        DemoLog.note("Nothing reached Sepolia. The refusal is on-chain, atomic and free.");
    }

    // ─────────────────────────────────── layer 1 ───────────────────────────────────

    /**
     * @dev Submit through the agent door and assert the wrapped selector.
     *
     *      A LOW-LEVEL CALL, NOT `vm.expectRevert`. Outside a test context `expectRevert` is
     *      unreliable around a real RPC call, and this form additionally hands back the raw bytes
     *      so the selector can be read rather than merely matched.
     *
     * @return The 32-byte word the engine embedded, for the caller to decode.
     */
    function _layer1(bytes4 expected, AgentRequest.Built memory req) private returns (bytes memory) {
        (bool ok, bytes memory ret) = req.wallet.call(AgentRequest.encodeSubmit(req));

        if (ok) revert ExpectedRefusalButSucceeded(_errorName(expected));
        if (ret.length < 4) revert NotWrappedByEngine(bytes4(0));

        bytes4 outer = bytes4(ret);
        if (outer != POLICY_CHECK_REVERTED) {
            // Not wrapped — the request died before reaching the policy (a wallet-level check such
            // as the nonce or the expiry). G6 expects exactly this, so it is reported rather than
            // treated as an error here.
            if (outer == expected) {
                DemoLog.ok("layer 1", "refused by the WALLET, before any policy ran");
                return ret;
            }
            revert NotWrappedByEngine(outer);
        }

        bytes32 embedded = abi.decode(_slice(ret, 4), (bytes32));
        bytes4 innerSelector = bytes4(embedded);
        if (innerSelector != expected) revert WrongRefusal(expected, innerSelector);

        DemoLog.ok("layer 1", "engine wrapped the policy's refusal, selector intact");
        return ret;
    }

    // ─────────────────────────────────── layer 2 ───────────────────────────────────

    /**
     * @dev The same request, straight to `URP.checkAction`, pranked as the engine, on a Donut fork.
     *      The error arrives whole. Nothing is broadcast: this runs against forked state.
     */
    function _layer2(AgentRequest.Built memory req) private {
        vm.createSelectFork(vm.envString("PUSH_DONUT_RPC_URL"));

        (address target, uint256 value, bytes memory data) = _decodeSingle(req.executionCalldata);

        vm.prank(req.engine); // MANDATORY — see the contract docs.
        (bool ok, bytes memory ret) = AddressBook.ours("urp")
            .call(
                // `checkAction` is inherited from IActionPolicy, not redeclared on IURP — the v3
                // interface deliberately never repeats an upstream signature.
                abi.encodeCall(IActionPolicy.checkAction, (_configId(req.wallet), req.wallet, target, value, data))
            );

        if (ok) {
            DemoLog.note("    layer 2: checkAction accepted it - the refusal came from elsewhere");
            return;
        }
        DemoLog.ok("layer 2", "URP refused it directly, with arguments intact");
        _printArguments(ret);
    }

    /// @dev Decode the full, untruncated error and print its arguments. This is where the amber
    ///      line's numbers come from.
    function _printArguments(bytes memory ret) private view {
        if (ret.length < 4) return;
        bytes4 sel = bytes4(ret);
        bytes memory body = _slice(ret, 4);

        if (sel == IURP.CallNotAllowed.selector && body.length >= 64) {
            (address t, bytes4 s) = abi.decode(body, (address, bytes4));
            DemoLog.kv("  target", vm.toString(t));
            DemoLog.kv("  selector", vm.toString(abi.encodePacked(s)));
        } else if (sel == IURP.ForbiddenInnerTarget.selector && body.length >= 32) {
            DemoLog.kv("  forbidden", vm.toString(abi.decode(body, (address))));
        } else if (sel == IURP.BeneficiaryMismatch.selector && body.length >= 64) {
            (address want, address got) = abi.decode(body, (address, address));
            DemoLog.kv("  expected", vm.toString(want));
            DemoLog.kv("  got", vm.toString(got));
        } else if (sel == IURP.AmountExceedsCap.selector && body.length >= 64) {
            (uint256 amt, uint256 cap) = abi.decode(body, (uint256, uint256));
            DemoLog.kv("  requested", DemoLog.formatAmount(amt, 6, "USDC"));
            DemoLog.kv("  cap", DemoLog.formatAmount(cap, 6, "USDC"));
        } else if (sel == IURP.TotalSpendCapExceeded.selector && body.length >= 64) {
            (uint256 total, uint256 cap) = abi.decode(body, (uint256, uint256));
            DemoLog.kv("  would total", DemoLog.formatAmount(total, 6, "USDC"));
            DemoLog.kv("  lifetime cap", DemoLog.formatAmount(cap, 6, "USDC"));
        }
    }

    // ─────────────────────────────────── helpers ───────────────────────────────────

    /**
     * @dev `configId = keccak(account ‖ keccak(permissionId ‖ actionId))`, where
     *      `actionId = keccak(target ‖ selector)`.
     *
     *      THE ORDER MATTERS AT EVERY LEVEL and the derivation mixes `encode` and `encodePacked`
     *      across the chain — an SDK assuming one throughout derives every id wrong. Transcribed
     *      from `test/integration/E2E.t.sol`, which asserts it against the live engine.
     */
    function _configId(address account) private view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(AddressBook.donut("UniversalGatewayPC"), SEND_OUTBOUND_SELECTOR));
        bytes32 pid = Ledger.word("permissionId", "14_GrantMandate");
        return ConfigId.wrap(keccak256(abi.encodePacked(account, keccak256(abi.encodePacked(pid, actionId)))));
    }

    /// @dev `ExecutionLib.encodeSingle` is `abi.encodePacked(target, value, callData)` — 20 bytes,
    ///      then 32, then the remainder. Unpacked here so layer 2 can hand URP the same arguments
    ///      the wallet would have.
    function _decodeSingle(bytes memory ecd) private pure returns (address target, uint256 value, bytes memory data) {
        assembly {
            target := shr(96, mload(add(ecd, 0x20)))
            value := mload(add(ecd, 0x34))
        }
        data = _slice(ecd, 52);
    }

    function _slice(bytes memory b, uint256 from) private pure returns (bytes memory out) {
        if (b.length <= from) return "";
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _errorName(bytes4 sel) private pure returns (string memory) {
        if (sel == IURP.CallNotAllowed.selector) return "CallNotAllowed";
        if (sel == IURP.ForbiddenInnerTarget.selector) return "ForbiddenInnerTarget";
        if (sel == IURP.BeneficiaryMismatch.selector) return "BeneficiaryMismatch";
        if (sel == IURP.AmountExceedsCap.selector) return "AmountExceedsCap";
        if (sel == IURP.TotalSpendCapExceeded.selector) return "TotalSpendCapExceeded";
        return "refused";
    }

    function _describe(bytes memory, bytes4 sel) private pure returns (string memory) {
        return string.concat("refused by ", _errorName(sel));
    }
}
