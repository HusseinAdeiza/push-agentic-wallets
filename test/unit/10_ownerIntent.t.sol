// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";

import { AGW } from "../../src/AGW.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";

import { AGWErrors } from "../../src/libraries/Errors.sol";

import { ModeLib, ModeCode, CallType, ExecType, ModeSelector, ModePayload } from "../../src/libraries/ModeLib.sol";

import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";

import { AllowedCall, Config, OWNER_LANE_FLAG, OwnerIntent, RulesType } from "../../src/libraries/Types.sol";

import { Session, PermissionId, PolicyData, ActionData } from "smartsessions/DataTypes.sol";

import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

import { MockUEA } from "../mocks/MockUEA.sol";

/// @dev A target that records who called it.
contract CallerProbe {
    address public lastCaller;
    uint256 public calls;

    function ping() external {
        lastCaller = msg.sender;
        calls++;
    }

    function boom() external pure {
        revert("boom");
    }
}

/// @dev Re-enters `executeWithSig` on the wallet that called it.
contract ReentrantTarget {
    function reenter(AGW w, bytes32 mode, bytes calldata cd, OwnerIntent calldata i, bytes calldata sig) external {
        w.executeWithSig(mode, cd, i, sig);
    }
}

/**
 * @title  AGW — the owner-intent doors (Changes C and D of the UniversalMarketplace PRD).
 * @notice G-series: `grantRulesWithSig`. X-series: `executeWithSig`.
 *
 * @dev    The owner is a real EOA key here (and a MockUEA where named), so every signature is really
 *         made and really verified. The digest is BaseTest's hand-built witness, never the library.
 */
contract PushAgentWalletOwnerIntentTest is BaseTest {
    AGW internal wallet;
    address internal ownerAddr;
    uint256 internal ownerPk;
    address internal EXECUTOR;
    address internal agentAddr;
    address internal ASSET;
    address internal PROTOCOL;
    address internal CEA;
    CallerProbe internal probe;

    function setUp() public override {
        super.setUp();
        (ownerAddr, ownerPk) = ecdsaKey("intentOwner");
        (agentAddr,) = ecdsaKey("agentKey");
        EXECUTOR = makeAddr("marketplace");
        ASSET = address(new MockPRC20());
        PROTOCOL = makeAddr("protocol");
        CEA = makeAddr("cea");
        probe = new CallerProbe();
        vm.warp(1_000_000_000);
        wallet = newWallet(ownerAddr);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _session() internal view returns (Session memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: bytes4(keccak256("swap(uint256,address)")),
            beneficiaryOffset: 36,
            hasBeneficiary: true,
            maxValue: 0
        });
        return canonicalSession(
            ecdsaConfig(agentAddr),
            universalInitData(
                Config({
                    initialized: false,
                    validUntil: uint48(block.timestamp + 30 days),
                    destChainHash: bytes32(0),
                    expectedCEA: CEA,
                    asset: ASSET,
                    maxAmountPerCall: 100e6,
                    maxAmountTotal: 100e6,
                    maxPCPerCall: 1 ether,
                    spent: 0,
                    allowedCalls: rules
                })
            )
        );
    }

    function _grantIntent(AGW w, address owner_, Session memory s) internal view returns (OwnerIntent memory i) {
        i = blankIntent(owner_, address(w), EXECUTOR);
        i.sessionHash = keccak256(abi.encode(s));
        i.grantNonce = w.grantNonce();
    }

    function _single() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _batch() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleBatch());
    }

    function _pingCalldata() internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(probe), 0, abi.encodeCall(CallerProbe.ping, ()));
    }

    function _execIntent(bytes32 mode, bytes memory cd) internal view returns (OwnerIntent memory i) {
        i = blankIntent(ownerAddr, address(wallet), EXECUTOR);
        i.mode = mode;
        i.execCalldataHash = keccak256(cd);
        i.nonceKey = OWNER_LANE_FLAG;
        i.nonceSeq = wallet.getNonce(OWNER_LANE_FLAG);
    }

    function _grantWithSig(Session memory s, OwnerIntent memory i, bytes memory sig) internal returns (bytes32) {
        vm.prank(EXECUTOR);
        return wallet.grantRulesWithSig(s, i, sig);
    }

    function _execWithSig(bytes32 mode, bytes memory cd, OwnerIntent memory i, bytes memory sig) internal {
        vm.prank(EXECUTOR);
        wallet.executeWithSig(mode, cd, i, sig);
    }

    // ════════════════════════════ G — grantRulesWithSig ════════════════════════════

    function test_G01_grantWithIntent_relayerSubmits_mandateGranted() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes32 pid = _grantWithSig(s, i, signIntent(ownerPk, i));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
        assertEq(wallet.grantNonce(), 1);
    }

    function test_G02_grantWithIntent_ueaOwner() public {
        MockUEA uea = new MockUEA(ownerAddr);
        AGW w = newWallet(address(uea));
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(w, address(uea), s);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(EXECUTOR);
        bytes32 pid = w.grantRulesWithSig(s, i, sig);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(w)));
    }

    function test_G03_replay_revertsIntentGrantNonceMismatch() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        _grantWithSig(s, i, sig);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentGrantNonceMismatch.selector, uint64(1), uint64(0)));
        _grantWithSig(s, i, sig);
    }

    function test_G04_tamperedSession_revertsIntentSessionMismatch() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        s.sessionValidatorInitData = ecdsaConfig(makeAddr("attackerKey"));
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentSessionMismatch.selector, keccak256(abi.encode(s))));
        _grantWithSig(s, i, sig);
    }

    function test_G05_zeroSessionHash_reverts() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        i.sessionHash = bytes32(0);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentSessionMismatch.selector, keccak256(abi.encode(s))));
        _grantWithSig(s, i, sig);
    }

    function test_G06_expired() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        vm.warp(uint256(i.deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.OwnerSigExpired.selector, i.deadline));
        _grantWithSig(s, i, sig);
    }

    function test_G07_wrongWalletField() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        i.wallet = address(0xdead);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.IntentWalletMismatch.selector, address(wallet), address(0xdead))
        );
        _grantWithSig(s, i, sig);
    }

    function test_G08_wrongOwnerField_revertsNotOwner() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, makeAddr("notTheOwner"), s);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        _grantWithSig(s, i, sig);
    }

    function test_G09_wrongSigner() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        (, uint256 otherPk) = ecdsaKey("other");
        bytes memory sig = signIntent(otherPk, i);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _grantWithSig(s, i, sig);
    }

    /// @dev The FACTORY's domain is the one in force — a signature under the wallet's address fails.
    function test_G10_signedUnderWalletDomain_reverts() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntentFor(address(wallet), ownerPk, i);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _grantWithSig(s, i, sig);
    }

    /// ⚠️ NEVER-DELETE. Only the intent's executor may present it.
    function test_G15_wrongExecutor_revertsExecutorMismatch() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ExecutorMismatch.selector, EXECUTOR, RELAYER));
        wallet.grantRulesWithSig(s, i, sig);
    }

    function test_G15b_zeroExecutor_revertsExecutorMismatch() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        i.executor = address(0);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ExecutorMismatch.selector, address(0), address(0)));
        wallet.grantRulesWithSig(s, i, sig);
    }

    function test_G16_wrongSignerChainId() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        i.signerChainId = 11_155_111;
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _grantWithSig(s, i, sig);
    }

    /// @dev Every shape rule `grantRules` enforces, through the signature door, with the same error.
    function test_G11_runsSameShapeChecks() public {
        // userOpPolicies present
        Session memory s1 = _session();
        s1.userOpPolicies = new PolicyData[](1);
        _expectShapeError(s1, abi.encodeWithSelector(AGWErrors.MalformedSessionShape.selector));

        // no actions
        Session memory s2 = _session();
        s2.actions = new ActionData[](0);
        _expectShapeError(s2, abi.encodeWithSelector(AGWErrors.TooManyActions.selector, uint256(0)));

        // universal mandate aimed at a non-gateway target
        Session memory s3 = _session();
        s3.actions[0].actionTarget = address(probe);
        _expectShapeError(
            s3,
            abi.encodeWithSelector(
                AGWErrors.RulesTypeMismatch.selector, RulesType.UNIVERSAL, uint256(0), address(probe)
            )
        );

        // empty chain string
        Session memory s4 = _session();
        s4.actions[0].actionPolicies[0].initData = abi.encode("", bytes(""));
        _expectShapeError(s4, abi.encodeWithSelector(AGWErrors.EmptyChain.selector));

        // non-canonical validator
        Session memory s5 = _session();
        s5.sessionValidator = ISessionValidator(address(0xBAD));
        _expectShapeError(s5, abi.encodeWithSelector(AGWErrors.MalformedSessionShape.selector));
    }

    function _expectShapeError(Session memory s, bytes memory err) internal {
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes memory sig = signIntent(ownerPk, i);
        // the owner path refuses it identically …
        vm.prank(ownerAddr);
        vm.expectRevert(err);
        wallet.grantRules(s);
        // … and so does the signature path
        vm.prank(EXECUTOR);
        vm.expectRevert(err);
        wallet.grantRulesWithSig(s, i, sig);
    }

    function test_G12_permissionIdEqualsOwnerPath() public {
        Session memory s = _session();
        uint256 snap = vm.snapshotState();
        vm.prank(ownerAddr);
        bytes32 viaOwner = wallet.grantRules(s);
        vm.revertToState(snap);
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        bytes32 viaSig = _grantWithSig(s, i, signIntent(ownerPk, i));
        assertEq(viaSig, viaOwner);
    }

    function test_G13_execFieldsIgnoredHere() public {
        Session memory s = _session();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        i.execCalldataHash = keccak256("whatever");
        i.nonceSeq = 999;
        i.nonceKey = 0;
        _grantWithSig(s, i, signIntent(ownerPk, i));
        assertEq(wallet.grantNonce(), 1);
    }

    function test_G14_ownerBatchViaSelf_stillWorks() public {
        vm.prank(ownerAddr);
        bytes32 oldPid = wallet.grantRules(_session());
        Execution[] memory batch = new Execution[](2);
        batch[0] = Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.revokeRules, (oldPid)) });
        batch[1] =
            Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.grantRules, (_session())) });
        vm.prank(ownerAddr);
        wallet.execute(_batch(), ExecutionLib.encodeBatch(batch));
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(oldPid), address(wallet)));
        assertEq(wallet.grantNonce(), 2);
    }

    // ════════════════════════════ X — executeWithSig ════════════════════════════

    function test_X01_single() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        vm.expectEmit(address(wallet));
        emit IAGW.OwnerExecutedWithSig(_single(), keccak256(cd), OWNER_LANE_FLAG, 0);
        _execWithSig(_single(), cd, i, signIntent(ownerPk, i));
        assertEq(probe.lastCaller(), address(wallet));
        assertEq(wallet.getNonce(OWNER_LANE_FLAG), 1);
    }

    function test_X02_batch_inOrder() public {
        Execution[] memory b = new Execution[](2);
        b[0] = Execution({ target: address(probe), value: 0, callData: abi.encodeCall(CallerProbe.ping, ()) });
        b[1] = Execution({ target: address(probe), value: 0, callData: abi.encodeCall(CallerProbe.ping, ()) });
        bytes memory cd = ExecutionLib.encodeBatch(b);
        OwnerIntent memory i = _execIntent(_batch(), cd);
        _execWithSig(_batch(), cd, i, signIntent(ownerPk, i));
        assertEq(probe.calls(), 2);
    }

    /// @dev Owner-equivalence: a batch entry may call the wallet's own lifecycle function via self.
    function test_X03_batch_selfCall_grantMandate_works() public {
        Execution[] memory b = new Execution[](1);
        b[0] = Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.grantRules, (_session())) });
        bytes memory cd = ExecutionLib.encodeBatch(b);
        OwnerIntent memory i = _execIntent(_batch(), cd);
        _execWithSig(_batch(), cd, i, signIntent(ownerPk, i));
        assertEq(wallet.grantNonce(), 1);
    }

    function test_X04_nonOwnerLane() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        i.nonceKey = 5;
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.OwnerLaneRequired.selector, uint192(5)));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X05_wrongSeq() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        i.nonceSeq = 3;
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.InvalidNonce.selector, OWNER_LANE_FLAG, uint64(0), uint64(3)));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X06_replay() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        _execWithSig(_single(), cd, i, sig);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.InvalidNonce.selector, OWNER_LANE_FLAG, uint64(1), uint64(0)));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X07_expired() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.warp(uint256(i.deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.OwnerSigExpired.selector, i.deadline));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X08_wrongSigner() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        (, uint256 otherPk) = ecdsaKey("other");
        bytes memory sig = signIntent(otherPk, i);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X09_tamperedCalldata() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        bytes memory other = ExecutionLib.encodeSingle(address(probe), 0, abi.encodeCall(CallerProbe.boom, ()));
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentExecMismatch.selector, keccak256(other)));
        _execWithSig(_single(), other, i, sig);
    }

    function test_X10_tamperedMode() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentExecMismatch.selector, keccak256(cd)));
        _execWithSig(_batch(), cd, i, sig);
    }

    function test_X11_zeroExecHash() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        i.execCalldataHash = bytes32(0);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentExecMismatch.selector, keccak256(cd)));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X12_wrongWalletField() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        i.wallet = address(0xdead);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.IntentWalletMismatch.selector, address(wallet), address(0xdead))
        );
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X13_wrongPushChainSalt() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.chainId(42_101);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X14_signedUnderWalletDomain() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntentFor(address(wallet), ownerPk, i);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _execWithSig(_single(), cd, i, sig);
    }

    /// ⚠️ NEVER-DELETE. Only the intent's executor may present it.
    function test_X22_wrongExecutor_revertsExecutorMismatch() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ExecutorMismatch.selector, EXECUTOR, RELAYER));
        wallet.executeWithSig(_single(), cd, i, sig);
    }

    function test_X23_wrongSignerChainId() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        i.signerChainId = 137;
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X15_unsupportedExecType() public {
        bytes32 tryMode = ModeCode.unwrap(
            ModeLib.encode(CallType.wrap(0x00), ExecType.wrap(0x01), ModeSelector.wrap(bytes4(0)), ModePayload.wrap(0))
        );
        bytes32 delegateMode = ModeCode.unwrap(
            ModeLib.encode(CallType.wrap(0xFF), ExecType.wrap(0x00), ModeSelector.wrap(bytes4(0)), ModePayload.wrap(0))
        );
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(tryMode, cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        _execWithSig(tryMode, cd, i, sig);

        OwnerIntent memory j = _execIntent(delegateMode, cd);
        sig = signIntent(ownerPk, j);
        vm.expectRevert(AGWErrors.UnsupportedExecutionMode.selector);
        _execWithSig(delegateMode, cd, j, sig);
    }

    function test_X16_targetRevert_bubbles_andNonceUnwinds() public {
        bytes memory cd = ExecutionLib.encodeSingle(address(probe), 0, abi.encodeCall(CallerProbe.boom, ()));
        OwnerIntent memory i = _execIntent(_single(), cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(bytes("boom"));
        _execWithSig(_single(), cd, i, sig);
        assertEq(wallet.getNonce(OWNER_LANE_FLAG), 0, "the nonce write unwound with the revert");
    }

    /// ⚠️ NEVER-DELETE. The same key signing an agent op hash cannot pass as the owner.
    function test_X18_sessionSigNeverValidatesAsOwnerIntent() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        // the ten-field agent op hash for the same calldata, signed by the OWNER's key
        bytes32 opHash = keccak256(
            abi.encode(
                keccak256("AGW.Op.v3"),
                block.chainid,
                address(wallet),
                address(engine),
                bytes32(uint256(1)),
                _single(),
                keccak256(cd),
                uint192(0),
                uint64(0),
                uint48(0)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, opHash);
        vm.expectRevert(AGWErrors.InvalidOwnerSignature.selector);
        _execWithSig(_single(), cd, i, abi.encodePacked(r, s, v));
    }

    function test_X19_grantFieldsIgnoredHere() public {
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _execIntent(_single(), cd);
        i.sessionHash = keccak256("nope");
        i.grantNonce = 42;
        _execWithSig(_single(), cd, i, signIntent(ownerPk, i));
        assertEq(probe.calls(), 1);
    }

    /// @dev THE BUNDLE PROPERTY: one intent, one signature, serves grant then exec; then each replay
    ///      fails on its own nonce.
    function test_X20_sameIntent_servesGrantThenExec() public {
        Session memory s = _session();
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = _grantIntent(wallet, ownerAddr, s);
        i.mode = _single();
        i.execCalldataHash = keccak256(cd);
        i.nonceKey = OWNER_LANE_FLAG;
        i.nonceSeq = 0;
        uint256 before = intentSignatures;
        bytes memory sig = signIntent(ownerPk, i);
        assertEq(intentSignatures - before, 1, "exactly one signature");

        _grantWithSig(s, i, sig);
        _execWithSig(_single(), cd, i, sig);
        assertEq(wallet.grantNonce(), 1);
        assertEq(probe.calls(), 1);

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.IntentGrantNonceMismatch.selector, uint64(1), uint64(0)));
        _grantWithSig(s, i, sig);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.InvalidNonce.selector, OWNER_LANE_FLAG, uint64(1), uint64(0)));
        _execWithSig(_single(), cd, i, sig);
    }

    function test_X21_reentrancyGuarded() public {
        ReentrantTarget rt = new ReentrantTarget();
        bytes memory inner = _pingCalldata();
        OwnerIntent memory innerI = _execIntent(_single(), inner);
        innerI.executor = address(rt);
        innerI.nonceSeq = 1;
        bytes memory innerSig = signIntent(ownerPk, innerI);

        bytes memory outer = ExecutionLib.encodeSingle(
            address(rt), 0, abi.encodeCall(ReentrantTarget.reenter, (wallet, _single(), inner, innerI, innerSig))
        );
        OwnerIntent memory i = _execIntent(_single(), outer);
        bytes memory sig = signIntent(ownerPk, i);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        _execWithSig(_single(), outer, i, sig);
    }

    function test_X24_ueaOwner_executes() public {
        MockUEA uea = new MockUEA(ownerAddr);
        AGW w = newWallet(address(uea));
        bytes memory cd = _pingCalldata();
        OwnerIntent memory i = blankIntent(address(uea), address(w), EXECUTOR);
        i.mode = _single();
        i.execCalldataHash = keccak256(cd);
        bytes memory sig = signIntent(ownerPk, i);
        vm.prank(EXECUTOR);
        w.executeWithSig(_single(), cd, i, sig);
        assertEq(probe.lastCaller(), address(w));
    }

    function test_intentDomainSeparator_equalsFactory() public view {
        assertEq(wallet.domainSeparator(1), factory.domainSeparator(1));
    }
}
