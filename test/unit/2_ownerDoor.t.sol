// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";

import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

import { AllowedCall, Config, OWNER_LANE_FLAG, OwnerIntent, RulesType } from "../../src/libraries/Types.sol";

import { AGW } from "../../src/AGW.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";

import { AGWErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import {
    ModeLib,
    ModeCode,
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

import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";

import { Session, PermissionId } from "smartsessions/DataTypes.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @notice AGW — Phase 3a: skeleton, owner door, initialisation, views.
 *
 * @dev    grantRules / revokeRules / revokeAllRules / executeAsAgent are placeholders in this
 *         sub-phase; their tests arrive in 3b and 3c. Where a test here needs mandate STATE it
 *         builds it directly through the engine (`vm.prank(wallet) -> engine.enableSessions`),
 *         which is exactly what grantRules will do minus the salt and shape check.
 */
contract PushAgentWalletTest is BaseTest {
    AGW internal wallet;
    address internal WALLET_OWNER;

    /// @dev The mandate asset. A real PRC20 mock, not an EOA: URP interrogates the asset at
    ///      universal init and an address with no code is refused `InvalidAsset` by design.
    address internal PRC20;

    function setUp() public override {
        super.setUp();
        PRC20 = address(new MockPRC20());
        WALLET_OWNER = makeAddr("walletOwner");
        wallet = newWallet(WALLET_OWNER);
        vm.deal(address(wallet), 100 ether);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _batchMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleBatch());
    }

    /// @dev Build an arbitrary (callType, execType) mode. Packed by hand rather than through
    ///      ModeLib.encode so the test can express types ModeLib has no constant for — which is
    ///      what the rejection cases need.
    ///      Layout: | CALLTYPE 1B | EXECTYPE 1B | UNUSED 4B | ModeSelector 4B | ModePayload 22B |
    function _mode(bytes1 callType, bytes1 execType) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(callType, execType, bytes4(0), bytes4(0), bytes22(0)));
    }

    function _singleCalldata(address target, uint256 value, bytes memory data) internal pure returns (bytes memory) {
        return ExecutionLib.encodeSingle(target, value, data);
    }

    /// @dev A gateway-shaped call — the owner composing an outbound request freely (no URP pin).
    function _gatewayShapedCalldata() internal view returns (bytes memory) {
        return _singleCalldata(GATEWAY, 0, abi.encodeWithSelector(SEND_OUTBOUND_SELECTOR, ""));
    }

    /// @dev Grant a mandate THROUGH THE WALLET — the real path. (In 3a this went directly to the
    ///      engine because grantRules was a placeholder; 3b switched it, per the instruction.)
    function _grant(AGW w, address agentKey) internal returns (bytes32 pid) {
        vm.prank(WALLET_OWNER);
        return w.grantRules(canonicalSession(agentConfig(agentKey), _urpInitData()));
    }

    function _grant(AGW w) internal returns (bytes32) {
        return _grant(w, AGENT);
    }

    /// @dev A minimal valid URP config, so enableSessions' policy init succeeds.
    function _urpInitData() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: _addr("farProtocol"),
            selector: bytes4(keccak256("swap(uint256,address)")),
            beneficiaryOffset: 36,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 365 days),
                destChainHash: keccak256("eip155:11155111"),
                expectedCEA: _addr("cea"),
                asset: PRC20,
                maxAmountPerCall: 100 ether,
                maxAmountTotal: 1000 ether,
                maxPCPerCall: 5 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    /// @dev A deterministic address without touching cheatcode state, so `view` helpers stay view.
    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }

    // ═══════════════════════════════════ W-01 ═══════════════════════════════════

    /**
     * W-01 ⚠️ NEVER-WEAKEN — THE MOST IMPORTANT TEST IN THIS CONTRACT.
     *
     * `execute` reads EXACTLY TWO THINGS: the immutable-args owner, and calldata. No module, no
     * policy, no engine state, no flag may ever be consulted on that path. This matrix is what
     * guards that: the owner door must succeed in EVERY degraded wallet state.
     *
     * If someone later adds a "helpful" safety check — a module-health probe, an engine liveness
     * read, a pause flag — at least one cell here goes red. That is the entire point. Do not
     * weaken a cell to make a change pass; the change is the bug.
     *
     * MATRIX: {zero mandates, ghost-mandate state, engine uninstalled, hostile validator installed,
     * engine returning garbage} x {transfer, gateway-shaped call} x {single, batch}.
     */
    function test_OwnerPath_SurvivesDegradedMatrix() public {
        // ── cell group 1: zero mandates (the freshly initialised wallet) ──
        _assertOwnerDoorFullyLive("zero mandates");

        // ── cell group 2: ghost-mandate state — a live permission exists on the engine ──
        // Granted through the REAL path (wallet.grantRules), switched from the direct
        // engine.enableSessions used while grantRules was a 3a placeholder.
        _grant(wallet);
        _assertOwnerDoorFullyLive("ghost-mandate state");

        // ── cell group 3: engine UNINSTALLED (after clearing permissions so the wedge guard passes) ──
        AGW w3 = newWallet(WALLET_OWNER);
        vm.deal(address(w3), 100 ether);
        vm.prank(WALLET_OWNER);
        w3.uninstallModule(1, address(engine), "");
        assertFalse(w3.isModuleInstalled(1, address(engine), ""), "engine really is uninstalled");
        _assertOwnerDoorFullyLiveOn(w3, "engine uninstalled");

        // ── cell group 4: a HOSTILE validator installed ──
        AGW w4 = newWallet(WALLET_OWNER);
        vm.deal(address(w4), 100 ether);
        HostileValidator hostile = new HostileValidator();
        vm.prank(WALLET_OWNER);
        w4.installModule(1, address(hostile), "");
        assertTrue(w4.isModuleInstalled(1, address(hostile), ""), "hostile validator really is installed");
        _assertOwnerDoorFullyLiveOn(w4, "hostile validator installed");

        // ── cell group 5: the engine returns GARBAGE from every call ──
        AGW w5 = newWallet(WALLET_OWNER);
        vm.deal(address(w5), 100 ether);
        vm.etch(address(engine), type(GarbageEngine).runtimeCode);
        _assertOwnerDoorFullyLiveOn(w5, "engine returning garbage");
    }

    function _assertOwnerDoorFullyLive(string memory cell) internal {
        _assertOwnerDoorFullyLiveOn(wallet, cell);
    }

    /// @dev Both payload shapes x both call types = four cells per degraded state.
    function _assertOwnerDoorFullyLiveOn(AGW w, string memory cell) internal {
        address sink = makeAddr(string.concat("sink:", cell));
        uint256 before = sink.balance;
        uint64 cp0 = w.checkpointCount();

        // (a) SINGLE — a plain transfer (this is what "withdrawal" is; there is no withdraw()).
        vm.prank(WALLET_OWNER);
        w.execute(_singleMode(), _singleCalldata(sink, 1 ether, ""));
        assertEq(sink.balance, before + 1 ether, string.concat(cell, ": single transfer"));

        // (b) SINGLE — a gateway-shaped call. The owner composes outbound requests freely; no URP
        //     pin applies on this door.
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));
        vm.prank(WALLET_OWNER);
        w.execute(_singleMode(), _gatewayShapedCalldata());
        assertEq(callsRecorded(GATEWAY), 1, string.concat(cell, ": single gateway-shaped call"));
        vm.etch(GATEWAY, "");

        // (c) BATCH — transfer + gateway-shaped call in one owner signature. This is the shape the
        //     canonical permission-change flow needs (W-10).
        //     NOTE: vm.etch replaces code but NOT storage, so the recorder's slot-0 counter
        //     survives the re-etch above. Zero it explicitly, or this leg reads leg (b)'s count.
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: sink, value: 1 ether, callData: "" });
        execs[1] =
            Execution({ target: GATEWAY, value: 0, callData: abi.encodeWithSelector(SEND_OUTBOUND_SELECTOR, "") });

        vm.prank(WALLET_OWNER);
        w.execute(_batchMode(), ExecutionLib.encodeBatch(execs));

        assertEq(sink.balance, before + 2 ether, string.concat(cell, ": batch transfer leg"));
        assertEq(callsRecorded(GATEWAY), 1, string.concat(cell, ": batch gateway leg"));
        vm.etch(GATEWAY, "");

        assertEq(w.checkpointCount(), cp0 + 4, string.concat(cell, ": every owner call ticked"));
    }

    /// A non-owner is refused in every one of those states — the door is open to exactly one address.
    function test_OwnerPath_RejectsNonOwner() public {
        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.execute(_singleMode(), _singleCalldata(AGENT, 1 ether, ""));

        vm.prank(FACTORY);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.execute(_singleMode(), _singleCalldata(AGENT, 1 ether, ""));
    }

    /// The owner door bubbles an inner revert verbatim rather than swallowing it.
    function test_OwnerPath_BubblesInnerRevert() public {
        Reverter r = new Reverter();
        vm.prank(WALLET_OWNER);
        vm.expectRevert(Reverter.Nope.selector);
        wallet.execute(_singleMode(), _singleCalldata(address(r), 0, abi.encodeCall(Reverter.boom, ())));
    }

    // ═══════════════════════════ execution-mode gates ═══════════════════════════

    /**
     * ExecutionLib.decodeBatch's THREE MALFORMED-CALLDATA GUARDS, each through the owner door.
     *
     * WHY THESE EXIST AT ALL — this is the D-4 divergence from the reference implementation, and it
     * was added because upstream's version is a bug: given SINGLE-encoded calldata in BATCH mode it
     * reads a length of zero and returns an EMPTY batch, so `execute` SUCCEEDS having performed no
     * call — a silent no-op that still consumes a nonce and emits an event. The guards turn that
     * into a revert.
     *
     * WHY THE OWNER DOOR — the agent door refuses batch mode at step 9 before decoding, so these
     * lines are unreachable from there. `execute` is the only path that decodes a batch.
     *
     * A guard whose absence WAS a bug, with no test, is a guard a future refactor deletes silently.
     * Each case names `MalformedBatchCalldata` rather than accepting any revert.
     */
    function test_DecodeBatch_MalformedCalldata_AllThreeGuards() public {
        bytes32 batchMode = _batchMode();

        // (1) ExecutionLib.sol:51 — shorter than the single offset word.
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedBatchCalldata.selector);
        wallet.execute(batchMode, new bytes(31));

        // (2) ExecutionLib.sol:60 — the offset word points past the end of the blob.
        bytes memory offsetPastEnd = abi.encodePacked(uint256(1_000_000), uint256(0));
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedBatchCalldata.selector);
        wallet.execute(batchMode, offsetPastEnd);

        // (2b) the same guard's SECOND arm: the offset lands inside the blob, but leaves fewer than
        //      32 bytes after it — so there is no room for the length word that must follow.
        //      The blob is 96 bytes, so the offset must exceed 64 for fewer than 32 to remain.
        //      Measured: offset 64 leaves EXACTLY 32 and legitimately decodes to an empty batch,
        //      and offset 48 leaves 48 — both are VALID. 80 is the first that is not.
        bytes memory noRoomForLength = abi.encodePacked(uint256(80), uint256(0), uint256(0));
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedBatchCalldata.selector);
        wallet.execute(batchMode, noRoomForLength);

        // (3) ExecutionLib.sol:70 — a length larger than the remaining bytes could hold.
        //     offset 32, length 1000, but only one word follows: 1000 head slots cannot fit.
        bytes memory impossibleLength = abi.encodePacked(uint256(32), uint256(1000), uint256(0));
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedBatchCalldata.selector);
        wallet.execute(batchMode, impossibleLength);
    }

    /**
     * THE EXACT INPUT THE DIVERGENCE WAS WRITTEN FOR: SINGLE-encoded calldata submitted in BATCH
     * mode. Upstream decodes it as an empty batch and `execute` SUCCEEDS having called nothing.
     *
     * It must REVERT, and the recorder proves the silent-no-op reading is not what happens: the
     * target is never called, and the transaction does not succeed.
     */
    function test_DecodeBatch_SingleEncodedInBatchMode_RevertsNotSilentNoop() public {
        address sink = makeAddr("batchModeSink");
        etchCallRecorder(sink);
        vm.store(sink, bytes32(uint256(0)), bytes32(0));

        // Perfectly valid SINGLE calldata — target, value, empty payload.
        bytes memory singleEncoded = _singleCalldata(sink, 1 ether, "");

        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedBatchCalldata.selector);
        wallet.execute(_batchMode(), singleEncoded);

        assertEq(callsRecorded(sink), 0, "nothing was called");
        assertEq(sink.balance, 0, "and no value moved - it reverted rather than silently no-opping");

        // CONTROL: the same bytes in SINGLE mode do exactly what they say.
        vm.prank(WALLET_OWNER);
        wallet.execute(_singleMode(), singleEncoded);
        assertEq(sink.balance, 1 ether, "the same calldata is valid in SINGLE mode");
    }

    function test_OwnerDoor_RejectsNonDefaultExecAndExoticCallTypes() public {
        bytes memory ecd = _singleCalldata(AGENT, 0, "");

        // try-exec type
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        wallet.execute(_mode(0x00, 0x01), ecd);

        // delegatecall — the wallet half of the non-upgradeable ruling (W-25)
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        wallet.execute(_mode(0xFF, 0x00), ecd);

        // static
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        wallet.execute(_mode(0xFE, 0x00), ecd);

        // an unassigned call type
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        wallet.execute(_mode(0x42, 0x00), ecd);
    }

    function test_supportsExecutionMode() public view {
        assertTrue(wallet.supportsExecutionMode(_singleMode()), "single/default");
        assertTrue(wallet.supportsExecutionMode(_batchMode()), "batch/default");
        assertFalse(wallet.supportsExecutionMode(_mode(0x00, 0x01)), "try exec type");
        assertFalse(wallet.supportsExecutionMode(_mode(0xFF, 0x00)), "delegatecall");
        assertFalse(wallet.supportsExecutionMode(_mode(0xFE, 0x00)), "static");
    }

    // ═══════════════════════════════════ W-11 ═══════════════════════════════════

    /// Unqualified: types 2/3/4 are refused BY THE WALLET. A hook would run on the owner path and
    /// could block it — which is why no hook type exists in v3 at all.
    function test_W11_ModuleTypes_2_3_4_Rejected() public {
        DummyModule m = new DummyModule();

        for (uint256 t = 2; t <= 4; ++t) {
            assertFalse(wallet.supportsModule(t), "supportsModule must be false");

            vm.prank(WALLET_OWNER);
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnsupportedModuleType.selector, t));
            wallet.installModule(t, address(m), "");

            vm.prank(WALLET_OWNER);
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnsupportedModuleType.selector, t));
            wallet.uninstallModule(t, address(m), "");
        }

        assertTrue(wallet.supportsModule(1), "only type 1 is supported");
        assertFalse(wallet.supportsModule(0), "type 0");
        assertFalse(wallet.supportsModule(5), "type 5");
    }

    function test_InstallModule_Guards() public {
        DummyModule m = new DummyModule();

        // zero address
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        wallet.installModule(1, address(0), "");

        // codeless target
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        wallet.installModule(1, makeAddr("noCode"), "");

        // double install reverts loudly
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(m), "");
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ModuleAlreadyInstalled.selector, address(m)));
        wallet.installModule(1, address(m), "");

        // non-owner
        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.installModule(1, address(m), "");
    }

    function test_UninstallModule_RequiresInstalled() public {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ValidatorNotInstalled.selector, AGENT));
        wallet.uninstallModule(1, AGENT, "");
    }

    // ═══════════════════════════════════ W-12 ═══════════════════════════════════

    /// A reverting callback AND a gas-burning callback are both still removed. The account unmarks
    /// FIRST, so a hostile module cannot block its own removal.
    function test_W12_Uninstall_StipendSemantics() public {
        // (a) a callback that reverts
        RevertingUninstall rev = new RevertingUninstall();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(rev), "");

        vm.expectEmit(true, true, true, true, address(wallet));
        emit IAGW.UninstallCallbackFailed(address(rev));
        vm.prank(WALLET_OWNER);
        wallet.uninstallModule(1, address(rev), "");
        assertFalse(wallet.isModuleInstalled(1, address(rev), ""), "reverting callback still removed");

        // (b) a callback that burns everything it is given
        GasBurnerUninstall burner = new GasBurnerUninstall();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(burner), "");

        vm.expectEmit(true, true, true, true, address(wallet));
        emit IAGW.UninstallCallbackFailed(address(burner));
        vm.prank(WALLET_OWNER);
        wallet.uninstallModule(1, address(burner), "");
        assertFalse(wallet.isModuleInstalled(1, address(burner), ""), "gas-burning callback still removed");
    }

    /// The stipend is a named constant and it really is capped: the burner consumes the stipend,
    /// not the whole transaction. Asserted with a number so the test can fail.
    function test_W12_StipendIsCapped() public {
        GasBurnerUninstall burner = new GasBurnerUninstall();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(burner), "");

        vm.prank(WALLET_OWNER);
        uint256 before = gasleft();
        wallet.uninstallModule(1, address(burner), "");
        uint256 used = before - gasleft();

        emit log_named_uint("uninstall gas with a burning callback", used);
        // The 100k stipend plus the wallet's own work. Well under a full-transaction burn.
        assertLt(used, 200_000, "the callback is capped by UNINSTALL_CALLBACK_GAS_STIPEND");
    }

    // ═══════════════════════════════════ W-13 ═══════════════════════════════════

    /// The wedge guard: the engine cannot be uninstalled while it holds live permissions, because
    /// its unbounded cleanup loop would die midway under the stipend and leave dangling rows the
    /// engine then refuses to reinstall over. AND a third-party validator with live "state" is NOT
    /// protected — it removes unconditionally.
    function test_W13_EngineUninstall_WedgeGuard() public {
        // with a live permission, the engine is protected
        _grant(wallet);
        assertTrue(engine.isInitialized(address(wallet)), "engine reports live state");

        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.EngineStillHoldsPermissions.selector);
        wallet.uninstallModule(1, address(engine), "");
        assertTrue(wallet.isModuleInstalled(1, address(engine), ""), "still installed");

        // after removing the permission, it uninstalls cleanly
        PermissionId[] memory ids = engine.getPermissionIDs(address(wallet));
        for (uint256 i; i < ids.length; ++i) {
            vm.prank(address(wallet));
            engine.removeSession(ids[i]);
        }
        assertFalse(engine.isInitialized(address(wallet)), "engine reports no state");

        vm.prank(WALLET_OWNER);
        wallet.uninstallModule(1, address(engine), "");
        assertFalse(wallet.isModuleInstalled(1, address(engine), ""), "clean uninstall after revokeAllRules-equivalent");
    }

    /// THE OTHER HALF, and it is the security-relevant one: a hostile validator that claims live
    /// state removes anyway. The guard is scoped EXACTLY to DEFAULT_SESSION_ENGINE (§11 item 9) —
    /// generalising it would hand every hostile module a removal blocker.
    function test_W13_ThirdPartyValidator_NotProtected() public {
        AlwaysInitializedValidator hostile = new AlwaysInitializedValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(hostile), "");

        assertTrue(hostile.isInitialized(address(wallet)), "it claims live state");

        vm.prank(WALLET_OWNER);
        wallet.uninstallModule(1, address(hostile), "");
        assertFalse(wallet.isModuleInstalled(1, address(hostile), ""), "removed unconditionally");
    }

    // ═══════════════════════════════════ W-14 ═══════════════════════════════════

    /// The probe FAILS OPEN. An engine whose isInitialized reverts, burns gas, or returns garbage
    /// must still be removable — the guard exists to prevent an ordering mistake, never to make a
    /// broken engine irremovable.
    function test_W14_EngineGuard_FailsOpen() public {
        // (a) probe reverts
        _assertEngineRemovableWithProbe(type(RevertingProbeEngine).runtimeCode, "probe reverts");

        // (b) probe burns all the gas it is given
        _assertEngineRemovableWithProbe(type(GasBurnerProbeEngine).runtimeCode, "probe burns gas");

        // (c) probe returns garbage too short to decode
        _assertEngineRemovableWithProbe(type(ShortReturnProbeEngine).runtimeCode, "probe returns short data");

        // (d) probe returns no data at all
        _assertEngineRemovableWithProbe(type(EmptyReturnProbeEngine).runtimeCode, "probe returns nothing");

        // (e) probe returns a FULL-LENGTH word that is not a canonical bool. This is the case the
        // other four miss: they all fail the `ret.length >= 32` guard or the `ok` check, so the
        // decode never runs. Here the probe SUCCEEDS and returns 32 bytes, and decoding a
        // non-canonical bool is itself a revert — inside the guard expression, which blocked
        // removal instead of failing open.
        _assertEngineRemovableWithProbe(type(NonBoolProbeEngine).runtimeCode, "probe returns non-canonical bool");
    }

    /// @dev Snapshot the real engine's code, etch the broken probe, assert removal proceeds, then
    ///      restore — so each case runs against a genuinely installed engine.
    function _assertEngineRemovableWithProbe(bytes memory probeCode, string memory label) internal {
        AGW w = newWallet(WALLET_OWNER);
        bytes memory realEngineCode = address(engine).code;

        vm.etch(address(engine), probeCode);

        vm.prank(WALLET_OWNER);
        w.uninstallModule(1, address(engine), "");
        assertFalse(w.isModuleInstalled(1, address(engine), ""), label);

        vm.etch(address(engine), realEngineCode);
    }

    // ═══════════════════════════════════ W-20 ═══════════════════════════════════

    function test_W20_InitializeAccount_FactoryOnlyOnce() public {
        // a fresh, UNINITIALISED clone
        bytes memory args = abi.encodePacked(WALLET_OWNER, FACTORY);
        AGW fresh = AGW(
            payable(Clones.cloneDeterministicWithImmutableArgs(address(walletImpl), args, bytes32(uint256(999))))
        );

        // non-factory callers are refused
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.CallerIsNotFactory.selector);
        fresh.initializeAccount();

        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotFactory.selector);
        fresh.initializeAccount();

        // the factory succeeds, and both events fire
        vm.expectEmit(true, true, true, true, address(fresh));
        emit IAGW.ModuleInstalled(1, address(engine));
        vm.expectEmit(true, true, true, true, address(fresh));
        emit IAGW.AccountInitialized(WALLET_OWNER, address(engine));

        vm.prank(FACTORY);
        fresh.initializeAccount();

        assertTrue(fresh.isModuleInstalled(1, address(engine), ""), "engine installed as sole validator");

        // second call reverts
        vm.prank(FACTORY);
        vm.expectRevert(AGWErrors.AlreadyInitialized.selector);
        fresh.initializeAccount();
    }

    // ═══════════════════════════════════ W-21 ═══════════════════════════════════

    /// Always 0xffffffff. The wallet never signs as an ERC-1271 party in v3, and this is also what
    /// makes the engine's ENABLE-mode flow dead on v3 wallets (S-01).
    function test_W21_ERC1271_AlwaysInvalid() public view {
        assertEq(wallet.isValidSignature(bytes32(0), ""), bytes4(0xffffffff), "empty");
        assertEq(wallet.isValidSignature(keccak256("x"), hex"deadbeef"), bytes4(0xffffffff), "arbitrary");
        assertEq(
            wallet.isValidSignature(keccak256("y"), abi.encodePacked(uint256(1), uint256(2), uint8(27))),
            bytes4(0xffffffff),
            "well-formed-looking ECDSA signature"
        );
    }

    function testFuzz_W21_ERC1271_AlwaysInvalid(bytes32 hash, bytes memory sig) public view {
        assertEq(wallet.isValidSignature(hash, sig), bytes4(0xffffffff), "no input ever validates");
    }

    // ═══════════════════════════════════ W-22 ═══════════════════════════════════

    /// A freshly deployed wallet is a VALID wallet: the owner door is fully live, and the agent
    /// door refuses. (In 3c this asserts the failure happens before any policy runs; here the
    /// agent door is still a placeholder, so it asserts the door is closed.)
    function test_W22_EmptyWallet_RejectsAgents() public {
        AGW fresh = newWallet(WALLET_OWNER);
        vm.deal(address(fresh), 10 ether);

        assertEq(engine.getPermissionIDs(address(fresh)).length, 0, "no mandates");

        // the agent door is closed — no id names an agent on an empty wallet, so the wallet's own
        // agent check refuses before any policy runs
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, bytes32(0), AGENT));
        fresh.executeAsAgent(bytes32(0), _singleMode(), "");

        // the owner door is fully live
        address sink = makeAddr("freshSink");
        vm.prank(WALLET_OWNER);
        fresh.execute(_singleMode(), _singleCalldata(sink, 1 ether, ""));
        assertEq(sink.balance, 1 ether, "owner door works on an empty wallet");
    }

    // ═══════════════════════════════════ W-23 ═══════════════════════════════════

    /// The owner-door half. (The RulesActionAuthorized half arrives in 3c.)
    function test_W23_Events_Attribution_OwnerDoor() public {
        address sink = makeAddr("eventSink");
        bytes memory ecd = _singleCalldata(sink, 1 ether, "");

        vm.expectEmit(true, true, true, true, address(wallet));
        emit IAGW.OwnerExecuted(_singleMode(), keccak256(ecd));

        vm.prank(WALLET_OWNER);
        wallet.execute(_singleMode(), ecd);
    }

    /// The event is emitted AFTER successful dispatch — a failed call emits nothing.
    ///
    /// Counts `OwnerExecuted` only: forge also records the `Checkpointed` log emitted (before the call)
    /// inside the frame that then reverted, though the chain keeps nothing from that frame.
    function test_W23_NoEventOnFailedDispatch() public {
        Reverter r = new Reverter();
        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        try wallet.execute(_singleMode(), _singleCalldata(address(r), 0, abi.encodeCall(Reverter.boom, ()))) {
            fail();
        } catch { }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 ownerExecuted;
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].emitter == address(wallet) && logs[k].topics[0] == IAGW.OwnerExecuted.selector) {
                ++ownerExecuted;
            }
        }
        assertEq(ownerExecuted, 0, "no OwnerExecuted on a failed dispatch");
    }

    // ═══════════════════════════════════ W-25 ═══════════════════════════════════

    /**
     * W-25 — THE EXACT SELECTOR SET, not "contains no X".
     *
     * A denylist ("assert there is no upgradeTo") cannot fail against a MISNAMED entry — the same
     * defect class that made a `vm.expectCall(..., 0)` on an undeclared selector pass in Phase 2.
     * An exact set also catches an accidentally-`public` internal helper such as `_owner()`, which
     * no denylist would ever name.
     *
     * The expected list below is hard-coded on purpose. If a function is added or removed, this
     * test fails and a human decides whether the ABI change was intended.
     */
    function test_W25_Clone_NoUpgradeSurface_ExactSelectorSet() public view {
        bytes4[] memory expected = new bytes4[](31);
        uint256 i;

        // one-shot initialisation
        expected[i++] = AGW.initializeAccount.selector;
        // owner door + lifecycle
        expected[i++] = AGW.execute.selector;
        expected[i++] = AGW.grantRules.selector;
        // UniversalMarketplace PRD, Changes C and D: the owner-intent doors and their domain view.
        expected[i++] = AGW.grantRulesWithSig.selector;
        expected[i++] = AGW.executeWithSig.selector;
        expected[i++] = AGW.domainSeparator.selector;
        expected[i++] = AGW.revokeRules.selector;
        expected[i++] = AGW.revokeAllRules.selector;
        // agent door
        expected[i++] = AGW.executeAsAgent.selector;
        expected[i++] = AGW.agentOf.selector;
        // module manager
        expected[i++] = AGW.installModule.selector;
        expected[i++] = AGW.uninstallModule.selector;
        expected[i++] = AGW.isModuleInstalled.selector;
        expected[i++] = AGW.supportsModule.selector;
        expected[i++] = AGW.supportsExecutionMode.selector;
        // views
        expected[i++] = AGW.owner.selector;
        expected[i++] = AGW.factory.selector;
        expected[i++] = AGW.getNonce.selector;
        expected[i++] = AGW.grantNonce.selector;
        expected[i++] = AGW.checkpointCount.selector;
        expected[i++] = AGW.lastCheckpointBlock.selector;
        expected[i++] = AGW.accountId.selector;
        expected[i++] = IAGW.SESSION_ENGINE.selector;
        expected[i++] = IAGW.RULES_POLICY.selector;
        expected[i++] = IAGW.SESSION_VALIDATOR.selector;
        expected[i++] = IAGW.UNIVERSAL_GATEWAY_PC.selector;
        // reception plumbing
        expected[i++] = AGW.onERC721Received.selector;
        expected[i++] = AGW.onERC1155Received.selector;
        expected[i++] = AGW.onERC1155BatchReceived.selector;
        expected[i++] = AGW.supportsInterface.selector;
        expected[i++] = AGW.isValidSignature.selector;

        assertEq(i, 31, "the hard-coded list must be complete");
        assertSelectorSet("AGW", expected);
    }

    /**
     * The other half of W-25: `initializeAccount` on the IMPLEMENTATION reverts `CallerIsNotFactory()` from
     * EVERY caller — including the real factory placeholder.
     *
     * WHY `CallerIsNotFactory()` AND NOT `AlreadyInitialized()`, which looks like the "truer" reason: the
     * factory check runs first, and `_factory()` on the implementation reads a slice of its own
     * runtime bytecode rather than reverting (`Clones.fetchCloneArgs` is undefined on a non-clone,
     * OZ `Clones.sol:255-258`). Probe-confirmed value here:
     * `0x8063112d3a7D1461019A578063150B7A02146101` — nobody holds a key for it. §6.1 says to leave
     * the guard order and expect `CallerIsNotFactory()`.
     *
     * HONEST SCOPE: this test does NOT prove the constructor's `_initialized = true` line matters.
     * Verified by mutation — deleting that line leaves every test green, because the factory check
     * fires first and the latch behind it is unreachable on the implementation. The line stays
     * because §4 specifies it as an INDEPENDENT second block, and §4's own argument is that none of
     * the four inertness reasons is load-bearing alone. A test asserting otherwise would be
     * asserting something the code's structure makes unobservable.
     */
    function test_W25_ImplementationCannotBeInitialized() public {
        address[4] memory callers = [FACTORY, WALLET_OWNER, AGENT, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(AGWErrors.CallerIsNotFactory.selector);
            walletImpl.initializeAccount();
        }
    }

    /// The other three inertness reasons from §4, each asserted independently.
    function test_W25_ImplementationIsInertOnEveryDoor() public {
        // (1) the owner door: the only address passing onlyOwner is a bytecode slice.
        address implOwner = walletImpl.owner();
        assertTrue(implOwner != WALLET_OWNER && implOwner != FACTORY, "impl owner is a bytecode slice, not a key");

        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        walletImpl.execute(_singleMode(), _singleCalldata(AGENT, 0, ""));

        // (3) the agent door needs a session enabled for account = implementation, which only the
        //     unreachable owner door could grant.
        assertEq(engine.getPermissionIDs(address(walletImpl)).length, 0, "no sessions on the implementation");

        // (4) it holds no funds.
        assertEq(address(walletImpl).balance, 0, "the implementation holds nothing");
    }

    // ═══════════════════════════════════ W-27 ═══════════════════════════════════

    function test_W27_Immutables_SetAndReadableByClones() public {
        // (a) every zero constructor argument reverts
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        new AGW(address(0), address(urp), address(validator), GATEWAY);
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        new AGW(address(engine), address(0), address(validator), GATEWAY);
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        new AGW(address(engine), address(urp), address(0), GATEWAY);
        vm.expectRevert(AGWErrors.InvalidModuleAddress.selector);
        new AGW(address(engine), address(urp), address(validator), address(0));

        // (b) a deployed CLONE returns all four through its views — proving immutables resolve
        //     through delegatecall from the implementation's own bytecode
        assertEq(wallet.SESSION_ENGINE(), address(engine), "engine");
        assertEq(wallet.RULES_POLICY(), address(urp), "urp");
        assertEq(wallet.SESSION_VALIDATOR(), address(validator), "validator");
        assertEq(wallet.UNIVERSAL_GATEWAY_PC(), GATEWAY, "gateway");

        // (c) two implementations wired DIFFERENTLY produce clones that behave differently —
        //     the values are not shared state
        address altEngine = makeAddr("altEngine");
        address altUrp = makeAddr("altUrp");
        address altValidator = makeAddr("altValidator");
        address altGateway = makeAddr("altGateway");
        AGW altImpl = new AGW(altEngine, altUrp, altValidator, altGateway);

        AGW altClone = AGW(
            payable(Clones.cloneDeterministicWithImmutableArgs(
                    address(altImpl), abi.encodePacked(WALLET_OWNER, FACTORY), bytes32(uint256(1234))
                ))
        );

        assertEq(altClone.SESSION_ENGINE(), altEngine, "alt engine");
        assertEq(altClone.RULES_POLICY(), altUrp, "alt urp");
        assertEq(altClone.SESSION_VALIDATOR(), altValidator, "alt validator");
        assertEq(altClone.UNIVERSAL_GATEWAY_PC(), altGateway, "alt gateway");

        // and the original clone is unaffected
        assertEq(wallet.SESSION_ENGINE(), address(engine), "original clone unchanged");
    }

    /// Clone args round-trip: owner at 0-19, factory at 20-39.
    function test_CloneArgs_OwnerAndFactory() public view {
        assertEq(wallet.owner(), WALLET_OWNER, "owner from immutable args");
        assertEq(wallet.factory(), FACTORY, "factory from immutable args");
    }

    function testFuzz_CloneArgs_OwnerAndFactory(address o, address f) public {
        vm.assume(o != address(0) && f != address(0));
        AGW w = AGW(
            payable(Clones.cloneDeterministicWithImmutableArgs(
                    address(walletImpl), abi.encodePacked(o, f), keccak256(abi.encode(o, f))
                ))
        );
        assertEq(w.owner(), o, "any owner round-trips");
        assertEq(w.factory(), f, "any factory round-trips");
    }

    // ═════════════════════════════ storage layout ═════════════════════════════

    /**
     * THE WALLET'S WHOLE STATE IS SIX DECLARATIONS, in this order. Asserted against solc's own
     * storageLayout, not a slot read.
     *
     * `_initialized` (bool), `_grantNonce` (uint64), `_checkpointCount` (uint64) and
     * `_lastCheckpointBlock` (uint64) MUST share slot 0: the packing keeps every checkpoint a rewrite
     * of a non-zero slot, and a reordering that unpacked them would be a silent gas regression on
     * every owner call, grant and revoke.
     */
    function test_StorageLayout_ExactlySixDeclarations() public view {
        string memory artifact = vm.readFile("out/AGW.sol/AGW.json");

        string[] memory labels = new string[](6);
        labels[0] = "_initialized";
        labels[1] = "_grantNonce";
        labels[2] = "_checkpointCount";
        labels[3] = "_lastCheckpointBlock";
        labels[4] = "_installedValidators";
        labels[5] = "_nonces";
        string[6] memory slots = ["0", "0", "0", "0", "1", "2"];

        for (uint256 i; i < labels.length; ++i) {
            string memory base = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            assertEq(
                vm.parseJsonString(artifact, string.concat(base, ".label")),
                labels[i],
                string.concat("declaration ", vm.toString(i))
            );
            assertEq(
                vm.parseJsonString(artifact, string.concat(base, ".slot")), slots[i], string.concat(labels[i], " slot")
            );
        }

        // exactly six: index 6 must not exist
        assertFalse(
            vm.keyExistsJson(artifact, ".storageLayout.storage[6]"),
            "a seventh storage declaration appeared - the wallet's whole state is six"
        );

        // the packing of slot 0
        assertEq(vm.parseJsonUint(artifact, ".storageLayout.storage[0].offset"), 0, "_initialized offset");
        assertEq(vm.parseJsonUint(artifact, ".storageLayout.storage[1].offset"), 1, "_grantNonce offset");
        assertEq(vm.parseJsonUint(artifact, ".storageLayout.storage[2].offset"), 9, "_checkpointCount offset");
        assertEq(vm.parseJsonUint(artifact, ".storageLayout.storage[3].offset"), 17, "_lastCheckpointBlock offset");
    }

    // ═══════════════════════════════ views & plumbing ═══════════════════════════════

    function test_AccountId() public view {
        assertEq(wallet.accountId(), "push.agw.1.0.0", "ERC-7579 vendorname.accountname.semver");
    }

    /// ERC-165 + the two receiver interfaces, and NOTHING else. It must NOT report
    /// IERC7579Account — the wallet implements that interface only partially, so advertising it
    /// would be a false claim to exactly the tooling that probes for it (§11 item 15).
    function test_SupportsInterface_DoesNotClaimERC7579Account() public view {
        assertTrue(wallet.supportsInterface(0x01ffc9a7), "ERC-165");
        assertTrue(wallet.supportsInterface(0x150b7a02), "ERC721Receiver");
        assertTrue(wallet.supportsInterface(0x4e2312e0), "ERC1155Receiver");

        assertFalse(wallet.supportsInterface(0xffffffff), "the ERC-165 invalid id");

        // THE REAL interface id, computed from the upstream type — not a hash of the string
        // "IERC7579Account", which is a meaningless value the wallet would never return anyway
        // and which therefore cannot fail. (Value: 0xb429f8f5.)
        assertFalse(
            wallet.supportsInterface(type(IERC7579Account).interfaceId),
            "must NOT advertise IERC7579Account - the wallet implements it only partially"
        );

        // Nothing else is claimed either. Four spot values that a careless addition might return.
        assertFalse(wallet.supportsInterface(0xd03c7914), "supportsExecutionMode selector is not an interface id");
        assertFalse(wallet.supportsInterface(0x00000000), "zero");
        assertFalse(wallet.supportsInterface(0xdeadbeef), "arbitrary");
    }

    /// Only the three declared ids may ever return true. A fuzz so an added claim cannot hide.
    function testFuzz_SupportsInterface_ExactlyThree(bytes4 id) public view {
        bool expected = id == bytes4(0x01ffc9a7) || id == bytes4(0x150b7a02) || id == bytes4(0x4e2312e0);
        assertEq(wallet.supportsInterface(id), expected, "exactly three interface ids are claimed");
    }

    function test_TokenReceiverHooks() public view {
        assertEq(wallet.onERC721Received(address(0), address(0), 0, ""), bytes4(0x150b7a02), "721");
        assertEq(wallet.onERC1155Received(address(0), address(0), 0, 0, ""), bytes4(0xf23a6e61), "1155 single");
        assertEq(
            wallet.onERC1155BatchReceived(address(0), address(0), new uint256[](0), new uint256[](0), ""),
            bytes4(0xbc197c81),
            "1155 batch"
        );
    }

    function test_Receive_AcceptsPC() public {
        uint256 before = address(wallet).balance;
        vm.deal(AGENT, 5 ether);
        vm.prank(AGENT);
        (bool ok,) = address(wallet).call{ value: 5 ether }("");
        assertTrue(ok, "receive accepts PC from anyone - refunds land here");
        assertEq(address(wallet).balance, before + 5 ether, "balance moved");
    }

    function test_NonceViews_StartAtZero() public view {
        assertEq(wallet.getNonce(OWNER_LANE_FLAG), 0, "the first owner lane");
        assertEq(wallet.getNonce(type(uint192).max), 0, "an arbitrary owner lane");
        assertEq(wallet.grantNonce(), 0, "grant nonce starts at zero");
    }

    /// The agent door is live. A caller that is not the agent is refused by the wallet itself; the
    /// agent of a real grant gets through to the policy, which refuses a malformed request by gate.
    function test_AgentDoor_IsLive_AndRefusesMalformedRequests() public {
        bytes32 pid = _grant(wallet);
        bytes memory malformed = _gatewayShapedCalldata(); // selector + an empty `bytes`: 68 bytes

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid, RELAYER));
        wallet.executeAsAgent(pid, _singleMode(), malformed);

        vm.prank(AGENT);
        expectUrpGate(abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedOutboundRequest.selector, uint256(68)));
        wallet.executeAsAgent(pid, _singleMode(), malformed);
    }

    // ═══════════════════ execute() is untouched (UniversalMarketplace PRD, D5) ═══════════════════

    /**
     * ⚠️ NEVER-DELETE. The owner-door invariant: `execute` reads no module, policy or engine state; its
     * only side effect besides the calls is one checkpoint write per call to the wallet's own slot 0,
     * which cannot revert. Single and batch, every wallet storage read and write is slot 0, and the
     * engine is never touched. The reentrancy guard is transient (TLOAD/TSTORE, not recorded) and the
     * owner comes from the clone's code. `executeWithSig`, which also reads its nonce lane, is the
     * contrast that shows the recorder sees more than slot 0 when there is more.
     */
    function test_W_execute_touchesOnlyTheCheckpointSlot() public {
        address target = makeAddr("anyTarget");
        vm.deal(address(wallet), 1 ether);

        vm.record();
        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleSingle()), ExecutionLib.encodeSingle(target, 1, ""));
        _assertOnlySlotZero("execute (single)");

        Execution[] memory b = new Execution[](2);
        b[0] = Execution({ target: target, value: 1, callData: "" });
        b[1] = Execution({ target: target, value: 1, callData: "" });
        vm.record();
        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(b));
        _assertOnlySlotZero("execute (batch)");

        // Positive control: the recorder does see the new door's nonce lane.
        (address o, uint256 opk) = ecdsaKey("recorderControlOwner");
        AGW w = newWallet(o);
        bytes memory cd = ExecutionLib.encodeSingle(target, 0, "");
        OwnerIntent memory i = blankIntent(o, address(w), RELAYER);
        i.mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        i.execCalldataHash = keccak256(cd);
        bytes memory sig = signIntent(opk, i);
        vm.record();
        vm.prank(RELAYER);
        w.executeWithSig(i.mode, cd, i, sig);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(w));
        assertGt(reads.length, 0, "control: executeWithSig reads its nonce lane");
        assertGt(writes.length, 0, "control: executeWithSig writes its nonce lane");
    }

    /// @dev The wallet's recorded accesses are non-empty and all slot 0; the engine's are empty.
    function _assertOnlySlotZero(string memory what) internal view {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(wallet));
        assertGt(reads.length, 0, string.concat(what, " reads the checkpoint slot"));
        assertGt(writes.length, 0, string.concat(what, " writes the checkpoint slot"));
        for (uint256 k; k < reads.length; ++k) {
            assertEq(reads[k], bytes32(0), string.concat(what, " must read no wallet slot but slot 0"));
        }
        for (uint256 k; k < writes.length; ++k) {
            assertEq(writes[k], bytes32(0), string.concat(what, " must write no wallet slot but slot 0"));
        }
        (bytes32[] memory engineReads, bytes32[] memory engineWrites) = vm.accesses(address(engine));
        assertEq(engineReads.length, 0, string.concat(what, " must not read the engine"));
        assertEq(engineWrites.length, 0, string.concat(what, " must not write the engine"));
    }
}

// ─────────────────────────────── test doubles ───────────────────────────────
// All OBSERVERS or inert stand-ins. None supplies behaviour the wallet's logic depends on.

/**
 * @dev A validator that is hostile in every way it CAN be while still being installable.
 *
 *      `onInstall` must succeed — the wallet bubbles install reverts by design (§6.7 step 5), so a
 *      module that reverts there simply never gets installed and the "hostile validator installed"
 *      cell would test nothing. Everything reachable AFTER installation reverts, which is the
 *      state W-01 actually cares about: a hostile module sitting in the registry must not affect
 *      the owner door, because the owner door never consults the registry.
 */
contract HostileValidator {
    function onInstall(bytes calldata) external { }

    function onUninstall(bytes calldata) external pure {
        revert("hostile: refuses removal");
    }

    function isModuleType(uint256) external pure returns (bool) {
        revert("hostile");
    }

    function isInitialized(address) external pure returns (bool) {
        revert("hostile");
    }

    function validateUserOp(bytes calldata, bytes32) external pure returns (uint256) {
        revert("hostile");
    }

    fallback() external payable {
        revert("hostile");
    }

    receive() external payable {
        revert("hostile");
    }
}

/// @dev Returns garbage from every call, including the engine's own methods.
contract GarbageEngine {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"deadbeef";
    }
}

contract DummyModule {
    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256) external pure returns (bool) {
        return true;
    }
}

contract RevertingUninstall {
    function onInstall(bytes calldata) external { }

    function onUninstall(bytes calldata) external pure {
        revert("no");
    }
}

contract GasBurnerUninstall {
    uint256 private sink;

    function onInstall(bytes calldata) external { }

    function onUninstall(bytes calldata) external {
        // Burn everything given. The stipend must cap this.
        while (true) {
            sink++;
        }
    }
}

/// @dev A third-party validator that claims live state — it must still be removable.
contract AlwaysInitializedValidator {
    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}

contract RevertingProbeEngine {
    function isInitialized(address) external pure returns (bool) {
        revert("probe down");
    }

    fallback() external { }
}

contract GasBurnerProbeEngine {
    uint256 private sink;

    function isInitialized(address) external returns (bool) {
        while (true) {
            sink++;
        }
        return true;
    }

    fallback() external { }
}

contract ShortReturnProbeEngine {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"01";
    }
}

contract NonBoolProbeEngine {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(2));
    }
}

contract EmptyReturnProbeEngine {
    fallback() external { }
}

contract Reverter {
    error Nope();

    function boom() external pure {
        revert Nope();
    }
}
