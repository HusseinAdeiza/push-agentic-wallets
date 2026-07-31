// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import {
    ModeLib,
    ModeCode,
    CallType,
    ExecType,
    ModeSelector,
    ModePayload,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_STATIC,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY,
    MODE_DEFAULT
} from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { MockTarget, RejectsPC } from "../mocks/Mocks.sol";

/// @dev Exposes the calldata-only decoders through an external boundary.
contract DecodeHarness {
    function decodeSingle(bytes calldata ecd) external pure returns (address, uint256, bytes memory) {
        (address t, uint256 v, bytes calldata cd) = ExecutionLib.decodeSingle(ecd);
        return (t, v, cd);
    }

    function decodeBatch(bytes calldata ecd) external pure returns (Execution[] memory) {
        return ExecutionLib.decodeBatch(ecd);
    }
}

/// @notice Closes coverage on the shared libraries and the remaining revert paths.
contract LibrariesTest is Test {
    DecodeHarness internal h;

    function setUp() public {
        h = new DecodeHarness();
    }

    // ── ModeLib ───────────────────────────────────────────────────────

    function test_encodeDecodeRoundTrip() public pure {
        ModeCode m = ModeLib.encode(
            CALLTYPE_BATCH, EXECTYPE_TRY, ModeSelector.wrap(bytes4(0xaabbccdd)), ModePayload.wrap(bytes22(uint176(42)))
        );
        (CallType ct, ExecType et, ModeSelector ms, ModePayload mp) = ModeLib.decode(m);

        assertEq(CallType.unwrap(ct), CallType.unwrap(CALLTYPE_BATCH));
        assertEq(ExecType.unwrap(et), ExecType.unwrap(EXECTYPE_TRY));
        assertEq(ModeSelector.unwrap(ms), bytes4(0xaabbccdd));
        assertEq(ModePayload.unwrap(mp), bytes22(uint176(42)));
    }

    function test_getCallType() public pure {
        assertEq(CallType.unwrap(ModeLib.getCallType(ModeLib.encodeSimpleSingle())), CallType.unwrap(CALLTYPE_SINGLE));
        assertEq(CallType.unwrap(ModeLib.getCallType(ModeLib.encodeSimpleBatch())), CallType.unwrap(CALLTYPE_BATCH));

        ModeCode dc = ModeLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0));
        assertEq(CallType.unwrap(ModeLib.getCallType(dc)), CallType.unwrap(CALLTYPE_DELEGATECALL));
    }

    function test_simpleEncoders() public pure {
        (CallType ct, ExecType et,,) = ModeLib.decode(ModeLib.encodeSimpleSingle());
        assertTrue(ct == CALLTYPE_SINGLE);
        assertTrue(et == EXECTYPE_DEFAULT);

        (CallType ct2, ExecType et2,,) = ModeLib.decode(ModeLib.encodeSimpleBatch());
        assertTrue(ct2 == CALLTYPE_BATCH);
        assertTrue(et2 == EXECTYPE_DEFAULT);
    }

    function test_typeComparators() public pure {
        assertTrue(CALLTYPE_SINGLE == CALLTYPE_SINGLE);
        assertTrue(CALLTYPE_SINGLE != CALLTYPE_BATCH);
        assertTrue(EXECTYPE_DEFAULT == EXECTYPE_DEFAULT);
        assertTrue(EXECTYPE_DEFAULT != EXECTYPE_TRY);
        assertTrue(MODE_DEFAULT == MODE_DEFAULT);
        assertTrue(CALLTYPE_STATIC != CALLTYPE_DELEGATECALL);
    }

    // ── ExecutionLib ──────────────────────────────────────────────────

    function test_encodeDecodeSingle() public view {
        bytes memory cd = abi.encodeCall(MockTarget.setValue, (7));
        bytes memory encoded = ExecutionLib.encodeSingle(address(0xBEEF), 1 ether, cd);

        (address t, uint256 v, bytes memory got) = h.decodeSingle(encoded);
        assertEq(t, address(0xBEEF));
        assertEq(v, 1 ether);
        assertEq(got, cd);
    }

    function test_encodeDecodeBatch() public view {
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution(address(0xAAA1), 1, hex"1122");
        execs[1] = Execution(address(0xBBB2), 2, hex"3344");

        Execution[] memory got = h.decodeBatch(ExecutionLib.encodeBatch(execs));

        assertEq(got.length, 2);
        assertEq(got[0].target, address(0xAAA1));
        assertEq(got[0].value, 1);
        assertEq(got[0].callData, hex"1122");
        assertEq(got[1].target, address(0xBBB2));
        assertEq(got[1].value, 2);
        assertEq(got[1].callData, hex"3344");
    }

    function test_encodeBatchEmpty() public view {
        Execution[] memory execs = new Execution[](0);
        assertEq(h.decodeBatch(ExecutionLib.encodeBatch(execs)).length, 0);
    }

    // ── remaining wallet revert paths ─────────────────────────────────

    /// callValidator must bubble the validator's raw revert data.
    function test_callValidatorBubblesRawRevertData() public {
        PushAgentWallet impl = new PushAgentWallet();
        AgentWalletFactory f = new AgentWalletFactory(address(impl));
        address owner = address(0xB0B);

        vm.prank(owner);
        PushAgentWallet w = PushAgentWallet(payable(f.deployAgentWallet(keccak256("bubble"))));

        Reverter r = new Reverter();
        vm.startPrank(owner);
        w.installModule(1, address(r), "");

        vm.expectRevert(abi.encodeWithSelector(Reverter.CustomFailure.selector, uint256(99)));
        w.callValidator(address(r), abi.encodeCall(Reverter.boom, ()));
        vm.stopPrank();
    }

    /// The factory rejects a zero implementation.
    function test_factoryRejectsZeroImplementation() public {
        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new AgentWalletFactory(address(0));
    }

    /// PushSessionValidator's stateless lifecycle hooks are callable no-ops.
    function test_validatorLifecycleHooks() public {
        PushSessionValidator v = new PushSessionValidator();
        v.onInstall(hex"00");
        v.onUninstall(hex"00");
        assertTrue(v.isInitialized(address(0xB0B)));
        assertTrue(v.isModuleType(7));
    }
}

contract Reverter {
    error CustomFailure(uint256 code);

    function boom() external pure {
        revert CustomFailure(99);
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 1;
    }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}
