// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
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
import {
    MockValidator,
    StubbornValidator,
    ReenteringValidator,
    MockTarget,
    MockHook,
    RejectsPC
} from "../mocks/Mocks.sol";

/// @notice PRD §11.1 — unit tests U-01 … U-23.
contract PushAgentWalletTest is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;
    PushAgentWallet internal wallet;

    address internal ownerUEA = address(0xB0B);
    address internal guardian = address(0x6DA);
    address internal stranger = address(0xBAD);
    bytes32 internal mandateId = keccak256("mandate-1");

    MockValidator internal validator;
    MockTarget internal target;

    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);
    event WalletInitialized(address indexed owner);
    event PCSwept(address indexed to, uint256 amount);
    event EmergencyRevokeAll(address indexed caller);

    function setUp() public {
        impl = _newImpl();
        factory = new AgentWalletFactory(address(impl));
        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(guardian)));

        validator = new MockValidator();
        target = new MockTarget();
    }

    // ── U-01 / U-02 — initialization ──────────────────────────────────

    function test_U01_initializeSetsOwner_secondCallReverts() public {
        assertEq(wallet.owner(), ownerUEA);
        vm.expectRevert(PushWalletErrors.AlreadyInitialized.selector);
        wallet.initialize(address(0xdead), address(0));
    }

    function test_U02_initializeZeroAddressReverts() public {
        PushAgentWallet fresh = _newImpl();
        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        fresh.initialize(address(0), address(0));
    }

    function test_U01b_initializeEmitsEvent() public {
        PushAgentWallet fresh = _newImpl();
        vm.expectEmit(true, false, false, true);
        emit WalletInitialized(ownerUEA);
        fresh.initialize(ownerUEA, guardian);
        assertEq(fresh.owner(), ownerUEA);
        assertEq(fresh.guardian(), guardian, "guardian set at initialize");
    }

    // ── T-06 / T-07 / T-08 — v2 constructor immutables (PRD Step 3) ───

    /**
     * T-06 — every immutable getter returns its own constructor argument.
     *
     * Deliberately uses five DISTINCT addresses, so this catches a transposition (two
     * arguments swapped) and not merely a zero. That matters because these five values are
     * what make the grant guards tamper-proof: `_requireSafeActions` compares action
     * targets and policies against `SMART_SESSION`, `UNIVERSAL_GATEWAY_PC`,
     * `ACP_ACTION_POLICY` and `VALUE_LIMIT_POLICY`, and `_requireBoundedSession` compares
     * against `TIMEFRAME_POLICY`. A swapped pair would leave G2/G3a/G3b comparing against
     * the wrong contract and silently passing sessions they should reject.
     *
     * They are immutables rather than storage precisely so no later write can redefine
     * what "safe session" means.
     */
    function test_T06_immutableGettersReturnConstructorArguments() public {
        address ss = address(0xAAA1);
        address gw = address(0xAAA2);
        address acp = address(0xAAA3);
        address tf = address(0xAAA4);
        address vl = address(0xAAA5);

        PushAgentWallet w = new PushAgentWallet(ss, gw, acp, tf, vl);

        assertEq(w.SMART_SESSION(), ss, "SMART_SESSION");
        assertEq(w.UNIVERSAL_GATEWAY_PC(), gw, "UNIVERSAL_GATEWAY_PC");
        assertEq(w.ACP_ACTION_POLICY(), acp, "ACP_ACTION_POLICY");
        assertEq(w.TIMEFRAME_POLICY(), tf, "TIMEFRAME_POLICY");
        assertEq(w.VALUE_LIMIT_POLICY(), vl, "VALUE_LIMIT_POLICY");
    }

    /// @dev Clones share the implementation's immutables, because immutables live in the
    ///      implementation's code rather than in storage. This is what lets one deployed
    ///      implementation serve every user's wallet with identical, unrewritable guards.
    function test_T06b_clonesInheritTheImplementationImmutables() public view {
        assertEq(wallet.SMART_SESSION(), impl.SMART_SESSION());
        assertEq(wallet.UNIVERSAL_GATEWAY_PC(), impl.UNIVERSAL_GATEWAY_PC());
        assertEq(wallet.ACP_ACTION_POLICY(), impl.ACP_ACTION_POLICY());
        assertEq(wallet.TIMEFRAME_POLICY(), impl.TIMEFRAME_POLICY());
        assertEq(wallet.VALUE_LIMIT_POLICY(), impl.VALUE_LIMIT_POLICY());
    }

    /**
     * T-07 — a zero address in ANY of the five constructor positions reverts.
     *
     * Tested position by position rather than in aggregate: a single all-zero case would
     * pass even if only the first check existed, leaving the other four unguarded.
     */
    function test_T07_zeroAddressInAnyConstructorPositionReverts() public {
        address ok1 = address(0xAAA1);

        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new PushAgentWallet(address(0), ok1, ok1, ok1, ok1);

        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new PushAgentWallet(ok1, address(0), ok1, ok1, ok1);

        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new PushAgentWallet(ok1, ok1, address(0), ok1, ok1);

        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new PushAgentWallet(ok1, ok1, ok1, address(0), ok1);

        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new PushAgentWallet(ok1, ok1, ok1, ok1, address(0));
    }

    /// @dev T-08 — `initialize` with a zero guardian succeeds and leaves the guardian unset.
    ///      No guardian is a valid configuration: `onlyGuardian` compares against
    ///      `msg.sender`, which can never be address(0), so every guardian entrypoint is
    ///      inert until the owner sets one via `setGuardian`.
    function test_T08_initializeWithZeroGuardianSucceeds() public {
        PushAgentWallet fresh = _newImpl();
        fresh.initialize(ownerUEA, address(0));

        assertEq(fresh.owner(), ownerUEA);
        assertEq(fresh.guardian(), address(0), "guardian deliberately unset");
        assertFalse(fresh.sessionsPaused(), "sessions start unpaused");

        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(ownerUEA);
        fresh.guardianPause();
    }

    // ── U-03 / U-04 / U-05 — account config ───────────────────────────

    function test_U03_accountId() public view {
        assertEq(wallet.accountId(), "push.agentwallet.1.0.0");
    }

    function test_U04_supportsModule() public view {
        assertTrue(wallet.supportsModule(1), "validator");
        assertTrue(wallet.supportsModule(4), "hook");
        assertFalse(wallet.supportsModule(2), "executor must be unsupported");
        assertFalse(wallet.supportsModule(3), "fallback must be unsupported");
        assertFalse(wallet.supportsModule(7));
        assertFalse(wallet.supportsModule(0));
        assertFalse(wallet.supportsModule(type(uint256).max));
    }

    function test_U05_supportsExecutionMode() public view {
        assertTrue(wallet.supportsExecutionMode(ModeLib.encodeSimpleSingle()));
        assertTrue(wallet.supportsExecutionMode(ModeLib.encodeSimpleBatch()));

        assertFalse(
            wallet.supportsExecutionMode(
                ModeLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0))
            )
        );
        assertFalse(
            wallet.supportsExecutionMode(
                ModeLib.encode(CALLTYPE_STATIC, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0))
            )
        );
        assertFalse(
            wallet.supportsExecutionMode(
                ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0))
            )
        );
        assertFalse(
            wallet.supportsExecutionMode(
                ModeLib.encode(CALLTYPE_BATCH, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0))
            )
        );
    }

    // ── U-06 … U-11 — module config ───────────────────────────────────

    function test_U06_installModuleByOwner() public {
        vm.expectEmit(false, false, false, true);
        emit ModuleInstalled(1, address(validator));
        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), hex"c0ffee");

        assertTrue(wallet.isModuleInstalled(1, address(validator), ""));
        assertTrue(validator.installed());
        assertEq(validator.lastInitData(), hex"c0ffee");
        assertEq(validator.installCount(), 1);
    }

    /// A-11 — reentrancy through onInstall is blocked by nonReentrant.
    function test_U06_A11_reentrancyThroughOnInstallBlocked() public {
        ReenteringValidator rv = new ReenteringValidator();
        rv.setWallet(address(wallet));

        vm.prank(ownerUEA);
        wallet.installModule(1, address(rv), "");

        assertTrue(rv.attempted(), "onInstall must have run");
        assertFalse(rv.reentrySucceeded(), "reentrant installModule must fail");
    }

    function test_U07_installModuleByNonOwnerReverts() public {
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(stranger);
        wallet.installModule(1, address(validator), "");
    }

    function test_U08_installUnsupportedTypeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnsupportedModuleType.selector, uint256(2)));
        vm.prank(ownerUEA);
        wallet.installModule(2, address(validator), "");

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnsupportedModuleType.selector, uint256(3)));
        vm.prank(ownerUEA);
        wallet.installModule(3, address(validator), "");
    }

    function test_U08b_installZeroAddressReverts() public {
        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        vm.prank(ownerUEA);
        wallet.installModule(1, address(0), "");
    }

    function test_U09_doubleInstallReverts() public {
        vm.startPrank(ownerUEA);
        wallet.installModule(1, address(validator), "");
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.ModuleAlreadyInstalled.selector, uint256(1), address(validator))
        );
        wallet.installModule(1, address(validator), "");
        vm.stopPrank();
    }

    function test_U10_uninstallModule() public {
        vm.startPrank(ownerUEA);
        wallet.installModule(1, address(validator), "");

        vm.expectEmit(false, false, false, true);
        emit ModuleUninstalled(1, address(validator));
        wallet.uninstallModule(1, address(validator), hex"dead");
        vm.stopPrank();

        assertFalse(wallet.isModuleInstalled(1, address(validator), ""));
        assertFalse(validator.installed());
        assertEq(validator.uninstallCount(), 1);
    }

    function test_U11_uninstallNotInstalledReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.ModuleNotInstalled.selector, uint256(1), address(validator))
        );
        vm.prank(ownerUEA);
        wallet.uninstallModule(1, address(validator), "");
    }

    function test_hookInstallAndUninstallManagesHookSlot() public {
        MockHook hook = new MockHook();
        vm.startPrank(ownerUEA);
        wallet.installModule(4, address(hook), "");
        assertTrue(wallet.isModuleInstalled(4, address(hook), ""));

        // hook fires on execute
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (7)))
        );
        assertEq(hook.preCount(), 1);
        assertEq(hook.postCount(), 1);
        assertEq(hook.lastMsgSender(), ownerUEA);

        wallet.uninstallModule(4, address(hook), "");
        vm.stopPrank();
        assertFalse(wallet.isModuleInstalled(4, address(hook), ""));

        // no longer fires
        vm.prank(ownerUEA);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (8)))
        );
        assertEq(hook.preCount(), 1, "hook must not fire after uninstall");
    }

    // ── U-12 … U-17 — execution ───────────────────────────────────────

    function test_U12_executeSingleByOwner() public {
        vm.prank(ownerUEA);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (42)))
        );
        assertEq(target.value(), 42);
        assertEq(target.callCount(), 1);
    }

    function test_U12b_executeSingleForwardsValue() public {
        vm.deal(address(wallet), 5 ether);
        vm.prank(ownerUEA);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 1 ether, abi.encodeCall(MockTarget.setValue, (1)))
        );
        assertEq(target.receivedValue(), 1 ether);
        assertEq(address(target).balance, 1 ether);
    }

    function test_U13_executeBatchInOrder() public {
        Execution[] memory execs = new Execution[](3);
        execs[0] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));
        execs[1] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (2)));
        execs[2] = Execution(address(target), 0, abi.encodeCall(MockTarget.setValue, (3)));

        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(execs));

        assertEq(target.callCount(), 3);
        assertEq(target.orderLength(), 3);
        assertEq(target.order(0), 1);
        assertEq(target.order(1), 2);
        assertEq(target.order(2), 3);
        assertEq(target.value(), 3);
    }

    function test_U14_executeByStrangerReverts() public {
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(stranger);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)))
        );
    }

    /// U-15 / A-15 — delegatecall mode is rejected explicitly.
    function test_U15_A15_delegatecallModeReverts() public {
        ModeCode mode = ModeLib.encode(CALLTYPE_DELEGATECALL, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0));
        vm.expectRevert(PushWalletErrors.DelegatecallNotSupported.selector);
        vm.prank(ownerUEA);
        wallet.execute(mode, ExecutionLib.encodeSingle(address(target), 0, ""));
    }

    function test_U16_execTypeTryReverts() public {
        ModeCode mode = ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_TRY, MODE_DEFAULT, ModePayload.wrap(0));
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnsupportedExecType.selector, EXECTYPE_TRY));
        vm.prank(ownerUEA);
        wallet.execute(mode, ExecutionLib.encodeSingle(address(target), 0, ""));
    }

    function test_U16b_unsupportedCallTypeReverts() public {
        ModeCode mode = ModeLib.encode(CALLTYPE_STATIC, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0));
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnsupportedCallType.selector, CALLTYPE_STATIC));
        vm.prank(ownerUEA);
        wallet.execute(mode, ExecutionLib.encodeSingle(address(target), 0, ""));
    }

    function test_U17_innerRevertBubblesOriginalData() public {
        vm.expectRevert(abi.encodeWithSelector(MockTarget.TargetReverted.selector, "boom"));
        vm.prank(ownerUEA);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.boom, ()))
        );
    }

    // ── U-18 — sweepPC ────────────────────────────────────────────────

    function test_U18_sweepPCByOwner() public {
        vm.deal(address(wallet), 3 ether);
        address payable dest = payable(address(0xD35));

        vm.expectEmit(true, false, false, true);
        emit PCSwept(dest, 2 ether);
        vm.prank(ownerUEA);
        wallet.sweepPC(dest, 2 ether);

        assertEq(dest.balance, 2 ether);
        assertEq(address(wallet).balance, 1 ether);
    }

    function test_U18b_sweepPCByNonOwnerReverts() public {
        vm.deal(address(wallet), 1 ether);
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(stranger);
        wallet.sweepPC(payable(stranger), 1 ether);
    }

    function test_U18c_sweepPCZeroAddressReverts() public {
        vm.deal(address(wallet), 1 ether);
        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        vm.prank(ownerUEA);
        wallet.sweepPC(payable(address(0)), 1 ether);
    }

    function test_U18d_sweepPCFailedTransferReverts() public {
        vm.deal(address(wallet), 1 ether);
        RejectsPC r = new RejectsPC();
        vm.expectRevert(PushWalletErrors.NativeTransferFailed.selector);
        vm.prank(ownerUEA);
        wallet.sweepPC(payable(address(r)), 1 ether);
    }

    // ── U-19 / A-10 — emergencyRevokeAll ──────────────────────────────

    function test_U19_A10_emergencyRevokeAllBypassesRevertingOnUninstall() public {
        StubbornValidator sv = new StubbornValidator();
        vm.prank(ownerUEA);
        wallet.installModule(1, address(sv), "");
        assertTrue(wallet.isModuleInstalled(1, address(sv), ""));

        // Normal uninstall is blocked by the module itself.
        vm.expectRevert(bytes("cannot uninstall"));
        vm.prank(ownerUEA);
        wallet.uninstallModule(1, address(sv), "");
        assertTrue(wallet.isModuleInstalled(1, address(sv), ""), "still installed");

        // The escape hatch works.
        address[] memory vs = new address[](1);
        vs[0] = address(sv);
        vm.expectEmit(true, false, false, true);
        emit EmergencyRevokeAll(ownerUEA);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);

        assertFalse(wallet.isModuleInstalled(1, address(sv), ""), "revoked");
    }

    function test_U19b_emergencyRevokeAllClearsHook() public {
        MockHook hook = new MockHook();
        vm.startPrank(ownerUEA);
        wallet.installModule(4, address(hook), "");
        address[] memory vs = new address[](0);
        wallet.emergencyRevokeAll(vs);

        // hook no longer fires
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)))
        );
        vm.stopPrank();
        assertEq(hook.preCount(), 0, "hook slot must be cleared");
    }

    function test_U19c_emergencyRevokeAllByNonOwnerReverts() public {
        address[] memory vs = new address[](1);
        vs[0] = address(validator);
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(stranger);
        wallet.emergencyRevokeAll(vs);
    }

    // ── U-24 … U-26 — Q8: single-active-hook discipline ───────────────

    /// U-24 — emergencyRevokeAll clears the hook MAPPING, not just the slot, so the
    /// hook can be reinstalled afterwards.
    function test_U24_Q8_emergencyRevokeAllClearsHookMapping() public {
        MockHook hook = new MockHook();
        vm.startPrank(ownerUEA);
        wallet.installModule(4, address(hook), "");
        assertTrue(wallet.isModuleInstalled(4, address(hook), ""));

        address[] memory none = new address[](0);
        wallet.emergencyRevokeAll(none);

        assertFalse(wallet.isModuleInstalled(4, address(hook), ""), "mapping must be cleared, not just _hook");

        // The previously-orphaning bug made this revert forever.
        wallet.installModule(4, address(hook), "");
        vm.stopPrank();
        assertTrue(wallet.isModuleInstalled(4, address(hook), ""), "hook must be reinstallable");
    }

    /// U-25 — installing a second hook while one is active is rejected. Silently
    /// overwriting _hook would orphan the first hook's mapping entry forever.
    function test_U25_Q8_secondHookRejected() public {
        MockHook a = new MockHook();
        MockHook b = new MockHook();

        vm.startPrank(ownerUEA);
        wallet.installModule(4, address(a), "");

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.HookAlreadyInstalled.selector, address(a)));
        wallet.installModule(4, address(b), "");
        vm.stopPrank();

        assertTrue(wallet.isModuleInstalled(4, address(a), ""));
        assertFalse(wallet.isModuleInstalled(4, address(b), ""));
    }

    /// U-26 — explicit uninstall then install leaves no orphan.
    function test_U26_Q8_uninstallThenInstallSecondHook() public {
        MockHook a = new MockHook();
        MockHook b = new MockHook();

        vm.startPrank(ownerUEA);
        wallet.installModule(4, address(a), "");
        wallet.uninstallModule(4, address(a), "");
        wallet.installModule(4, address(b), "");
        vm.stopPrank();

        assertFalse(wallet.isModuleInstalled(4, address(a), ""), "A must not be orphaned");
        assertTrue(wallet.isModuleInstalled(4, address(b), ""));

        // B is the active hook.
        vm.prank(ownerUEA);
        wallet.execute(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)))
        );
        assertEq(b.preCount(), 1, "B is active");
        assertEq(a.preCount(), 0, "A is not");
    }

    // ── U-20 / A-14 — callValidator ───────────────────────────────────

    function test_U20_A14_callValidatorUninstalledReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidatorNotInstalled.selector, address(target)));
        vm.prank(ownerUEA);
        wallet.callValidator(address(target), abi.encodeCall(MockTarget.setValue, (1)));
    }

    function test_U20b_callValidatorByNonOwnerReverts() public {
        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(stranger);
        wallet.callValidator(address(validator), abi.encodeCall(MockValidator.setValidationData, (0)));
    }

    function test_U20c_callValidatorForwardsAndReturns() public {
        vm.startPrank(ownerUEA);
        wallet.installModule(1, address(validator), "");
        wallet.callValidator(address(validator), abi.encodeCall(MockValidator.setValidationData, (123)));
        vm.stopPrank();
        assertEq(validator.validationData(), 123);
    }

    function test_U20d_callValidatorBubblesRevert() public {
        StubbornValidator sv = new StubbornValidator();
        vm.startPrank(ownerUEA);
        wallet.installModule(1, address(sv), "");
        vm.expectRevert(bytes("cannot uninstall"));
        wallet.callValidator(address(sv), abi.encodeWithSignature("onUninstall(bytes)", ""));
        vm.stopPrank();
    }

    // ── U-21 … U-23 — misc surface ────────────────────────────────────

    function test_U21_isValidSignatureAlwaysFails() public view {
        assertEq(wallet.isValidSignature(bytes32(0), ""), bytes4(0xFFFFFFFF));
        assertEq(wallet.isValidSignature(keccak256("x"), hex"1234"), bytes4(0xFFFFFFFF));
    }

    function test_U22_tokenReceiverSelectors() public view {
        assertEq(wallet.onERC721Received(address(0), address(0), 0, ""), IERC721Receiver.onERC721Received.selector);
        assertEq(
            wallet.onERC1155Received(address(0), address(0), 0, 0, ""), IERC1155Receiver.onERC1155Received.selector
        );
        uint256[] memory ids = new uint256[](0);
        assertEq(
            wallet.onERC1155BatchReceived(address(0), address(0), ids, ids, ""),
            IERC1155Receiver.onERC1155BatchReceived.selector
        );
    }

    function test_U22b_supportsInterface() public view {
        assertTrue(wallet.supportsInterface(type(IERC165).interfaceId));
        assertTrue(wallet.supportsInterface(type(IERC721Receiver).interfaceId));
        assertTrue(wallet.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertFalse(wallet.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_U23_receiveAcceptsNativePC() public {
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        (bool ok,) = address(wallet).call{ value: 2 ether }("");
        assertTrue(ok);
        assertEq(address(wallet).balance, 2 ether);
    }

    /**
     * D-3 — self-calls are rejected by AUTHORIZATION, not by the reentrancy guard.
     *
     * The `msg.sender == address(this)` branch was removed: a UEA multicall calls
     * each target directly, so Stage B config arrives with `msg.sender == UEA` and
     * never needs the wallet to call itself.
     *
     * ACPActionPolicy R7 is retained regardless. A-04 has three independent
     * defences — SmartSession's InvalidSelfCall, our R7, and this modifier — and
     * this test pins the third.
     */
    function test_D3_selfCallRejectedByAuthorization() public {
        Execution[] memory execs = new Execution[](1);
        execs[0] =
            Execution(address(wallet), 0, abi.encodeCall(PushAgentWallet.installModule, (1, address(validator), "")));

        // The inner self-call bubbles Unauthorized, not ReentrancyGuardReentrantCall.
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(execs));

        assertFalse(wallet.isModuleInstalled(1, address(validator), ""));
    }

    /// D-3 — the wallet calling itself directly is also rejected.
    function test_D3_directSelfCallRejected() public {
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(address(wallet));
        wallet.installModule(1, address(validator), "");
    }

    /**
     * D-3 — Stage B works as a UEA multicall: each entry arrives with
     * msg.sender == UEA, so config needs no self-call at all.
     */
    function test_D3_stageBConfigViaOwnerCallsSucceeds() public {
        vm.startPrank(ownerUEA);
        wallet.installModule(1, address(validator), "");
        wallet.callValidator(address(validator), abi.encodeCall(MockValidator.setValidationData, (0)));
        vm.stopPrank();

        assertTrue(wallet.isModuleInstalled(1, address(validator), ""));
    }

    /// Owner may still configure directly (the path Stage B must use today).
    function test_ownerDirectConfigWorks() public {
        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");
        assertTrue(wallet.isModuleInstalled(1, address(validator), ""));
    }

    /// @dev v2 constructor takes five module addresses. This suite tests the wallet's own
    ///      surface, not the session path, so placeholders suffice.
    function _newImpl() internal returns (PushAgentWallet) {
        return new PushAgentWallet(address(0x5511), address(0x6A7E), address(0xAC90), address(0x71FE), address(0x0A11));
    }
}
