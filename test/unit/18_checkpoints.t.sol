// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { AGW } from "../../src/AGW.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGWErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";
import {
    AllowedCall,
    AmountRule,
    ArgPin,
    CheckpointKind,
    Config,
    Multicall,
    NativeConfig,
    OWNER_LANE_FLAG,
    OwnerIntent,
    RulesType
} from "../../src/libraries/Types.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import { Session, PermissionId } from "smartsessions/DataTypes.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/**
 * @notice AGW — checkpoints: the owner-interference counter (B2).
 *
 * @dev    The counter moves once per owner-door call (before the call), once per grant and once per
 *         revoked id, and never when the agent acts. Everything here runs against the real engine,
 *         the real URP behind its proxy and wallets from the real factory. The only test doubles are
 *         observers: a probe that records the counter it sees, inert call targets, and a hostile
 *         validator that the owner door must ignore.
 *
 * @dev    No selector-less `vm.expectRevert()` in this file.
 */
contract CheckpointsTest is BaseTest {
    AGW internal wallet;
    address internal owner;
    uint256 internal ownerPk;
    address internal agent;

    address internal cea;
    address internal protocol;
    address internal asset;
    NativeTarget internal nativeTarget;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));

    /**
     * @dev Steady-state gas of one owner `execute` single (1 wei to an empty account, warm wallet):
     *      measured at 15,071 with `forge test` on forge 1.5.1-stable, plus 10%.
     */
    uint256 internal constant OWNER_SINGLE_GAS_BUDGET = 16_579;

    /// @dev The same call under `--isolate` (which `--gas-report` switches on): every top-level call is
    ///      its own transaction. Measured at 46,851, plus 10%.
    uint256 internal constant OWNER_SINGLE_GAS_BUDGET_ISOLATED = 51_537;

    /// @dev Steady-state gas of an owner `execute` batch of five such calls: measured at 62,736, plus 10%.
    uint256 internal constant OWNER_BATCH5_GAS_BUDGET = 69_010;

    /// @dev The same batch under `--isolate`: measured at 98,940, plus 10%.
    uint256 internal constant OWNER_BATCH5_GAS_BUDGET_ISOLATED = 108_834;

    function setUp() public override {
        super.setUp();
        (owner, ownerPk) = makeAddrAndKey("checkpointOwner");
        agent = makeAddr("checkpointAgent");
        cea = makeAddr("destinationAccount");
        protocol = makeAddr("farChainProtocol");
        asset = address(new MockPRC20()); // answers SOURCE_CHAIN_NAMESPACE, which URP checks at init
        nativeTarget = new NativeTarget();

        vm.warp(1_000_000_000);

        wallet = newWallet(owner);
        vm.deal(address(wallet), 100 ether);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _single() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _batch() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleBatch());
    }

    function _ref(address target, uint256 value, bytes memory callData) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, value, callData));
    }

    function _ownerSingle(AGW w, address target, uint256 value, bytes memory callData) internal {
        vm.prank(owner);
        w.execute(_single(), ExecutionLib.encodeSingle(target, value, callData));
    }

    function _ownerBatch(AGW w, Execution[] memory execs) internal {
        vm.prank(owner);
        w.execute(_batch(), ExecutionLib.encodeBatch(execs));
    }

    function _expectCheckpoint(AGW w, uint64 seq, CheckpointKind kind, bytes32 ref) internal {
        vm.expectEmit(true, false, false, true, address(w));
        emit IAGW.Checkpointed(seq, kind, ref, uint64(block.number));
    }

    function _urpInitData() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: protocol, selector: SWAP_SELECTOR, beneficiaryOffset: 36, hasBeneficiary: true, maxValue: 1 ether
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 365 days),
                expectedCEA: cea,
                maxGasPerCall: 5 ether,
                assets: oneAsset(asset, 100 ether, 1000 ether),
                allowedCalls: rules
            })
        );
    }

    function _universalSession(address agent_) internal view returns (Session memory) {
        return canonicalSession(agentConfig(agent_), _urpInitData());
    }

    function _grant(address agent_) internal returns (bytes32) {
        vm.prank(owner);
        return wallet.grantRules(_universalSession(agent_));
    }

    function _nativeSession(address agent_) internal view returns (Session memory s) {
        NativeConfig memory cfg = NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: address(nativeTarget),
            selector: NativeTarget.ping.selector,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: new ArgPin[](0)
        });
        s = sessionWithPolicy(address(urp), agentConfig(agent_), nativeInitData(cfg));
        s.actions[0].actionTarget = address(nativeTarget);
        s.actions[0].actionTargetSelector = NativeTarget.ping.selector;
    }

    /// @dev A valid universal agent request against `wallet`, bridging `amount` with `pcValue` PC.
    function _agentEcd(uint256 amount, uint256 pcValue) internal view returns (bytes memory) {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: protocol, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), cea) });
        return
            ExecutionLib.encodeSingle(GATEWAY, pcValue, outboundRequest(asset, amount, 1 ether, address(wallet), calls));
    }

    /// @dev The `Checkpointed` logs `w` emitted, in order.
    function _checkpoints(Vm.Log[] memory logs, address w)
        internal
        pure
        returns (uint64[] memory seqs, uint8[] memory kinds, bytes32[] memory refs)
    {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == w && logs[i].topics[0] == IAGW.Checkpointed.selector) ++n;
        }
        seqs = new uint64[](n);
        kinds = new uint8[](n);
        refs = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != w || logs[i].topics[0] != IAGW.Checkpointed.selector) continue;
            seqs[k] = uint64(uint256(logs[i].topics[1]));
            (kinds[k], refs[k],) = abi.decode(logs[i].data, (uint8, bytes32, uint64));
            ++k;
        }
    }

    function _countTopic(Vm.Log[] memory logs, address w, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == w && logs[i].topics[0] == topic) ++n;
        }
    }

    // ═══════════════════════════════ the owner doors ═══════════════════════════════

    function test_CP01_freshWalletStartsAtZero() public view {
        assertEq(wallet.checkpointCount(), 0, "a fresh wallet has no checkpoint");
        assertEq(wallet.lastCheckpointBlock(), 0, "and no checkpoint block");
    }

    function test_CP02_executeSingleTicksOnce() public {
        address target = makeAddr("eoaTarget");

        vm.recordLogs();
        _expectCheckpoint(wallet, 1, CheckpointKind.OWNER_ACTION, _ref(target, 1, ""));
        _ownerSingle(wallet, target, 1, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wallet.checkpointCount(), 1, "one call, one checkpoint");
        assertEq(wallet.lastCheckpointBlock(), block.number, "stamped with this block");
        assertEq(_countTopic(logs, address(wallet), IAGW.Checkpointed.selector), 1, "exactly one Checkpointed");
    }

    function test_CP03_executeBatchTicksPerCall() public {
        Execution[] memory execs = new Execution[](3);
        execs[0] = Execution({ target: makeAddr("a"), value: 1, callData: "" });
        execs[1] = Execution({ target: makeAddr("b"), value: 2, callData: "" });
        execs[2] = Execution({ target: makeAddr("c"), value: 3, callData: hex"" });

        for (uint64 i; i < 3; ++i) {
            _expectCheckpoint(
                wallet, i + 1, CheckpointKind.OWNER_ACTION, _ref(execs[i].target, execs[i].value, execs[i].callData)
            );
        }
        _ownerBatch(wallet, execs);

        assertEq(wallet.checkpointCount(), 3, "one checkpoint per call in the batch");
    }

    /**
     * ⚠️ NEVER-DELETE. The snapshot-ordering guarantee: a consumer snapshotting during an owner call —
     * an 8183 hook inside `fund` — already sees that call's checkpoint, and every later call in the
     * same batch moves the counter again. This is what makes "once per call, before the call" right.
     */
    function test_CP04_tickPrecedesEachCall() public {
        CheckpointProbe probe = new CheckpointProbe();
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: address(probe), value: 0, callData: abi.encodeCall(CheckpointProbe.snap, ()) });
        execs[1] = execs[0];
        _ownerBatch(wallet, execs);

        assertEq(probe.seenLength(), 2, "the probe was called twice");
        assertEq(probe.seen(0), 1, "the first call already saw its own checkpoint");
        assertEq(probe.seen(1), 2, "the second call saw the second checkpoint");
        assertEq(wallet.checkpointCount(), 2, "final count");

        AGW other = newWallet(owner);
        CheckpointProbe probe2 = new CheckpointProbe();
        _ownerSingle(other, address(probe2), 0, abi.encodeCall(CheckpointProbe.snap, ()));
        assertEq(probe2.seenLength(), 1, "the probe was called once");
        assertEq(probe2.seen(0), 1, "a single call already sees its own checkpoint");
    }

    /**
     * ⚠️ NEVER-DELETE. Why per call, before the call. (a) A clean funding batch ends exactly at the
     * snapshot the consumer took inside it. (b) A withdrawal batched AFTER the snapshot moves the
     * counter past it. A once-per-`execute` tick fails one half or the other: at the end it makes (a)
     * look tampered with; at the start it hides the withdrawal in (b).
     */
    function test_CP05_sameBatchWithdrawalIsVisible() public {
        MockERC20 token = new MockERC20();

        // (a) clean: [approve, snapshot]
        token.mint(address(wallet), 100e6);
        CheckpointProbe probe = new CheckpointProbe();
        Execution[] memory clean = new Execution[](2);
        clean[0] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(MockERC20.approve, (makeAddr("spender"), 1))
        });
        clean[1] = Execution({ target: address(probe), value: 0, callData: abi.encodeCall(CheckpointProbe.snap, ()) });
        _ownerBatch(wallet, clean);
        assertEq(probe.seen(0), 2, "the snapshot includes both ticks so far");
        assertEq(wallet.checkpointCount(), probe.seen(0), "a clean batch ends at the snapshot");

        // (b) interference: [snapshot, withdraw everything]
        AGW w2 = newWallet(owner);
        token.mint(address(w2), 100e6);
        CheckpointProbe probe2 = new CheckpointProbe();
        Execution[] memory spoiled = new Execution[](2);
        spoiled[0] =
            Execution({ target: address(probe2), value: 0, callData: abi.encodeCall(CheckpointProbe.snap, ()) });
        spoiled[1] = Execution({
            target: address(token), value: 0, callData: abi.encodeCall(MockERC20.transfer, (owner, 100e6))
        });
        _ownerBatch(w2, spoiled);
        assertEq(token.balanceOf(owner), 100e6, "the owner withdrew");
        assertEq(w2.checkpointCount(), probe2.seen(0) + 1, "the withdrawal after the snapshot is visible");
    }

    function test_CP06_emptyBatchTicksNothing() public {
        vm.recordLogs();
        _ownerBatch(wallet, new Execution[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wallet.checkpointCount(), 0, "an empty batch did nothing");
        assertEq(_countTopic(logs, address(wallet), IAGW.Checkpointed.selector), 0, "no Checkpointed");
        assertEq(_countTopic(logs, address(wallet), IAGW.OwnerExecuted.selector), 1, "the door itself ran");
    }

    function test_CP07_revertedOwnerCallLeavesNoCheckpoint() public {
        Reverter r = new Reverter();
        bytes memory ecd = ExecutionLib.encodeSingle(address(r), 0, abi.encodeCall(Reverter.boom, ()));

        vm.prank(owner);
        vm.expectRevert(bytes("boom"));
        wallet.execute(_single(), ecd);

        assertEq(wallet.checkpointCount(), 0, "the revert unwound the checkpoint");
        assertEq(wallet.lastCheckpointBlock(), 0, "and its block stamp");
    }

    function test_CP08_executeWithSigTicksPerCall() public {
        address target = makeAddr("sigTarget");

        // single
        bytes memory cd = ExecutionLib.encodeSingle(target, 1, "");
        OwnerIntent memory i = blankIntent(owner, address(wallet), RELAYER);
        i.mode = _single();
        i.execCalldataHash = keccak256(cd);
        i.nonceKey = OWNER_LANE_FLAG;
        i.nonceSeq = 0;
        bytes memory sig = signIntent(ownerPk, i);

        _expectCheckpoint(wallet, 1, CheckpointKind.OWNER_ACTION, _ref(target, 1, ""));
        vm.prank(RELAYER);
        wallet.executeWithSig(i.mode, cd, i, sig);
        assertEq(wallet.checkpointCount(), 1, "single: one checkpoint");

        // batch of two
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: target, value: 2, callData: "" });
        execs[1] = Execution({ target: makeAddr("sigTarget2"), value: 3, callData: "" });
        bytes memory bcd = ExecutionLib.encodeBatch(execs);
        OwnerIntent memory j = blankIntent(owner, address(wallet), RELAYER);
        j.mode = _batch();
        j.execCalldataHash = keccak256(bcd);
        j.nonceKey = OWNER_LANE_FLAG;
        j.nonceSeq = 1;
        bytes memory bsig = signIntent(ownerPk, j);

        _expectCheckpoint(wallet, 2, CheckpointKind.OWNER_ACTION, _ref(execs[0].target, 2, ""));
        _expectCheckpoint(wallet, 3, CheckpointKind.OWNER_ACTION, _ref(execs[1].target, 3, ""));
        vm.prank(RELAYER);
        wallet.executeWithSig(j.mode, bcd, j, bsig);
        assertEq(wallet.checkpointCount(), 3, "batch: one checkpoint per call");
    }

    // ═══════════════════════════════ grant and revoke ═══════════════════════════════

    function test_CP09_grantTicksRulesGranted() public {
        // grantRules: the id is predicted the engine's way — the wallet's grant nonce is the salt.
        Session memory s = _universalSession(agent);
        Session memory salted = _universalSession(agent);
        salted.salt = bytes32(uint256(wallet.grantNonce()));
        bytes32 predicted = PermissionId.unwrap(IdLib.toPermissionIdMemory(salted));

        _expectCheckpoint(wallet, 1, CheckpointKind.RULES_GRANTED, predicted);
        vm.expectEmit(true, true, false, true, address(wallet));
        emit IAGW.RulesGranted(predicted, RulesType.UNIVERSAL, keccak256(bytes(CHAIN_SEPOLIA)), CHAIN_SEPOLIA);
        vm.prank(owner);
        bytes32 rid = wallet.grantRules(s);
        assertEq(rid, predicted, "the predicted id");
        assertEq(wallet.checkpointCount(), 1, "a grant ticks once");

        // grantRulesWithSig: same kind, its own id.
        Session memory s2 = _universalSession(makeAddr("secondAgent"));
        OwnerIntent memory i = blankIntent(owner, address(wallet), RELAYER);
        i.sessionHash = keccak256(abi.encode(s2));
        i.grantNonce = wallet.grantNonce();
        bytes memory sig = signIntent(ownerPk, i);

        vm.recordLogs();
        vm.prank(RELAYER);
        bytes32 rid2 = wallet.grantRulesWithSig(s2, i, sig);
        (uint64[] memory seqs, uint8[] memory kinds, bytes32[] memory refs) =
            _checkpoints(vm.getRecordedLogs(), address(wallet));

        assertEq(seqs.length, 1, "a signed grant ticks once");
        assertEq(seqs[0], 2, "seq 2");
        assertEq(kinds[0], uint8(CheckpointKind.RULES_GRANTED), "kind RULES_GRANTED");
        assertEq(refs[0], rid2, "ref is the signed grant's own id");
        assertEq(wallet.checkpointCount(), 2, "count");
    }

    function test_CP10_failedGrantTicksNothing() public {
        Session memory s = _universalSession(agent);
        s.sessionValidator = ISessionValidator(makeAddr("notOurValidator"));

        vm.prank(owner);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        wallet.grantRules(s);

        assertEq(wallet.checkpointCount(), 0, "a refused grant ticks nothing");
    }

    function test_CP11_revokeRulesTicksRulesRevoked() public {
        bytes32 rid = _grant(agent);
        uint64 n = wallet.checkpointCount();

        _expectCheckpoint(wallet, n + 1, CheckpointKind.RULES_REVOKED, rid);
        vm.expectEmit(true, false, false, true, address(wallet));
        emit IAGW.RulesRevoked(rid);
        vm.prank(owner);
        wallet.revokeRules(rid);
        assertEq(wallet.checkpointCount(), n + 1, "a revoke ticks once");

        bytes32 ghost = keccak256("never granted");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnknownPermission.selector, ghost));
        wallet.revokeRules(ghost);
        assertEq(wallet.checkpointCount(), n + 1, "a ghost revoke ticks nothing");
    }

    function test_CP12_revokeAllTicksOncePerId() public {
        bytes32[3] memory rids = [_grant(agent), _grant(makeAddr("agentB")), _grant(makeAddr("agentC"))];
        uint64 n = wallet.checkpointCount();

        vm.recordLogs();
        vm.prank(owner);
        wallet.revokeAllRules();
        (uint64[] memory seqs, uint8[] memory kinds, bytes32[] memory refs) =
            _checkpoints(vm.getRecordedLogs(), address(wallet));

        assertEq(wallet.checkpointCount(), n + 3, "one checkpoint per revoked id");
        assertEq(seqs.length, 3, "three Checkpointed");
        for (uint256 k; k < 3; ++k) {
            assertEq(seqs[k], n + 1 + k, "consecutive seqs");
            assertEq(kinds[k], uint8(CheckpointKind.RULES_REVOKED), "kind RULES_REVOKED");
            bool found;
            for (uint256 m; m < 3; ++m) {
                if (refs[k] == rids[m]) found = true;
            }
            assertTrue(found, "each ref is one of the three ids");
        }
        assertTrue(refs[0] != refs[1] && refs[1] != refs[2] && refs[0] != refs[2], "three distinct ids");

        vm.recordLogs();
        vm.prank(owner);
        wallet.revokeAllRules();
        assertEq(wallet.checkpointCount(), n + 3, "an empty revokeAll ticks nothing");
        assertEq(_countTopic(vm.getRecordedLogs(), address(wallet), IAGW.Checkpointed.selector), 0, "no event");
    }

    // ═══════════════════════════════ who can never tick ═══════════════════════════════

    function testFuzz_CP13_noNonOwnerPathTicks(address caller) public {
        vm.assume(caller != owner && caller != address(wallet) && caller != agent);
        assumeNotForgeAddress(caller);

        bytes32 rid = _grant(agent);
        uint64 n = wallet.checkpointCount();
        Session memory s = _universalSession(agent);
        bytes memory ecd = ExecutionLib.encodeSingle(makeAddr("x"), 1, "");

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.execute(_single(), ecd);

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.grantRules(s);

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeRules(rid);

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeAllRules();

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.installModule(1, address(validator), "");

        vm.prank(caller);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.uninstallModule(1, address(engine), "");

        bytes memory agentEcd = _agentEcd(1 ether, 0);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, rid, caller));
        wallet.executeAsAgent(rid, _single(), agentEcd);

        assertEq(wallet.checkpointCount(), n, "no non-owner path ticks");
    }

    /**
     * ⚠️ NEVER-DELETE. The agent door never moves the counter — not a successful universal action, not
     * a successful native action, not one URP refuses, not a refused caller. An agent that could tick
     * the counter could always fake owner interference and get paid for a job it spoiled.
     */
    function test_CP14_agentActionsNeverTick() public {
        bytes32 uRid = _grant(agent);
        vm.prank(owner);
        bytes32 nRid = wallet.grantRules(_nativeSession(agent));
        uint64 n = wallet.checkpointCount();
        uint64 b = wallet.lastCheckpointBlock();
        assertEq(n, 2, "the two grants ticked");

        etchCallRecorder(GATEWAY);
        bytes memory universal = _agentEcd(1 ether, 0);
        bytes memory native = ExecutionLib.encodeSingle(address(nativeTarget), 0, abi.encodeCall(NativeTarget.ping, ()));
        bytes memory overCap = _agentEcd(1 ether, 6 ether);

        // a successful universal agent action
        vm.roll(block.number + 1);
        vm.prank(agent);
        wallet.executeAsAgent(uRid, _single(), universal);
        assertEq(callsRecorded(GATEWAY), 1, "the universal action ran");
        assertEq(wallet.checkpointCount(), n, "universal agent action: no tick");
        assertEq(wallet.lastCheckpointBlock(), b, "universal agent action: no block stamp");

        // a successful native agent action
        vm.roll(block.number + 1);
        vm.prank(agent);
        wallet.executeAsAgent(nRid, _single(), native);
        assertEq(nativeTarget.pings(), 1, "the native action ran");
        assertEq(wallet.checkpointCount(), n, "native agent action: no tick");
        assertEq(wallet.lastCheckpointBlock(), b, "native agent action: no block stamp");

        // an agent action URP refuses (gate 8)
        vm.roll(block.number + 1);
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.PCValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)
            )
        );
        vm.prank(agent);
        wallet.executeAsAgent(uRid, _single(), overCap);
        assertEq(wallet.checkpointCount(), n, "refused agent action: no tick");

        // a refused caller
        vm.roll(block.number + 1);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, uRid, stranger));
        wallet.executeAsAgent(uRid, _single(), universal);
        assertEq(wallet.checkpointCount(), n, "refused caller: no tick");
        assertEq(wallet.lastCheckpointBlock(), b, "refused caller: no block stamp");
    }

    // ═══════════════════════════════ consequences, pinned ═══════════════════════════════

    function test_CP15_selfLifecycleCallTicksTwice() public {
        bytes32 rid = _grant(agent);
        uint64 n = wallet.checkpointCount();
        bytes memory revokeCd = abi.encodeCall(AGW.revokeRules, (rid));
        Execution[] memory execs = new Execution[](1);
        execs[0] = Execution({ target: address(wallet), value: 0, callData: revokeCd });

        _expectCheckpoint(wallet, n + 1, CheckpointKind.OWNER_ACTION, _ref(address(wallet), 0, revokeCd));
        _expectCheckpoint(wallet, n + 2, CheckpointKind.RULES_REVOKED, rid);
        _ownerBatch(wallet, execs);

        assertEq(wallet.checkpointCount(), n + 2, "the owner call and the revoke inside it both ticked");
    }

    function test_CP16_directEngineGrantTicksAsOwnerAction() public {
        Session memory s = _universalSession(agent);
        s.salt = bytes32(uint256(0xD1EC7));
        Session[] memory arr = new Session[](1);
        arr[0] = s;

        vm.recordLogs();
        _ownerSingle(wallet, address(engine), 0, abi.encodeCall(ISmartSession.enableSessions, (arr)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint64[] memory seqs, uint8[] memory kinds,) = _checkpoints(logs, address(wallet));

        assertTrue(engine.isPermissionEnabled(IdLib.toPermissionIdMemory(s), address(wallet)), "enabled on the engine");
        assertEq(seqs.length, 1, "exactly one checkpoint");
        assertEq(kinds[0], uint8(CheckpointKind.OWNER_ACTION), "as an owner action");
        assertEq(_countTopic(logs, address(wallet), IAGW.RulesGranted.selector), 0, "no RulesGranted");
        assertEq(wallet.checkpointCount(), 1, "count");
    }

    function test_CP17_lastCheckpointBlockTracksTheBlock() public {
        uint256 blockB = 100;
        vm.roll(blockB);
        _ownerSingle(wallet, makeAddr("t1"), 1, "");
        assertEq(wallet.lastCheckpointBlock(), blockB, "stamped at B");

        vm.roll(blockB + 10);
        Execution[] memory execs = new Execution[](2);
        execs[0] = Execution({ target: makeAddr("t2"), value: 1, callData: "" });
        execs[1] = Execution({ target: makeAddr("t3"), value: 1, callData: "" });
        _ownerBatch(wallet, execs);

        assertEq(wallet.lastCheckpointBlock(), blockB + 10, "stamped at B + 10");
        assertEq(wallet.checkpointCount(), 3, "two checkpoints share block B + 10 - consumers compare counts");
    }

    function test_CP18_countersArePerWallet() public {
        AGW w2 = newWallet(owner);
        vm.deal(address(w2), 1 ether);
        vm.roll(50);

        _ownerSingle(wallet, makeAddr("t"), 1, "");
        assertEq(wallet.checkpointCount(), 1, "the first wallet ticked");
        assertEq(w2.checkpointCount(), 0, "the second did not");
        assertEq(w2.lastCheckpointBlock(), 0, "nor its block");

        _ownerSingle(w2, makeAddr("t"), 1, "");
        assertEq(w2.checkpointCount(), 1, "the second ticked on its own");
        assertEq(wallet.checkpointCount(), 1, "the first is unmoved");
    }

    function test_CP19_ownerDoorStillTicksInDegradedStates() public {
        // (a) engine uninstalled — uninstalling does not tick; the owner door still ticks.
        AGW w1 = newWallet(owner);
        vm.deal(address(w1), 1 ether);
        vm.prank(owner);
        w1.uninstallModule(1, address(engine), "");
        assertFalse(w1.isModuleInstalled(1, address(engine), ""), "engine uninstalled");
        assertEq(w1.checkpointCount(), 0, "uninstallModule does not tick");
        _ownerSingle(w1, makeAddr("sink1"), 1, "");
        assertEq(w1.checkpointCount(), 1, "the owner door ticks with the engine uninstalled");

        // (b) hostile validator installed — installing does not tick; the owner door still ticks.
        AGW w2 = newWallet(owner);
        vm.deal(address(w2), 1 ether);
        CheckpointHostileValidator hostile = new CheckpointHostileValidator();
        vm.prank(owner);
        w2.installModule(1, address(hostile), "");
        assertEq(w2.checkpointCount(), 0, "installModule does not tick");
        _ownerSingle(w2, makeAddr("sink2"), 1, "");
        assertEq(w2.checkpointCount(), 1, "the owner door ticks with a hostile validator installed");
    }

    // ═══════════════════════════════════ gas ═══════════════════════════════════

    function test_gas_ownerDoorCheckpointOverhead() public {
        address sink = makeAddr("gasSink");
        bytes memory single = ExecutionLib.encodeSingle(sink, 1, "");
        Execution[] memory execs = new Execution[](5);
        for (uint256 i; i < 5; ++i) {
            execs[i] = Execution({ target: sink, value: 1, callData: "" });
        }
        bytes memory batch5 = ExecutionLib.encodeBatch(execs);
        bytes32 single_ = _single();
        bytes32 batch_ = _batch();

        _ownerSingle(wallet, sink, 1, ""); // warm the wallet and the sink

        vm.prank(owner);
        uint256 before = gasleft();
        wallet.execute(single_, single);
        uint256 usedSingle = before - gasleft();

        vm.prank(owner);
        before = gasleft();
        wallet.execute(batch_, batch5);
        uint256 usedBatch = before - gasleft();

        emit log_named_uint("owner execute single (steady state) gas", usedSingle);
        emit log_named_uint("owner execute batch of 5 (steady state) gas", usedBatch);

        bool isolated = isolatedCalls();
        assertLt(
            usedSingle,
            isolated ? OWNER_SINGLE_GAS_BUDGET_ISOLATED : OWNER_SINGLE_GAS_BUDGET,
            "owner single within its measured budget"
        );
        assertLt(
            usedBatch,
            isolated ? OWNER_BATCH5_GAS_BUDGET_ISOLATED : OWNER_BATCH5_GAS_BUDGET,
            "owner batch of 5 within its measured budget"
        );
    }
}

// ─────────────────────────────── test doubles ───────────────────────────────

/// @dev Records the calling wallet's checkpoint count each time it is called — stands in for a
///      consumer (an 8183 hook) snapshotting during an owner-door call. Observer only.
contract CheckpointProbe {
    uint64[] public seen;

    function snap() external {
        seen.push(AGW(payable(msg.sender)).checkpointCount());
    }

    function seenLength() external view returns (uint256) {
        return seen.length;
    }
}

/// @dev A Push-side contract a native rules set can name. Counts its calls; decides nothing.
contract NativeTarget {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

/// @dev A call target that always reverts with a reason, for the reverted-owner-call test.
contract Reverter {
    function boom() external pure {
        revert("boom");
    }
}

/**
 * @dev Copy of `2_ownerDoor.t.sol`'s `HostileValidator` (distinct name to keep artifact names unique):
 *      installable, and hostile in everything reachable after installation. The owner door must ignore
 *      it, because the owner door never consults the module registry.
 */
contract CheckpointHostileValidator {
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
