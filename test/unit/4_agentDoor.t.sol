// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import {
    AllowedCall,
    AmountRule,
    ArgPin,
    Config,
    NativeConfig,
    OWNER_LANE_FLAG,
    OwnerIntent
} from "../../src/libraries/Types.sol";
import { AGW } from "../../src/AGW.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGWErrors } from "../../src/libraries/Errors.sol";
import { AgentValidator } from "../../src/validators/AgentValidator.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { Multicall } from "../../src/libraries/Types.sol";
import { Session, PermissionId, ConfigId, SmartSessionMode } from "smartsessions/DataTypes.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";
import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";
import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

/**
 * @notice AGW — the agent door, `executeAsAgent`.
 *
 * @dev    Every test here drives the REAL path: real engine, real URP, real sender validator. The
 *         agent is a Push address and calls the door itself; the wallet checks it is the agent the
 *         rules set names, writes it into the engine's signature field, and the validator confirms
 *         it. Nothing is mocked except where a test needs a failure the real components cannot
 *         produce (a fixed-verdict policy for W-07, a reverting target for W-18, a re-entering
 *         target for W-05) — and those are OBSERVERS of the wallet's reaction, never oracles.
 *
 * @dev    EXACTLY ONE selector-less `vm.expectRevert()` exists in this file, and it is bare by
 *         construction: `test_W03_OpHash_Field6_MalformedBatchShapeIsRejected`, where the ENGINE's
 *         batch decoder rejects a shape mismatch and reverts WITHOUT DATA. Every other negative
 *         test names its error.
 *
 *         The recurring named expectations, and what each proves:
 *           · `CallerIsNotAgent(pid, caller)` — the wallet's own pre-check: the caller is not the
 *             agent `pid` names here (including an unknown, revoked or non-canonical id).
 *           · `NoPoliciesSet(pid)`            — the engine's minimum-one-policy floor.
 *           · `expectUrpGate(...)`           — a URP gate, seen through the engine's 32-byte
 *             rewrap as `PolicyCheckReverted`. Names WHICH gate fired.
 */
contract PushAgentWalletAgentDoorTest is BaseTest {
    AGW internal wallet;
    address internal WALLET_OWNER;
    uint256 internal walletOwnerPk;

    /// @dev The agent's Push address. Its key is used only by X17, to prove an agent-signed
    ///      OwnerIntent is refused; the agent door itself verifies no signature.
    address internal agentAddr;
    uint256 internal agentPk;

    address internal CEA;
    address internal PROTOCOL;
    address internal ASSET;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));
    uint16 internal constant BENEFICIARY_OFFSET = 36;

    /**
     * @dev Steady-state gas of one universal `executeAsAgent` — warm wallet, warm engine and URP rows,
     *      the gateway a call recorder — measured at 41,016 on forge 1.5.1-stable with the pinned
     *      toolchain, plus 10%. It measures the door, the engine and URP, not a real gateway's work.
     */
    uint256 internal constant AGENT_DOOR_GAS_BUDGET = 45_118;

    /**
     * @dev The same call under `--isolate`, which `--gas-report` switches on: every top-level call is
     *      then its own transaction, paying the 21,000 intrinsic cost, its calldata and cold access
     *      again. Measured at 134,316, plus 10%.
     */
    uint256 internal constant AGENT_DOOR_GAS_BUDGET_ISOLATED = 147_748;

    bytes32 internal permissionId;

    function setUp() public override {
        super.setUp();
        // makeAddrAndKey("walletOwner") is the same address makeAddr("walletOwner") yields; the key
        // lets the owner-lane test sign an OwnerIntent.
        (WALLET_OWNER, walletOwnerPk) = makeAddrAndKey("walletOwner");
        (agentAddr, agentPk) = ecdsaKey("agentSigner");

        CEA = makeAddr("destinationAccount");
        PROTOCOL = makeAddr("farChainProtocol");
        ASSET = address(new MockPRC20()); // answers SOURCE_CHAIN_NAMESPACE, which URP checks at init

        vm.warp(1_000_000_000);

        wallet = newWallet(WALLET_OWNER);
        vm.deal(address(wallet), 100 ether);

        permissionId = _grant();
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _urpInitData() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 365 days),
                destChainHash: keccak256("eip155:11155111"),
                expectedCEA: CEA,
                asset: ASSET,
                maxAmountPerCall: 100 ether,
                maxAmountTotal: 1000 ether,
                maxPCPerCall: 5 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    function _grant() internal returns (bytes32) {
        return _grantFor(agentAddr);
    }

    function _grantFor(address agent) internal returns (bytes32) {
        vm.prank(WALLET_OWNER);
        return wallet.grantRules(canonicalSession(agentConfig(agent), _urpInitData()));
    }

    function _calls() internal view returns (Multicall[] memory c) {
        c = new Multicall[](1);
        c[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) });
    }

    /// @dev The wallet-level executionCalldata: a SINGLE call to the gateway carrying a valid
    ///      outbound request. This is the exact shape URP's gauntlet is built to police.
    function _executionCalldata(uint256 amount, uint256 pcValue) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            GATEWAY, pcValue, outboundRequest(ASSET, amount, 1 ether, address(wallet), _calls())
        );
    }

    function _ecd() internal view returns (bytes memory) {
        return _executionCalldata(1 ether, 0);
    }

    function _singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _submitAs(address caller, bytes32 pid, bytes32 mode, bytes memory ecd) internal {
        vm.prank(caller);
        wallet.executeAsAgent(pid, mode, ecd);
    }

    /// @dev Submit a well-formed request as the agent. The gateway is a recorder so dispatch succeeds.
    function _run(bytes32 pid, bytes memory ecd) internal {
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));
        _submitAs(agentAddr, pid, _singleMode(), ecd);
    }

    function _run() internal {
        _run(permissionId, _ecd());
    }

    function _configIdOf(bytes32 pid, address target, bytes4 selector) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(target, selector));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(pid, actionId));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), actionPolicyId)));
    }

    function _configId() internal view returns (ConfigId) {
        return _configIdOf(permissionId, GATEWAY, SEND_OUTBOUND_SELECTOR);
    }

    function _spentOf(bytes32 pid) internal view returns (uint256) {
        return urp.getConfig(_configIdOf(pid, GATEWAY, SEND_OUTBOUND_SELECTOR), address(wallet)).spent;
    }

    function _spent() internal view returns (uint256) {
        return _spentOf(permissionId);
    }

    /// @dev The exact operation the wallet must hand the engine for `(pid, mode, ecd)` from `caller`.
    function _expectedOp(bytes32 pid, bytes32 mode, bytes memory ecd, address caller)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(wallet);
        op.nonce = 0;
        op.initCode = "";
        op.callData = abi.encodeWithSelector(AGW.execute.selector, mode, ecd);
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        op.paymasterAndData = "";
        op.signature = abi.encodePacked(SmartSessionMode.USE, pid, caller);
    }

    /// @dev A session on one native action, with an arbitrary policy and config. For tests that
    ///      enable sessions on the engine DIRECTLY, bypassing `grantRules`.
    function _directSession(
        address sessionValidator,
        bytes memory config,
        address target,
        bytes4 selector,
        address policy,
        bytes memory policyInitData,
        bytes32 salt
    ) internal view returns (Session memory s) {
        s = sessionWithPolicy(policy, config, policyInitData);
        s.sessionValidator = ISessionValidator(sessionValidator);
        s.actions[0].actionTarget = target;
        s.actions[0].actionTargetSelector = selector;
        s.salt = salt;
    }

    /// @dev The owner enables `s` on the engine DIRECTLY, through the owner door — the legitimate
    ///      path that bypasses `grantRules` and its shape checks entirely.
    function _enableDirect(Session memory s) internal returns (bytes32 pid) {
        Session[] memory arr = new Session[](1);
        arr[0] = s;
        vm.prank(WALLET_OWNER);
        wallet.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(address(engine), 0, abi.encodeCall(ISmartSession.enableSessions, (arr)))
        );
        pid = PermissionId.unwrap(IdLib.toPermissionIdMemory(s));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "enabled directly");
    }

    // ═══════════════════════════ the happy path ═══════════════════════════

    function test_HappyPath_ValidatesAndDispatches() public {
        _run();

        assertEq(callsRecorded(GATEWAY), 1, "the gateway was called exactly once");
        assertEq(_spent(), 1 ether, "URP metered the bridged amount");
    }

    // ═══════════════════════════════════ W-19 ═══════════════════════════════════

    /// ONLY THE AGENT: every other caller — the owner included — is refused before the engine runs,
    /// and nothing moves. Then the agent itself succeeds.
    function test_W19_OnlyTheAgentMayCall() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();

        address[8] memory callers = [
            WALLET_OWNER,
            OWNER,
            RELAYER,
            makeAddr("stranger"),
            address(factory),
            address(urp),
            address(engine),
            address(validator)
        ];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, callers[i]));
            _submitAs(callers[i], permissionId, _singleMode(), ecd);
        }

        assertEq(callsRecorded(GATEWAY), 0, "nothing dispatched");
        assertEq(_spent(), 0, "nothing metered");

        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
        assertEq(callsRecorded(GATEWAY), 1, "the agent itself succeeds");
    }

    function testFuzz_W19_anyNonAgentRefused(address caller) public {
        vm.assume(caller != agentAddr);
        bytes memory ecd = _ecd();

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, caller));
        _submitAs(caller, permissionId, _singleMode(), ecd);

        assertEq(_spent(), 0, "nothing metered");
    }

    // ═══════════════════════════════════ W-02 ═══════════════════════════════════

    /**
     * W-02 ⚠️ NEVER-DELETE — A REQUEST DIES WITH ITS RULES SET.
     *
     * A request built for rules set A. Revoke A, regrant BYTE-IDENTICAL terms as rules set B. The
     * request for A must now fail and must never charge B. Two mechanisms carry it: removal clears
     * A's agent on the engine, so `agentOf(A)` is zero and the agent check refuses; and the wallet's
     * grant nonce salts B with a fresh id, so nothing addressed to A can ever reach B.
     */
    function test_W02_BankedRequest_FailsAfterRegrant() public {
        etchCallRecorder(GATEWAY);
        bytes memory banked = _ecd();

        vm.startPrank(WALLET_OWNER);
        wallet.revokeRules(permissionId);
        bytes32 newPid = wallet.grantRules(canonicalSession(agentConfig(agentAddr), _urpInitData()));
        vm.stopPrank();

        assertTrue(newPid != permissionId, "the regranted rules set has a NEW id");
        assertEq(wallet.agentOf(permissionId), address(0), "the revoked id names no agent");
        assertEq(wallet.agentOf(newPid), agentAddr, "the new id names the agent");

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agentAddr));
        _submitAs(agentAddr, permissionId, _singleMode(), banked);

        assertEq(callsRecorded(GATEWAY), 0, "nothing dispatched");
        assertEq(_spentOf(newPid), 0, "the new rules set's budget is untouched");

        _submitAs(agentAddr, newPid, _singleMode(), banked);
        assertEq(_spentOf(newPid), 1 ether, "the same request works under the new id");
    }

    // ═══════════════════════════════════ W-03 ═══════════════════════════════════

    /// The request names its rules set, and the agent must be the one THAT rules set names: an agent
    /// can never act under, or charge, another agent's rules set.
    function test_W03_PermissionIdBindsTheAgent() public {
        address agentB = makeAddr("agentB");
        bytes32 pidB = _grantFor(agentB);
        bytes memory ecd = _ecd();

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pidB, agentAddr));
        _submitAs(agentAddr, pidB, _singleMode(), ecd);

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agentB));
        _submitAs(agentB, permissionId, _singleMode(), ecd);

        etchCallRecorder(GATEWAY);
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
        assertEq(_spent(), 1 ether, "A acts under its own id");
        assertEq(_spentOf(pidB), 0, "and B's budget did not move");

        _submitAs(agentB, pidB, _singleMode(), _executionCalldata(2 ether, 0));
        assertEq(_spentOf(pidB), 2 ether, "B acts under its own id");
        assertEq(_spent(), 1 ether, "and A's budget did not move");
    }

    /**
     * A MALFORMED batch — batch mode paired with single-encoded calldata — is rejected by the
     * ENGINE's batch decoder, on SHAPE, before the wallet's mode gate is reached.
     *
     * The engine ACCEPTS batch mode (`SmartSession.sol:280-288` routes it to `checkBatch7579Exec`);
     * it is only the malformed SHAPE that fails here. W-09 sends a WELL-FORMED batch and proves the
     * wallet's gate fires on its own, with its own named error.
     *
     * What this test pins: the engine rejects a shape mismatch, and it does so without revert data —
     * the one bare expectRevert in this file.
     */
    function test_W03_OpHash_Field6_MalformedBatchShapeIsRejected() public {
        bytes32 batchMode = ModeCode.unwrap(ModeLib.encodeSimpleBatch());
        bytes memory ecd = _ecd();

        // BARE BY CONSTRUCTION (1 of 1 in this file — see the header). Batch mode paired with
        // single-encoded calldata fails the ENGINE's batch decoder on SHAPE, and that decoder
        // reverts without data. There is no named error to expect.
        vm.expectRevert();
        _submitAs(agentAddr, permissionId, batchMode, ecd);

        // The wallet's own gate is still live and reachable — proven by a mode the engine accepts
        // but the wallet refuses: EXECTYPE_TRY with a single call type.
        bytes32 tryMode = bytes32(abi.encodePacked(bytes1(0x00), bytes1(0x01), bytes4(0), bytes4(0), bytes22(0)));
        assertFalse(wallet.supportsExecutionMode(tryMode), "try-exec is not an accepted mode");
    }

    // ═══════════════════════════════════ W-04 ═══════════════════════════════════

    /**
     * The same call submitted twice is two actions: both run, both are metered, both are recorded.
     * Replay protection is the sender's own transaction nonce — an EOA's nonce, or the UEA payload's
     * nonce — and the wallet keeps no agent replay state by design.
     */
    function test_W04_SameCallTwiceIsTwoActions() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();

        vm.recordLogs();
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 authorized;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wallet) && logs[i].topics[0] == IAGW.RulesActionAuthorized.selector) {
                ++authorized;
            }
        }

        assertEq(callsRecorded(GATEWAY), 2, "both dispatched");
        assertEq(_spent(), 2 ether, "both metered");
        assertEq(authorized, 2, "both recorded");
    }

    // ═══════════════════════════════════ W-05 ═══════════════════════════════════

    /**
     * A dispatched call that re-enters the agent door is refused by the reentrancy guard, and the
     * whole outer action unwinds with it.
     *
     * Driven through a real NATIVE rules set whose one action is `ReenteringTarget.poke`, so the
     * re-entry happens exactly where it could matter: inside dispatch, after validation.
     */
    function test_W05_ReentryIntoTheAgentDoorRefused() public {
        ReenteringTarget target = new ReenteringTarget();
        NativeConfig memory cfg = NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: address(target),
            selector: ReenteringTarget.poke.selector,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: 5,
            callsUsed: 0,
            pins: new ArgPin[](0)
        });
        Session memory s = sessionWithPolicy(address(urp), agentConfig(agentAddr), nativeInitData(cfg));
        s.actions[0].actionTarget = address(target);
        s.actions[0].actionTargetSelector = ReenteringTarget.poke.selector;
        vm.prank(WALLET_OWNER);
        bytes32 nativePid = wallet.grantRules(s);

        bytes memory inner = _ecd();
        bytes memory outer = ExecutionLib.encodeSingle(
            address(target),
            0,
            abi.encodeCall(ReenteringTarget.poke, (address(wallet), permissionId, _singleMode(), inner))
        );

        etchCallRecorder(GATEWAY);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _submitAs(agentAddr, nativePid, _singleMode(), outer);

        ConfigId nativeCfg = _configIdOf(nativePid, address(target), ReenteringTarget.poke.selector);
        assertEq(urp.getNativeConfig(nativeCfg, address(wallet)).callsUsed, 0, "the outer action unwound");
        assertEq(callsRecorded(GATEWAY), 0, "the inner action never ran");
        assertEq(_spent(), 0, "and nothing was metered");
    }

    // ═══════════════════════════════════ W-07 ═══════════════════════════════════

    /**
     * W-07 — the verdict is enforced. Skipping this makes the policy's expiry gate DECORATIVE: the
     * engine returns the window in `vd` and only the wallet enforces it.
     *
     * A fixed-verdict policy is used because the real URP cannot be made to return an arbitrary
     * window. It supplies only the verdict whose ENFORCEMENT by the wallet is under test. Each case is
     * a separate session the owner enables on the engine directly, with the canonical validator and
     * the agent's config, on a native target.
     */
    function test_W07_Verdict_Enforced() public {
        address target = makeAddr("verdictTarget");
        etchCallRecorder(target);
        bytes memory ecd = ExecutionLib.encodeSingle(target, 0, hex"11223344");
        uint48 nowTs = uint48(block.timestamp);

        // (i) a non-zero authorizer: the ENGINE refuses it as a policy violation, before the wallet
        //     sees a verdict (`PolicyLib.sol:31-35`, `:157`). The wallet's own `ValidationFailed`
        //     branch is therefore unreachable through the real engine.
        {
            (bytes32 pid, address policy) = _verdictSession(target, uint256(uint160(0xBEEF)), 1);
            vm.expectRevert(
                abi.encodeWithSelector(ISmartSession.PolicyViolation.selector, PermissionId.wrap(pid), policy)
            );
            _submitAs(agentAddr, pid, _singleMode(), ecd);
        }

        // (ii) before validAfter => OutsideTimeWindow. The policy's unbounded `validUntil = 0` reaches
        //      the wallet as `type(uint48).max`: the engine merges the policy's verdict with the
        //      validator's through `ValidationDataLib.intersect`, which normalises an unbounded
        //      `validUntil` to the maximum (`ValidationDataLib.sol:30-35`).
        {
            (bytes32 pid,) = _verdictSession(target, _verdict(0, nowTs + 100), 2);
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.OutsideTimeWindow.selector, nowTs + 100, type(uint48).max));
            _submitAs(agentAddr, pid, _singleMode(), ecd);
        }

        // (iii) after a non-zero validUntil => OutsideTimeWindow
        {
            (bytes32 pid,) = _verdictSession(target, _verdict(nowTs - 1, 0), 3);
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.OutsideTimeWindow.selector, uint48(0), nowTs - 1));
            _submitAs(agentAddr, pid, _singleMode(), ecd);
        }

        // (iv) validUntil == 0 and validAfter == 0 => unbounded, dispatches
        {
            (bytes32 pid,) = _verdictSession(target, 0, 4);
            _submitAs(agentAddr, pid, _singleMode(), ecd);
            assertEq(callsRecorded(target), 1, "validUntil == 0 is unbounded, not expired");
        }

        // (v) validUntil == now => still valid (the check is strictly greater-than)
        {
            (bytes32 pid,) = _verdictSession(target, _verdict(nowTs, 0), 5);
            _submitAs(agentAddr, pid, _singleMode(), ecd);
            assertEq(callsRecorded(target), 2, "validUntil == now is not expired");
        }

        // (vi) validAfter == now => already valid (the check is strictly less-than)
        {
            (bytes32 pid,) = _verdictSession(target, _verdict(0, nowTs), 6);
            _submitAs(agentAddr, pid, _singleMode(), ecd);
            assertEq(callsRecorded(target), 3, "validAfter == now is valid");
        }
    }

    function _verdict(uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return uint256(validUntil) << 160 | uint256(validAfter) << 208;
    }

    function _verdictSession(address target, uint256 verdict, uint256 salt)
        internal
        returns (bytes32 pid, address policy)
    {
        policy = address(new FixedVerdictPolicy(verdict));
        pid = _enableDirect(
            _directSession(
                address(validator),
                agentConfig(agentAddr),
                target,
                bytes4(0x11223344),
                policy,
                "",
                bytes32(0xF7000 + salt)
            )
        );
    }

    // ═══════════════════════════════════ W-08 ═══════════════════════════════════

    /// The built operation, pinned field by field through the exact engine calldata: empty
    /// paymaster and init code, zero gas fields and nonce, the wallet as sender, the execute
    /// selector, and `USE ‖ pid ‖ agent` as the signature, with `keccak256(ecd)` as the hash.
    function test_W08_Paymaster_AlwaysEmpty() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();
        PackedUserOperation memory expectedOp = _expectedOp(permissionId, _singleMode(), ecd, agentAddr);

        vm.expectCall(address(engine), abi.encodeCall(ISmartSession.validateUserOp, (expectedOp, keccak256(ecd))));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
    }

    // ═══════════════════════════════════ W-26 ═══════════════════════════════════

    /**
     * W-26 — the built operation's callData selector decides which engine branch runs.
     *
     * When it equals IERC7579Account.execute.selector the engine decodes the mode and calls the
     * action policy through checkSingle7579Exec, forwarding THE REAL DECODED VALUE — which is what
     * URP's gas-value gate compares against. Every other selector falls through to the generic
     * branch, which calls the policy with target = account and a HARDCODED value = 0.
     */
    function test_W26_EngineBranch_SingleExecOnly() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();
        PackedUserOperation memory expectedOp = _expectedOp(permissionId, _singleMode(), ecd, agentAddr);

        assertEq(bytes4(expectedOp.callData), IERC7579Account.execute.selector, "the standard execute selector");
        assertEq(bytes4(expectedOp.callData), bytes4(0xe9ae5c53), "and its literal value");

        vm.expectCall(address(engine), abi.encodeCall(ISmartSession.validateUserOp, (expectedOp, keccak256(ecd))), 1);
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
    }

    /**
     * THE SECOND, INDEPENDENT REASON a zero-value comparison can never be reached: the generic
     * branch derives its action id from (account, selector), finds no policy configured under it,
     * and dies at the engine's minimum-one-policy floor.
     *
     * Demonstrated by driving the REAL engine with a request whose dispatch target is not the
     * gateway: the action id does not match the one configured, so no policy is found.
     */
    function test_W26_UnconfiguredActionDiesAtThePolicyFloor() public {
        bytes memory ecd = ExecutionLib.encodeSingle(makeAddr("someOtherContract"), 0, hex"11223344");

        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(permissionId)));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
    }

    // ═══════════════════════════════════ W-09 ═══════════════════════════════════

    /**
     * W-09 — the agent door is SINGLE-call-type only. Batching lives two layers deeper, inside the
     * multicall payload, bounded by URP's ten.
     *
     * THE GATE IS INDEPENDENTLY REACHABLE, and this test is what proves it. The engine ACCEPTS
     * batch mode — `SmartSession.sol:280-288` routes CALLTYPE_BATCH to `checkBatch7579Exec`, which
     * runs URP per entry, so a well-formed batch of one valid (gateway, sendOutbound) entry passes
     * engine validation cleanly. The ONLY thing standing between it and dispatch is the wallet's
     * mode gate, and it must name its own error.
     */
    function test_W09_AgentDoor_SingleCallTypeOnly() public {
        Execution[] memory entries = new Execution[](1);
        entries[0] = Execution({
            target: GATEWAY, value: 0, callData: outboundRequest(ASSET, 1 ether, 1 ether, address(wallet), _calls())
        });
        bytes memory batchEcd = ExecutionLib.encodeBatch(entries);
        bytes32 batchMode = ModeCode.unwrap(ModeLib.encodeSimpleBatch());

        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        _submitAs(agentAddr, permissionId, batchMode, batchEcd);

        // and BATCH still works on the OWNER door — the restriction is contextual, not global
        Execution[] memory execs = new Execution[](1);
        execs[0] = Execution({ target: makeAddr("sink"), value: 1 ether, callData: "" });
        vm.prank(WALLET_OWNER);
        wallet.execute(batchMode, ExecutionLib.encodeBatch(execs));
        assertEq(makeAddr("sink").balance, 1 ether, "the owner door still batches");
    }

    /**
     * The exotic call types and the try-exec type, each naming the error that actually fires.
     *
     * These do NOT reach the wallet's mode gate: the ENGINE rejects them first, and it names them
     * itself — `UnsupportedExecutionType()` for a non-default exec type, and `UnsupportedCallType`
     * for a call type it does not route. Read from the trace, not assumed.
     */
    function test_W09_ExoticModes_RejectedByTheEngineWithNamedErrors() public {
        bytes memory ecd = _ecd();

        // try-exec type: the engine's own named error (SmartSession.sol:276)
        bytes32 tryMode = bytes32(abi.encodePacked(bytes1(0x00), bytes1(0x01), bytes4(0), bytes4(0), bytes22(0)));
        vm.expectRevert(ISmartSession.UnsupportedExecutionType.selector);
        _submitAs(agentAddr, permissionId, tryMode, ecd);

        // delegatecall and static: neither is a routed call type, so the engine refuses them
        bytes1[2] memory exotic = [bytes1(0xFF), bytes1(0xFE)];
        for (uint256 i; i < exotic.length; ++i) {
            bytes32 mode = bytes32(abi.encodePacked(exotic[i], bytes1(0x00), bytes4(0), bytes4(0), bytes22(0)));
            vm.expectRevert(abi.encodeWithSelector(ISmartSession.UnsupportedCallType.selector, exotic[i]));
            _submitAs(agentAddr, permissionId, mode, ecd);
        }
    }

    // ═══════════════════════════════════ W-28 ═══════════════════════════════════

    /**
     * W-28 — the agent door ALWAYS builds a USE-mode operation. There is no signature input, so no
     * caller can choose ENABLE or UNSAFE_ENABLE: the engine's enable path, which derives a
     * permission from session bytes carried in the signature, is unreachable from this door.
     */
    function test_W28_AgentDoor_AlwaysBuildsUseMode() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();
        PackedUserOperation memory expectedOp = _expectedOp(permissionId, _singleMode(), ecd, agentAddr);
        assertEq(uint8(expectedOp.signature[0]), uint8(SmartSessionMode.USE), "byte 0 is USE");

        PermissionId[] memory before = engine.getPermissionIDs(address(wallet));

        vm.expectCall(address(engine), abi.encodeCall(ISmartSession.validateUserOp, (expectedOp, keccak256(ecd))));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);

        PermissionId[] memory afterIds = engine.getPermissionIDs(address(wallet));
        assertEq(afterIds.length, before.length, "no permission was enabled by the agent door");
        for (uint256 i; i < before.length; ++i) {
            assertEq(PermissionId.unwrap(afterIds[i]), PermissionId.unwrap(before[i]), "the id set is unchanged");
        }
    }

    // ═══════════════════════════════════ W-18 ═══════════════════════════════════

    /**
     * W-18 — an execution revert unwinds EVERYTHING: URP's spent counter and the metering event.
     * This is the atomicity the whole failure model rests on, and it is why dispatch is NEVER
     * wrapped in try/catch.
     */
    function test_W18_ExecutionRevert_UnwindsAll() public {
        // first, a successful request so there is real state to preserve
        _run();
        uint256 spentAfter = _spent();
        assertEq(spentAfter, 1 ether, "spend recorded");

        // now a request whose DISPATCH reverts: the gateway rejects the call
        vm.etch(GATEWAY, type(RevertingGateway).runtimeCode);
        bytes memory ecd = _ecd();

        vm.expectRevert(RevertingGateway.GatewayRejected.selector); // bubbled from the gateway, verbatim
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);

        assertEq(_spent(), spentAfter, "URP's SPENT counter unwound");

        // The EVENTS are unwound with the frame too. Asserted through STATE rather than through
        // vm.getRecordedLogs: forge records logs emitted inside a frame that later reverts, so a
        // log-scanning assertion here would fail against correct behaviour. What actually matters —
        // and what a chain observer would see — is that no counter moved, which is asserted above.
        //
        // The event's absence is then proven positively: the identical request, once the gateway
        // accepts, emits exactly one record and meters exactly once.
        vm.etch(GATEWAY, "");
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));

        vm.expectEmit(true, true, false, true, address(wallet));
        emit IAGW.RulesActionAuthorized(permissionId, agentAddr, keccak256(ecd));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);

        assertEq(_spent(), spentAfter + 1 ether, "the retry metered exactly once");
    }

    // ═══════════════════════════════════ W-23 ═══════════════════════════════════

    /// The agent-door half of the attribution record: the rules set, the agent, and the hash of the
    /// exact calldata executed.
    function test_W23_Events_Attribution_AgentDoor() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();

        vm.expectEmit(true, true, false, true, address(wallet));
        emit IAGW.RulesActionAuthorized(permissionId, agentAddr, keccak256(ecd));

        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
    }

    // ═══════════════════════════════════ W-29 ═══════════════════════════════════

    /**
     * W-29 — THE AGENT DOOR CANNOT REACH THE LIFECYCLE FUNCTIONS. This is what turns "self is
     * reachable only through the owner door" from an argument into a property.
     *
     * `onlyOwnerOrSelf` widens the three lifecycle functions from {owner} to {owner, address(this)}
     * (ruling A). That is safe only if nothing but the owner door can make the wallet call itself.
     * The agent door is the other candidate, and it is refused THREE INDEPENDENT WAYS.
     *
     * WHICH LAYER FIRES DEPENDS ON HOW FAR THE REQUEST GETS, and the ordering was read from traces,
     * not assumed:
     *   (a) a 7579-level dispatch target of the wallet never matches the rules set's one configured
     *       action, so it dies at the engine's minimum-one-policy FLOOR before URP runs;
     *   (b) a request that DOES match the action (target = gateway) but names the wallet as an
     *       INNER multicall target reaches URP gate 14, which forbids it;
     *   (c) with URP bypassed entirely via a non-canonical policy, the engine still refuses an
     *       execute-selector self-target with its own InvalidSelfCall.
     */
    function test_W29_AgentDoor_CannotSelfCall() public {
        // ── (a) the engine's no-policy floor ──
        bytes memory a = ExecutionLib.encodeSingle(address(wallet), 0, abi.encodeCall(AGW.revokeAllRules, ()));
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(permissionId)));
        _submitAs(agentAddr, permissionId, _singleMode(), a);

        // ── (b) URP gate 14: the wallet is a forbidden INNER target ──
        Multicall[] memory selfCalls = new Multicall[](1);
        selfCalls[0] = Multicall({ to: address(wallet), value: 0, data: abi.encodeCall(AGW.revokeAllRules, ()) });
        bytes memory b =
            ExecutionLib.encodeSingle(GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, address(wallet), selfCalls));

        expectUrpGate(abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector, address(wallet)));
        _submitAs(agentAddr, permissionId, _singleMode(), b);

        // ── (c) with URP BYPASSED, the engine's own InvalidSelfCall ──
        // sessionWithPolicy grants a rules set whose action policy is NOT URP — a shape grantRules
        // would refuse — so the gauntlet never runs. The engine still refuses an execute-selector
        // self-target (PolicyLib.sol:196).
        PermissivePolicy permissive = new PermissivePolicy();
        Session memory bypass = sessionWithPolicy(address(permissive), agentConfig(agentAddr), "");
        bypass.actions[0].actionTarget = address(wallet);
        bypass.actions[0].actionTargetSelector = AGW.execute.selector;
        bypass.salt = bytes32(uint256(0xE29));

        Session[] memory arr = new Session[](1);
        arr[0] = bypass;
        vm.prank(address(wallet));
        bytes32 bypassPid = PermissionId.unwrap(engine.enableSessions(arr)[0]);

        // The dispatch calldata must carry the EXECUTE selector for this branch to fire:
        // `PolicyLib.sol:195-198` reverts only when targetSig == IERC7579Account.execute.selector
        // AND target == msg.sender.
        bytes memory c = ExecutionLib.encodeSingle(
            address(wallet),
            0,
            abi.encodeCall(
                AGW.execute,
                (_singleMode(), ExecutionLib.encodeSingle(address(wallet), 0, abi.encodeCall(AGW.revokeAllRules, ())))
            )
        );

        vm.expectRevert(ISmartSession.InvalidSelfCall.selector);
        _submitAs(agentAddr, bypassPid, _singleMode(), c);

        // ── THE POSITIVE CONTROL ──
        // The same revokeRules calldata, through the OWNER door, succeeds via exactly the self-call
        // path the agent door cannot reach. Without this the test could pass against a wallet where
        // self-calls simply never work.
        Execution[] memory batch = new Execution[](1);
        batch[0] =
            Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.revokeRules, (permissionId)) });

        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(batch));

        assertFalse(
            engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(wallet)),
            "the owner's self-call path DOES work - the widening is reachable exactly once"
        );
    }

    // ═══════════════════════ U-12 / U-18, the deferred halves ═══════════════════════

    /// U-12's wallet half: a successful positive-amount request advances URP's counter AND emits
    /// OutboundMetered, through the real engine path.
    function test_U12_MeteringThroughTheRealPath() public {
        etchCallRecorder(GATEWAY);

        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.OutboundMetered(_configId(), address(engine), address(wallet), 3 ether);

        _submitAs(agentAddr, permissionId, _singleMode(), _executionCalldata(3 ether, 0));

        assertEq(_spent(), 3 ether, "spent advanced by exactly the bridged amount");
    }

    /// U-04's wallet half: a zero-amount request PASSES and meters nothing — the redeploy path.
    function test_U04_ZeroAmountThroughTheRealPath() public {
        etchCallRecorder(GATEWAY);

        _submitAs(agentAddr, permissionId, _singleMode(), _executionCalldata(0, 0));

        assertEq(callsRecorded(GATEWAY), 1, "the zero-amount request dispatched");
        assertEq(_spent(), 0, "and metered nothing");
    }

    /// The PC-value path: value decoded from the VALIDATED calldata leaves the wallet's own
    /// balance, bounded by URP gate 8. The agent cannot attach value — this door is not payable.
    function test_AgentRequestMovesPCFromTheWalletsOwnBalance() public {
        etchCallRecorder(GATEWAY);
        uint256 before = address(wallet).balance;

        _submitAs(agentAddr, permissionId, _singleMode(), _executionCalldata(1 ether, 2 ether)); // within 5

        assertEq(address(wallet).balance, before - 2 ether, "PC left the wallet's own balance");
        assertEq(GATEWAY.balance, 2 ether, "and reached the gateway");
    }

    /// Above URP gate 8's ceiling, the request dies and no PC moves.
    function test_PCValueAboveGate8IsRefused() public {
        etchCallRecorder(GATEWAY);
        uint256 before = address(wallet).balance;
        bytes memory ecd = _executionCalldata(1 ether, 6 ether); // maxPCPerCall is 5 ether

        // URP gate 8 fired, named through the engine's 32-byte rewrap.
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.PCValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)
            )
        );
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);

        assertEq(address(wallet).balance, before, "no PC moved");
    }

    // ═══════════════════════════ door-level guards ═══════════════════════════

    /// W-22's agent half: a wallet with NO rules sets refuses every agent request — no id names an
    /// agent there, so the wallet's pre-check fires before the engine is ever called.
    function test_W22_EmptyWallet_RejectsAgents_AgentHalf() public {
        AGW fresh = newWallet(WALLET_OWNER);
        vm.deal(address(fresh), 10 ether);
        bytes memory ecd = _ecd();

        vm.prank(agentAddr);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agentAddr));
        fresh.executeAsAgent(permissionId, _singleMode(), ecd);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, bytes32(0), RELAYER));
        fresh.executeAsAgent(bytes32(0), _singleMode(), ecd);
    }

    function test_W_agentDoor_unknownPermission_refused() public {
        bytes32 unknown = keccak256("never granted");
        bytes memory ecd = _ecd();

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, unknown, agentAddr));
        _submitAs(agentAddr, unknown, _singleMode(), ecd);
    }

    function test_W_agentDoor_revokedPermission_refused() public {
        bytes memory ecd = _ecd();

        vm.prank(WALLET_OWNER);
        wallet.revokeRules(permissionId);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agentAddr));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);

        bytes32 pid1 = _grant();
        bytes32 pid2 = _grant();
        vm.prank(WALLET_OWNER);
        wallet.revokeAllRules();

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid1, agentAddr));
        _submitAs(agentAddr, pid1, _singleMode(), ecd);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid2, agentAddr));
        _submitAs(agentAddr, pid2, _singleMode(), ecd);
    }

    /// Uninstalling the engine (after revoking everything) switches the agent door off entirely; the
    /// installed check fires before the agent check.
    function test_W_agentDoor_engineUninstalled_refused() public {
        bytes memory ecd = _ecd();

        vm.startPrank(WALLET_OWNER);
        wallet.revokeAllRules();
        wallet.uninstallModule(1, address(engine), "");
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ValidatorNotInstalled.selector, address(engine)));
        _submitAs(agentAddr, permissionId, _singleMode(), ecd);
    }

    /// A session the owner enabled on the engine directly, naming a session validator other than the
    /// canonical one, has no agent here — even with a well-formed agent config and URP as its policy.
    function test_W_agentDoor_foreignValidatorSessionHasNoAgent() public {
        AgentValidator other = new AgentValidator();
        Session memory s = canonicalSession(agentConfig(agentAddr), _urpInitData());
        s.sessionValidator = ISessionValidator(address(other));
        s.salt = bytes32(uint256(0xF0));
        bytes32 pid = _enableDirect(s);

        assertEq(wallet.agentOf(pid), address(0), "a non-canonical validator names no agent");

        bytes memory ecd = _ecd();
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid, agentAddr));
        _submitAs(agentAddr, pid, _singleMode(), ecd);
    }

    /// A session enabled directly with the CANONICAL validator but a pre-D3 config: the engine
    /// accepts it — at enable it checks only `isModuleType(7)`, never the config
    /// (`ConfigLib.sol:207-213`) — and the wallet reads no agent from it.
    function test_W_agentDoor_malformedConfigSessionHasNoAgent() public {
        Session memory s = canonicalSession(abi.encode(uint8(0), abi.encodePacked(agentAddr)), _urpInitData());
        s.salt = bytes32(uint256(0xF1));
        bytes32 pid = _enableDirect(s);

        assertEq(wallet.agentOf(pid), address(0), "a malformed config names no agent");

        bytes memory ecd = _ecd();
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid, agentAddr));
        _submitAs(agentAddr, pid, _singleMode(), ecd);
    }

    // ═══════════════════ the owner-intent doors (UniversalMarketplace PRD, C and D) ═══════════════════

    /// ⚠️ NEVER-DELETE. Owner lanes belong to `executeWithSig`: the agent door can neither read nor
    ///      advance any lane, and the owner lane still works at the recorded position afterwards.
    function test_W_agentDoor_neverTouchesOwnerLanes() public {
        uint192 laneA = OWNER_LANE_FLAG;
        uint192 laneB = OWNER_LANE_FLAG | 7;
        uint64 seqA = wallet.getNonce(laneA);
        uint64 seqB = wallet.getNonce(laneB);
        uint64 seq0 = wallet.getNonce(0);

        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();
        for (uint256 i; i < 3; ++i) {
            _submitAs(agentAddr, permissionId, _singleMode(), ecd);
        }
        bytes memory overCap = _executionCalldata(1 ether, 6 ether);
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.PCValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)
            )
        );
        _submitAs(agentAddr, permissionId, _singleMode(), overCap);

        assertEq(wallet.getNonce(laneA), seqA, "owner lane A untouched");
        assertEq(wallet.getNonce(laneB), seqB, "owner lane B untouched");
        assertEq(wallet.getNonce(0), seq0, "lane 0 untouched");

        address sink = makeAddr("laneSink");
        bytes memory ownerEcd = ExecutionLib.encodeSingle(sink, 1 ether, "");
        OwnerIntent memory intent = blankIntent(WALLET_OWNER, address(wallet), RELAYER);
        intent.mode = _singleMode();
        intent.execCalldataHash = keccak256(ownerEcd);
        intent.nonceKey = laneA;
        intent.nonceSeq = seqA;
        bytes memory sig = signIntent(walletOwnerPk, intent);

        vm.prank(RELAYER);
        wallet.executeWithSig(_singleMode(), ownerEcd, intent, sig);

        assertEq(sink.balance, 1 ether, "the owner lane works at the recorded position");
        assertEq(wallet.getNonce(laneA), seqA + 1, "and advanced exactly once");
    }

    /**
     * ⚠️ NEVER-DELETE. Owner authority and agent authority never cross:
     *   (a) the agent's key signing an OwnerIntent, presented by the agent as `intent.executor`, is
     *       refused `InvalidOwnerSignature` — the agent is not the owner;
     *   (b) the OWNER calling the agent door is refused `CallerIsNotAgent` — owner authority never
     *       passes as agent authority.
     */
    function test_X17_ownerIntentSigNeverValidatesAsSessionSig() public {
        bytes memory ecd = _ecd();

        OwnerIntent memory i = blankIntent(WALLET_OWNER, address(wallet), agentAddr);
        i.mode = _singleMode();
        i.execCalldataHash = keccak256(ecd);
        bytes memory agentSig = signIntent(agentPk, i);

        vm.prank(agentAddr);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        wallet.executeWithSig(_singleMode(), ecd, i, agentSig);

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, WALLET_OWNER));
        _submitAs(WALLET_OWNER, permissionId, _singleMode(), ecd);
    }

    /// ⚠️ NEVER-DELETE. Neither new door is reachable from the agent side:
    ///   (a) at grant, the wallet is never a grantable native target, whatever the selector;
    ///   (b) at dispatch, with URP bypassed by a session enabled directly on the engine, the dispatch
    ///       guard refuses `address(this)` — selector-independent, so it covers both new doors.
    function test_W_agentDoorCannotReach_grantMandateWithSig() public {
        bytes4[2] memory sels = [AGW.grantRulesWithSig.selector, AGW.executeWithSig.selector];
        for (uint256 k; k < 2; ++k) {
            // (a) grant time
            Session memory s = sessionWithPolicy(address(urp), agentConfig(agentAddr), envelope(nativeChain(), ""));
            s.actions[0].actionTarget = address(wallet);
            s.actions[0].actionTargetSelector = sels[k];
            vm.prank(WALLET_OWNER);
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenActionTarget.selector, address(wallet)));
            wallet.grantRules(s);

            // (b) dispatch time
            PermissivePolicy permissive = new PermissivePolicy();
            Session memory bypass = sessionWithPolicy(address(permissive), agentConfig(agentAddr), "");
            bypass.actions[0].actionTarget = address(wallet);
            bypass.actions[0].actionTargetSelector = sels[k];
            bypass.salt = bytes32(uint256(0xC0DE + k));
            Session[] memory arr = new Session[](1);
            arr[0] = bypass;
            vm.prank(address(wallet));
            bytes32 bypassPid = PermissionId.unwrap(engine.enableSessions(arr)[0]);

            bytes memory ecd = ExecutionLib.encodeSingle(address(wallet), 0, abi.encodePacked(sels[k], bytes32(0)));
            vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenDispatchTarget.selector, address(wallet)));
            _submitAs(agentAddr, bypassPid, _singleMode(), ecd);
        }
    }

    // ═══════════════════════════════════ agentOf ═══════════════════════════════════

    function test_agentOf_lifecycle() public {
        assertEq(wallet.agentOf(permissionId), agentAddr, "the granted agent");

        address agentB = makeAddr("agentB");
        bytes32 pidB = _grantFor(agentB);
        assertEq(wallet.agentOf(pidB), agentB, "each rules set names its own agent");
        assertEq(wallet.agentOf(permissionId), agentAddr, "and the first is unchanged");

        vm.prank(WALLET_OWNER);
        wallet.revokeRules(permissionId);
        assertEq(wallet.agentOf(permissionId), address(0), "revoked: no agent");
        assertEq(wallet.agentOf(pidB), agentB, "the other rules set still names its agent");

        assertEq(wallet.agentOf(bytes32(0)), address(0), "the zero id");
        assertEq(wallet.agentOf(keccak256("random")), address(0), "a random id");
    }

    function test_agentOf_viaGrantMandateWithSig() public {
        address agentB = makeAddr("agentB");
        Session memory s = canonicalSession(agentConfig(agentB), _urpInitData());

        OwnerIntent memory i = blankIntent(WALLET_OWNER, address(wallet), RELAYER);
        i.sessionHash = keccak256(abi.encode(s));
        i.grantNonce = wallet.grantNonce();
        bytes memory sig = signIntent(walletOwnerPk, i);

        vm.prank(RELAYER);
        bytes32 pid = wallet.grantRulesWithSig(s, i, sig);
        assertEq(wallet.agentOf(pid), agentB, "a signed grant names its agent");

        etchCallRecorder(GATEWAY);
        _submitAs(agentB, pid, _singleMode(), _ecd());
        assertEq(_spentOf(pid), 1 ether, "and that agent can act");
    }

    // ═══════════════════════════════════ gas ═══════════════════════════════════

    function test_gas_executeAsAgent_universalHappyPath() public {
        etchCallRecorder(GATEWAY);
        bytes memory ecd = _ecd();
        bytes32 mode = _singleMode();

        _submitAs(agentAddr, permissionId, mode, ecd); // warm the wallet, engine and URP rows

        vm.prank(agentAddr);
        uint256 before = gasleft();
        wallet.executeAsAgent(permissionId, mode, ecd);
        uint256 used = before - gasleft();

        emit log_named_uint("executeAsAgent universal steady-state gas", used);
        uint256 budget = _isolated() ? AGENT_DOOR_GAS_BUDGET_ISOLATED : AGENT_DOOR_GAS_BUDGET;
        assertLt(used, budget, "agent door gas within its measured budget");
    }

    /// @dev Whether top-level calls run as separate transactions (`--isolate`). A plain call to an empty
    ///      account then costs at least the 21,000 intrinsic gas; otherwise it costs a few thousand.
    function _isolated() internal returns (bool) {
        address probe = makeAddr("isolationProbe");
        uint256 before = gasleft();
        (bool ok,) = probe.call("");
        uint256 cost = before - gasleft();
        assertTrue(ok, "a call to an empty account succeeds");
        return cost >= 21_000;
    }
}

// ─────────────────────────────── test doubles ───────────────────────────────

contract RevertingGateway {
    error GatewayRejected();

    fallback() external payable {
        revert GatewayRejected();
    }

    receive() external payable {
        revert GatewayRejected();
    }
}

/// @dev An action policy that permits everything. Used ONLY to BYPASS URP in W-29(c) and the
///      dispatch-guard test, so the engine's and wallet's own refusals are reachable and provable on
///      their own. It is never used to establish that something is allowed.
contract PermissivePolicy {
    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    /// @dev The engine calls this during enableSessions; it must not revert.
    function initializeWithMultiplexer(address, ConfigId, bytes calldata) external { }

    /// @dev The engine gates enablement on this via OZ's ERC165Checker (`ConfigLib.sol:16,29`),
    ///      which requires IERC165 => true AND 0xffffffff => FALSE. A blanket `return true` fails
    ///      that check — the invalid-id probe is exactly what ERC165Checker uses to detect a
    ///      contract that answers everything.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        if (id == 0xffffffff) return false;
        return id == type(IERC165).interfaceId || id == type(IActionPolicy).interfaceId;
    }

    /// @dev VALIDATION_SUCCESS for anything. This exists ONLY so W-29(c) can reach the engine's own
    ///      InvalidSelfCall with URP out of the way. It never establishes that something is allowed.
    function checkAction(ConfigId, address, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

/// @dev An action policy that returns a fixed validation-data word. Observer, never oracle: it
///      supplies only the verdict whose ENFORCEMENT by the wallet is under test.
contract FixedVerdictPolicy {
    uint256 public immutable VERDICT;

    constructor(uint256 verdict) {
        VERDICT = verdict;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    /// @dev The engine calls this during enableSessions; it must not revert.
    function initializeWithMultiplexer(address, ConfigId, bytes calldata) external { }

    function checkAction(ConfigId, address, address, uint256, bytes calldata) external view returns (uint256) {
        return VERDICT;
    }

    /// @dev Same ERC-165 shape as `PermissivePolicy`: OZ's ERC165Checker requires 0xffffffff => false.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        if (id == 0xffffffff) return false;
        return id == type(IERC165).interfaceId || id == type(IActionPolicy).interfaceId;
    }
}

/// @dev A native target that re-enters the wallet's agent door from inside the dispatched call.
contract ReenteringTarget {
    function poke(address wallet, bytes32 pid, bytes32 mode, bytes calldata ecd) external {
        AGW(payable(wallet)).executeAsAgent(pid, mode, ecd);
    }
}
