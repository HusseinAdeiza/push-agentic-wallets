// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { IPushAgentWallet } from "../../src/interfaces/IPushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";
import { Session, PermissionId, ConfigId, SmartSessionMode } from "smartsessions/DataTypes.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";
import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

/**
 * @notice PushAgentWallet — Phase 3c: the agent door.
 *
 * @dev    Every test here drives the REAL path: real engine, real UCEP, real validator, real
 *         signatures. Nothing is mocked except where a test needs a specific failure the real
 *         components cannot produce (a verdict-returning validator for W-07, a reverting target for
 *         W-18) — and those are OBSERVERS of the wallet's reaction, never oracles for the
 *         behaviour under test.
 *
 * @dev    EXACTLY ONE selector-less `vm.expectRevert()` exists in this file, and it is bare by
 *         construction: `test_W03_OpHash_Field6_MalformedBatchShapeIsRejected`, where the ENGINE's
 *         batch decoder rejects a shape mismatch and reverts WITHOUT DATA. Every other negative
 *         test names its error, because a bare assertion cannot distinguish "the signature rejected
 *         the flipped hash" from "the request was malformed some other way" — a distinction that
 *         already hid one real coverage gap in this file (see W-09).
 *
 *         The recurring named expectations, and what each proves:
 *           · `ValidationFailed(address(1))` — a SIGNATURE-level rejection. The engine returns a
 *             failure verdict rather than reverting; the wallet converts it. This is the expectation
 *             for every W-03 field flip.
 *           · `InvalidPermissionId(pid)`     — the engine does not know that mandate (revoked, or
 *             never granted on this wallet).
 *           · `NoPoliciesSet(pid)`           — the engine's minimum-one-policy floor.
 *           · `expectUcepGate(...)`          — a UCEP gate, seen through the engine's 32-byte
 *             rewrap as `PolicyCheckReverted`. Names WHICH gate fired.
 */
contract PushAgentWalletAgentDoorTest is BaseTest {
    PushAgentWallet internal wallet;
    address internal WALLET_OWNER;

    address internal agentAddr;
    uint256 internal agentPk;

    address internal CEA;
    address internal PROTOCOL;
    address internal ASSET;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));
    uint16 internal constant BENEFICIARY_OFFSET = 36;

    bytes32 internal permissionId;

    function setUp() public override {
        super.setUp();
        WALLET_OWNER = makeAddr("walletOwner");
        (agentAddr, agentPk) = ecdsaKey("agentSigner");

        CEA = makeAddr("destinationAccount");
        PROTOCOL = makeAddr("farChainProtocol");
        ASSET = makeAddr("prc20");

        vm.warp(1_000_000_000);

        wallet = newWallet(WALLET_OWNER);
        vm.deal(address(wallet), 100 ether);

        permissionId = _grant();
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _ucepInitData() internal view returns (bytes memory) {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
        return abi.encode(
            IUCEP.Config({
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
        vm.prank(WALLET_OWNER);
        return wallet.grantMandate(canonicalSession(ecdsaConfig(agentAddr), _ucepInitData()));
    }

    function _calls() internal view returns (Multicall[] memory c) {
        c = new Multicall[](1);
        c[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) });
    }

    /// @dev The wallet-level executionCalldata: a SINGLE call to the gateway carrying a valid
    ///      outbound request. This is the exact shape UCEP's gauntlet is built to police.
    function _executionCalldata(uint256 amount, uint256 pcValue) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            GATEWAY, pcValue, outboundRequest(ASSET, amount, 1 ether, address(wallet), _calls())
        );
    }

    function _singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    struct Req {
        address validator;
        bytes32 mode;
        bytes executionCalldata;
        uint192 nonceKey;
        uint64 nonceSeq;
        uint48 requestExpiry;
        bytes32 pid;
    }

    function _defaultReq() internal view returns (Req memory r) {
        r.validator = address(engine);
        r.mode = _singleMode();
        r.executionCalldata = _executionCalldata(1 ether, 0);
        r.nonceKey = 0;
        r.nonceSeq = 0;
        r.requestExpiry = 0;
        r.pid = permissionId;
    }

    /// @dev The ten-field hash, recomputed INDEPENDENTLY of the contract, so a test that signs is
    ///      asserting the contract's layout rather than inheriting it.
    function _opHash(Req memory r) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
                block.chainid,
                address(wallet),
                r.validator,
                r.pid,
                r.mode,
                keccak256(r.executionCalldata),
                r.nonceKey,
                r.nonceSeq,
                r.requestExpiry
            )
        );
    }

    /// @dev Sign the ten-field hash and wrap it in the engine's USE-mode wire format:
    ///      mode byte ‖ permissionId ‖ sessionSig (EncodeLib.sol:29-37).
    function _signed(Req memory r) internal view returns (bytes memory) {
        bytes32 h = _opHash(r);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(agentPk, h);
        return abi.encodePacked(uint8(SmartSessionMode.USE), r.pid, abi.encodePacked(rr, s, v));
    }

    function _submit(Req memory r, bytes memory signature) internal {
        vm.prank(RELAYER);
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, signature, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    /// @dev Sign and submit a well-formed request. The gateway is a recorder so dispatch succeeds.
    function _run(Req memory r) internal {
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));
        _submit(r, _signed(r));
    }

    function _configId() internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(permissionId, actionId));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), actionPolicyId)));
    }

    function _spent() internal view returns (uint256) {
        return ucep.getConfig(_configId(), address(wallet)).spent;
    }

    // ═══════════════════════════ the happy path ═══════════════════════════

    function test_HappyPath_ValidatesAndDispatches() public {
        Req memory r = _defaultReq();
        _run(r);

        assertEq(callsRecorded(GATEWAY), 1, "the gateway was called exactly once");
        assertEq(wallet.getNonce(0), 1, "the lane advanced");
        assertEq(_spent(), 1 ether, "UCEP metered the bridged amount");
    }

    // ═══════════════════════════════════ W-19 ═══════════════════════════════════

    /// PERMISSIONLESS: any unrelated EOA can relay, and the owner can self-relay. The caller is
    /// never the authority.
    function test_W19_Permissionless_Relay() public {
        etchCallRecorder(GATEWAY);

        Req memory r = _defaultReq();
        bytes memory sig = _signed(r);

        address stranger = makeAddr("someRandomRelayer");
        vm.prank(stranger);
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
        assertEq(wallet.getNonce(0), 1, "a stranger relayed successfully");

        // the owner can self-relay too
        Req memory r2 = _defaultReq();
        r2.nonceSeq = 1;
        bytes memory sig2 = _signed(r2);
        vm.prank(WALLET_OWNER);
        wallet.executeWithSession(
            r2.validator, r2.mode, r2.executionCalldata, sig2, r2.nonceKey, r2.nonceSeq, r2.requestExpiry
        );
        assertEq(wallet.getNonce(0), 2, "the owner self-relayed");
    }

    // ═══════════════════════════════════ W-02 ═══════════════════════════════════

    /**
     * W-02 ⚠️ NEVER-DELETE — THE BANKED-REQUEST GUARANTEE.
     *
     * Sign a valid request under mandate A. Revoke A, regrant BYTE-IDENTICAL terms as mandate B.
     * The banked request must now fail — because `_grantNonce` gave B a different salt, hence a
     * different permissionId, which is bound into op-hash field 5. Without field 5 (§11 item 8) the
     * old signature would still verify against the new mandate and charge the new budget.
     */
    function test_W02_BankedRequest_FailsAfterRegrant() public {
        etchCallRecorder(GATEWAY);

        // the agent banks a valid, signed request
        Req memory banked = _defaultReq();
        bytes memory bankedSig = _signed(banked);

        // the owner revokes and regrants IDENTICAL terms
        vm.startPrank(WALLET_OWNER);
        wallet.stopMandate(permissionId);
        bytes32 newPid = wallet.grantMandate(canonicalSession(ecdsaConfig(agentAddr), _ucepInitData()));
        vm.stopPrank();

        assertTrue(newPid != permissionId, "the regranted mandate has a NEW id");

        // the banked request now fails
        vm.prank(RELAYER);
        // The regranted mandate has a new id, so the banked prefix names a permission the
        // engine no longer knows.
        vm.expectRevert(
            abi.encodeWithSelector(ISmartSession.InvalidPermissionId.selector, PermissionId.wrap(banked.pid))
        );
        wallet.executeWithSession(
            banked.validator,
            banked.mode,
            banked.executionCalldata,
            bankedSig,
            banked.nonceKey,
            banked.nonceSeq,
            banked.requestExpiry
        );

        assertEq(callsRecorded(GATEWAY), 0, "nothing dispatched");

        // and the NEW permission's counters are untouched
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        ConfigId newCfg =
            ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), keccak256(abi.encodePacked(newPid, actionId)))));
        assertEq(ucep.getConfig(newCfg, address(wallet)).spent, 0, "the new mandate's budget is untouched");
    }

    // ═══════════════════════════════════ W-03 ═══════════════════════════════════

    /**
     * W-03 — the op hash binds all TEN fields. Flip each independently; each must fail.
     *
     * The mechanism: the agent signs `_opHash(r)`. If the wallet recomputes a DIFFERENT hash from
     * the arrived parameters, the engine's signature check fails. So flipping a field in the
     * submitted parameters — while keeping the signature over the ORIGINAL — must break validation.
     *
     * Fields 1 (domain), 2 (chainid) and 3 (address(this)) cannot be flipped through the door's
     * parameters; they are asserted structurally at the end.
     */
    /**
     * Field 4 binds the VALIDATOR ADDRESS, so a signature authorising validator A cannot be
     * replayed against validator B.
     *
     * The second validator VERIFIES THE HASH rather than rubber-stamping — an always-succeed mock
     * would accept anything, and the test could not fail. It recomputes the ten-field hash with
     * ITSELF as field 4 and compares against the opHash the wallet passed in: they differ, because
     * the wallet computed field 4 from the submitted validator while the agent signed for the
     * engine.
     */
    function test_W03_OpHash_Field4_Validator() public {
        HashCheckingValidator alt = new HashCheckingValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(alt), "");

        Req memory r = _defaultReq();
        bytes memory sig = _signed(r); // signed with validator == engine in field 4

        // What the agent actually signed:
        alt.expectHash(_opHash(r));

        // Submitted against a DIFFERENT validator: the wallet now computes field 4 = alt, so the
        // opHash it hands the validator differs from the one the agent signed.
        r.validator = address(alt);
        vm.prank(RELAYER);
        vm.expectRevert(HashCheckingValidator.HashMismatch.selector);
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    function test_W03_OpHash_Field5_PermissionId() public {
        // grant a second mandate, so a real second id exists
        vm.prank(WALLET_OWNER);
        bytes32 otherPid = wallet.grantMandate(canonicalSession(ecdsaConfig(agentAddr), _ucepInitData()));

        Req memory r = _defaultReq();
        bytes32 h = _opHash(r); // hash commits to permissionId A
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(agentPk, h);

        // ...but the wire prefix names permissionId B. The wallet reads field 5 from the prefix, so
        // it recomputes a different hash and the signature fails.
        bytes memory tampered = abi.encodePacked(uint8(SmartSessionMode.USE), otherPid, abi.encodePacked(rr, s, v));

        // The engine returns FAILURE (it does not revert) and the wallet converts that to
        // ValidationFailed(address(1)). Naming it is what proves the SIGNATURE rejected the flipped
        // hash, rather than the request being malformed in some other way.
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, tampered, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    /**
     * Field 6 binds the WHOLE ModeCode, not just the two bytes the door gates on.
     *
     * THE OBVIOUS TEST IS WRONG, and mutation proved it: flipping single -> batch reverts at step 9
     * regardless of whether `mode` is in the hash at all, so a field-6 test built that way passes
     * against a hash that omits field 6 entirely — verified.
     *
     * This flips the ModePayload instead: 22 bytes the wallet never inspects and the engine never
     * gates on. If the mode were not hash-bound, this request would sail through. The ONLY thing
     * that can reject it is the signature over field 6.
     */
    function test_W03_OpHash_Field6_Mode() public {
        Req memory r = _defaultReq();
        bytes memory sig = _signed(r);

        // Same CALLTYPE_SINGLE + EXECTYPE_DEFAULT; a different ModePayload.
        r.mode = bytes32(abi.encodePacked(bytes1(0x00), bytes1(0x00), bytes4(0), bytes4(0), bytes22(uint176(0xABCDEF))));
        assertTrue(wallet.supportsExecutionMode(r.mode), "the flipped mode is still an ACCEPTED mode");

        vm.prank(RELAYER);
        // Signature-level rejection: the engine returns FAILURE (it does not revert) and the
        // wallet converts that verdict to ValidationFailed(address(1)). Naming it proves the
        // SIGNATURE rejected the flip, not that the request was malformed some other way.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    /**
     * A MALFORMED batch — batch mode paired with single-encoded calldata — is rejected by the
     * ENGINE's batch decoder, on SHAPE, before the wallet's step-9 gate is reached.
     *
     * THIS TEST WAS ONCE MISNAMED, and the misnaming hid a real gap. It used to be called
     * "...BatchIsRejectedByTheEngineFirst" and was read as evidence that the wallet's call-type gate
     * is unreachable — which is FALSE. The engine ACCEPTS batch mode
     * (`SmartSession.sol:280-288` routes it to `checkBatch7579Exec`); it was only the malformed
     * SHAPE that failed here. W-09 now sends a WELL-FORMED batch and proves the wallet's gate fires
     * on its own, with its own named error.
     *
     * What this test actually pins: the engine rejects a shape mismatch, and it does so without
     * revert data — the one bare expectRevert in this file.
     */
    function test_W03_OpHash_Field6_MalformedBatchShapeIsRejected() public {
        Req memory r = _defaultReq();
        r.mode = ModeCode.unwrap(ModeLib.encodeSimpleBatch());
        bytes memory sig = _signed(r); // correctly signed FOR batch

        vm.prank(RELAYER);
        // BARE BY CONSTRUCTION (1 of 1 in this file — see the header). Batch mode paired with
        // single-encoded calldata fails the ENGINE's batch decoder on SHAPE, and that decoder
        // reverts without data. There is no named error to expect.
        vm.expectRevert();
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );

        // The wallet's own gate is still live and reachable — proven by a mode the engine accepts
        // but the wallet refuses: EXECTYPE_TRY with a single call type.
        Req memory t = _defaultReq();
        t.mode = bytes32(abi.encodePacked(bytes1(0x00), bytes1(0x01), bytes4(0), bytes4(0), bytes22(0)));
        assertFalse(wallet.supportsExecutionMode(t.mode), "try-exec is not an accepted mode");
    }

    function test_W03_OpHash_Field7_ExecutionCalldata() public {
        Req memory r = _defaultReq();
        bytes memory sig = _signed(r);

        r.executionCalldata = _executionCalldata(2 ether, 0); // a different amount, one layer down
        vm.prank(RELAYER);
        // Signature-level rejection: the engine returns FAILURE (it does not revert) and the
        // wallet converts that verdict to ValidationFailed(address(1)). Naming it proves the
        // SIGNATURE rejected the flip, not that the request was malformed some other way.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    function test_W03_OpHash_Field8_NonceKey() public {
        Req memory r = _defaultReq();
        bytes memory sig = _signed(r);

        r.nonceKey = 7; // a different lane, whose position also starts at 0 so step 3 still passes
        vm.prank(RELAYER);
        // Signature-level rejection: the engine returns FAILURE (it does not revert) and the
        // wallet converts that verdict to ValidationFailed(address(1)). Naming it proves the
        // SIGNATURE rejected the flip, not that the request was malformed some other way.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );
    }

    function test_W03_OpHash_Field9_NonceSeq() public {
        // burn position 0 so position 1 is the expected one
        _run(_defaultReq());

        Req memory r = _defaultReq();
        r.nonceSeq = 1;
        bytes memory sig = _signed(r);

        // sign for seq 1 but... the hash commits to 1, and we submit 1. To flip the FIELD we must
        // sign a different value: sign seq 2's hash and submit as seq 1.
        Req memory other = _defaultReq();
        other.nonceSeq = 2;
        bytes memory wrongSig = _signed(other);
        sig; // the correct signature exists; we deliberately submit the other one

        vm.prank(RELAYER);
        // Signature-level rejection: the engine returns FAILURE (it does not revert) and the
        // wallet converts that verdict to ValidationFailed(address(1)). Naming it proves the
        // SIGNATURE rejected the flip, not that the request was malformed some other way.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, wrongSig, r.nonceKey, 1, r.requestExpiry);
    }

    function test_W03_OpHash_Field10_RequestExpiry() public {
        Req memory r = _defaultReq();
        r.requestExpiry = uint48(block.timestamp + 1 days);
        bytes memory sig = _signed(r);

        // a relayer trying to EXTEND the request's lifetime
        vm.prank(RELAYER);
        // Signature-level rejection: the engine returns FAILURE (it does not revert) and the
        // wallet converts that verdict to ValidationFailed(address(1)). Naming it proves the
        // SIGNATURE rejected the flip, not that the request was malformed some other way.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, uint48(block.timestamp + 30 days)
        );
    }

    /// Fields 1-3 are not reachable through the door's parameters. They are asserted structurally:
    /// the hash the contract computes equals the hash built from the domain, this chain and this
    /// wallet — so a different chain or a different wallet yields a different hash by construction.
    function test_W03_OpHash_Fields1to3_StructuralBinding() public {
        Req memory r = _defaultReq();

        bytes32 mine = _opHash(r);

        bytes32 otherChain = keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
                block.chainid + 1,
                address(wallet),
                r.validator,
                r.pid,
                r.mode,
                keccak256(r.executionCalldata),
                r.nonceKey,
                r.nonceSeq,
                r.requestExpiry
            )
        );
        bytes32 otherWallet = keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
                block.chainid,
                address(walletImpl),
                r.validator,
                r.pid,
                r.mode,
                keccak256(r.executionCalldata),
                r.nonceKey,
                r.nonceSeq,
                r.requestExpiry
            )
        );
        bytes32 otherDomain = keccak256(
            abi.encode(
                keccak256("SomeOtherProtocol.Op.v1"),
                block.chainid,
                address(wallet),
                r.validator,
                r.pid,
                r.mode,
                keccak256(r.executionCalldata),
                r.nonceKey,
                r.nonceSeq,
                r.requestExpiry
            )
        );

        assertTrue(mine != otherChain, "field 2: chainid is bound");
        assertTrue(mine != otherWallet, "field 3: address(this) is bound");
        assertTrue(mine != otherDomain, "field 1: the domain is bound");

        // and the contract really computes `mine` — proven by the signature over it validating
        _run(r);
        assertEq(callsRecorded(GATEWAY), 1, "the contract's hash == the independently built one");
    }

    // ═══════════════════════════════════ W-04 ═══════════════════════════════════

    function test_W04_Replay_And_LaneIndependence() public {
        Req memory r = _defaultReq();
        _run(r);
        assertEq(wallet.getNonce(0), 1, "lane 0 advanced");

        // the SAME (key, seq) again
        bytes memory sig = _signed(r);
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, uint192(0), uint64(1), uint64(0))
        );
        wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        );

        // a DIFFERENT lane is unaffected and starts at zero
        Req memory lane5 = _defaultReq();
        lane5.nonceKey = 5;
        _run(lane5);
        assertEq(wallet.getNonce(5), 1, "lane 5 advanced independently");
        assertEq(wallet.getNonce(0), 1, "lane 0 unchanged");

        // a WEDGED lane (submitting seq 9 on lane 3) blocks nothing else
        Req memory wedged = _defaultReq();
        wedged.nonceKey = 3;
        wedged.nonceSeq = 9;
        bytes memory wsig = _signed(wedged);
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, uint192(3), uint64(0), uint64(9))
        );
        wallet.executeWithSession(
            wedged.validator, wedged.mode, wedged.executionCalldata, wsig, wedged.nonceKey, wedged.nonceSeq, 0
        );

        Req memory lane7 = _defaultReq();
        lane7.nonceKey = 7;
        _run(lane7);
        assertEq(wallet.getNonce(7), 1, "a wedged lane blocks nothing else");
    }

    // ═══════════════════════════════════ W-05 ═══════════════════════════════════

    /**
     * W-05 — the position is consumed BEFORE validation (§11 item 2).
     *
     * A FAILED validation reverts the whole transaction, so the lane is restored — which is why the
     * ordering looks unobservable from outside. What it actually buys is that a re-entrant
     * validator cannot reuse the position DURING validation: by the time the engine is called, the
     * position is already spent in this frame.
     *
     * Asserted directly: a validator that re-enters the door mid-validation cannot replay.
     */
    function test_W05_Nonce_ConsumedBeforeValidation() public {
        ReenteringValidator reenter = new ReenteringValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(reenter), "");
        reenter.arm(address(wallet), _defaultReq().executionCalldata, _singleMode());

        Req memory r = _defaultReq();
        r.validator = address(reenter);
        bytes memory sig = _signed(r);

        // The re-entrant call inside validation must not succeed. Whatever the outer result, the
        // lane can never have advanced twice.
        vm.prank(RELAYER);
        try wallet.executeWithSession(
            r.validator, r.mode, r.executionCalldata, sig, r.nonceKey, r.nonceSeq, r.requestExpiry
        ) { }
            catch { }

        assertLe(wallet.getNonce(0), 1, "the position was never consumed twice");
        assertTrue(reenter.reentryFailed(), "the re-entrant call was refused");
    }

    // ═══════════════════════════════════ W-06 ═══════════════════════════════════

    function test_W06_RequestExpiry_Semantics() public {
        // (a) 0 => NEVER expires by time. Warp far forward — but stay INSIDE the mandate's own
        // validUntil (365 days), because UCEP gate 2 would otherwise kill the request first and
        // this test would pass for the wrong reason.
        vm.warp(block.timestamp + 300 days);
        Req memory never = _defaultReq();
        never.requestExpiry = 0;
        _run(never);
        assertEq(callsRecorded(GATEWAY), 1, "requestExpiry == 0 means NO expiry");

        // (b) a DISTANT-FUTURE stamp is ACCEPTED — there is no ceiling (§11 item 7). The stamp may
        // sit far beyond the mandate's own expiry; the wallet does not police the distance.
        Req memory distant = _defaultReq();
        distant.nonceSeq = 1;
        distant.requestExpiry = uint48(block.timestamp + 3650 days);
        _run(distant);
        assertEq(callsRecorded(GATEWAY), 1, "a year-ahead expiry is ACCEPTED, not rejected");

        // (c) a PAST stamp reverts, with zero state change.
        Req memory past = _defaultReq();
        past.nonceSeq = 2;
        past.requestExpiry = uint48(block.timestamp - 1);
        bytes memory sig = _signed(past);

        uint64 nonceBefore = wallet.getNonce(0);
        uint256 spentBefore = _spent();

        vm.prank(RELAYER);
        vm.expectRevert(PushWalletErrors.RequestExpired.selector);
        wallet.executeWithSession(past.validator, past.mode, past.executionCalldata, sig, 0, 2, past.requestExpiry);

        assertEq(wallet.getNonce(0), nonceBefore, "nonce unchanged");
        assertEq(_spent(), spentBefore, "spend unchanged");
    }

    /// The boundary: expiry == now is still valid (the check is strictly greater-than).
    function test_W06_ExpiryBoundaryIsInclusive() public {
        Req memory r = _defaultReq();
        r.requestExpiry = uint48(block.timestamp);
        _run(r);
        assertEq(callsRecorded(GATEWAY), 1, "block.timestamp == requestExpiry is NOT expired");
    }

    // ═══════════════════════════════════ W-07 ═══════════════════════════════════

    /**
     * W-07 — the verdict is enforced. Skipping this makes UCEP's expiry gate DECORATIVE: the engine
     * returns the window in `vd` and only the wallet enforces it.
     *
     * A mock validator is used because the real engine cannot be made to return an arbitrary
     * ValidationData. It is an OBSERVER of the wallet's reaction, not an oracle for validation.
     */
    function test_W07_Verdict_Enforced() public {
        VerdictValidator v = new VerdictValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(v), "");

        Req memory r = _defaultReq();
        r.validator = address(v);

        // (a) a non-zero authorizer => ValidationFailed. The engine signals failure with address(1).
        v.setVerdict(uint256(uint160(address(1))));
        bytes memory sig = _signed(r);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidationFailed.selector, address(1)));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);

        // (b) before validAfter => OutsideTimeWindow
        uint48 futureStart = uint48(block.timestamp + 1 days);
        v.setVerdict(uint256(futureStart) << 208);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.OutsideTimeWindow.selector, futureStart, uint48(0)));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);

        // (c) after a non-zero validUntil => OutsideTimeWindow
        uint48 pastEnd = uint48(block.timestamp - 1);
        v.setVerdict(uint256(pastEnd) << 160);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.OutsideTimeWindow.selector, uint48(0), pastEnd));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);

        // (d) validUntil == 0 => UNBOUNDED. A zero verdict passes and dispatches.
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));
        v.setVerdict(0);
        vm.prank(RELAYER);
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);
        assertEq(callsRecorded(GATEWAY), 1, "validUntil == 0 is unbounded, not expired");
    }

    // ═══════════════════════════════════ W-08 ═══════════════════════════════════

    /// The built operation's paymasterAndData is EMPTY on every path. Captured from a validator
    /// that records what the wallet actually built.
    function test_W08_Paymaster_AlwaysEmpty() public {
        CapturingValidator cap = new CapturingValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(cap), "");

        etchCallRecorder(GATEWAY);
        Req memory r = _defaultReq();
        r.validator = address(cap);
        _submit(r, _signed(r));

        assertEq(cap.paymasterAndDataLength(), 0, "paymasterAndData is empty");
        assertEq(cap.initCodeLength(), 0, "initCode is empty");
        assertEq(cap.accountGasLimits(), bytes32(0), "gas limits are zero");
        assertEq(cap.preVerificationGas(), 0, "preVerificationGas is zero");
        assertEq(cap.gasFees(), bytes32(0), "gasFees are zero");
        assertEq(cap.sender(), address(wallet), "sender == the wallet");
        assertEq(cap.nonce(), (uint256(r.nonceKey) << 64) | uint256(r.nonceSeq), "nonce mirrors the lane pair");
    }

    // ═══════════════════════════════════ W-26 ═══════════════════════════════════

    /**
     * W-26 — the built operation's callData selector decides which engine branch runs.
     *
     * When it equals IERC7579Account.execute.selector the engine decodes the mode and calls the
     * action policy through checkSingle7579Exec, forwarding THE REAL DECODED VALUE — which is what
     * UCEP's gas-value gate compares against. Every other selector falls through to the generic
     * branch, which calls the policy with target = account and a HARDCODED value = 0.
     */
    function test_W26_EngineBranch_SingleExecOnly() public {
        CapturingValidator cap = new CapturingValidator();
        vm.prank(WALLET_OWNER);
        wallet.installModule(1, address(cap), "");

        etchCallRecorder(GATEWAY);
        Req memory r = _defaultReq();
        r.validator = address(cap);
        _submit(r, _signed(r));

        assertEq(cap.callDataSelector(), IERC7579Account.execute.selector, "the standard execute selector");
        assertEq(cap.callDataSelector(), bytes4(0xe9ae5c53), "and its literal value");
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
        Req memory r = _defaultReq();
        // a target the mandate has no action for
        r.executionCalldata = ExecutionLib.encodeSingle(makeAddr("someOtherContract"), 0, hex"11223344");
        bytes memory sig = _signed(r);

        vm.prank(RELAYER);
        // The engine finds no policy configured for this (account, selector) and dies at its
        // minimum-one-policy floor — the second, independent reason a zero-value comparison
        // can never be reached.
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(r.pid)));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);
    }

    // ═══════════════════════════════════ W-09 ═══════════════════════════════════

    /**
     * W-09 — the agent door is SINGLE-call-type only. Batching lives two layers deeper, inside the
     * multicall payload, bounded by UCEP's ten.
     *
     * THE GATE IS INDEPENDENTLY REACHABLE, and this test is what proves it. An earlier version
     * paired batch MODE with single-ENCODED executionCalldata; the engine's batch decoder then
     * failed on SHAPE, and a bare `expectRevert` accepted that as if the gate had fired. Mutation
     * exposed it: deleting `callType != CALLTYPE_SINGLE` left the suite green.
     *
     * The engine ACCEPTS batch mode — `SmartSession.sol:280-288` routes CALLTYPE_BATCH to
     * `checkBatch7579Exec`, which runs UCEP per entry, so a well-formed batch of one valid
     * (gateway, sendOutbound) entry passes engine validation cleanly. The ONLY thing standing
     * between it and dispatch is the wallet's step-9 gate, and it must name its own error.
     */
    function test_W09_AgentDoor_SingleCallTypeOnly() public {
        // A WELL-FORMED batch: batch mode AND batch-encoded calldata, one valid gateway entry,
        // signed for batch. This passes the engine and dies at the wallet's gate.
        Execution[] memory entries = new Execution[](1);
        entries[0] = Execution({
            target: GATEWAY, value: 0, callData: outboundRequest(ASSET, 1 ether, 1 ether, address(wallet), _calls())
        });

        Req memory b = _defaultReq();
        b.mode = ModeCode.unwrap(ModeLib.encodeSimpleBatch());
        b.executionCalldata = ExecutionLib.encodeBatch(entries);
        bytes memory bsig = _signed(b);

        vm.prank(RELAYER);
        vm.expectRevert(PushWalletErrors.UnsupportedExecutionMode.selector);
        wallet.executeWithSession(b.validator, b.mode, b.executionCalldata, bsig, 0, 0, 0);

        // and BATCH still works on the OWNER door — the restriction is contextual, not global
        Execution[] memory execs = new Execution[](1);
        execs[0] = Execution({ target: makeAddr("sink"), value: 1 ether, callData: "" });
        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(execs));
        assertEq(makeAddr("sink").balance, 1 ether, "the owner door still batches");
    }

    /**
     * The exotic call types and the try-exec type, each naming the error that actually fires.
     *
     * These do NOT reach the wallet's step-9 gate: the ENGINE rejects them first, and it names them
     * itself — `UnsupportedExecutionType()` for a non-default exec type, and `UnsupportedCallType`
     * for a call type it does not route. Read from the trace, not assumed.
     */
    function test_W09_ExoticModes_RejectedByTheEngineWithNamedErrors() public {
        // try-exec type: the engine's own named error (SmartSession.sol:276)
        Req memory t = _defaultReq();
        t.mode = bytes32(abi.encodePacked(bytes1(0x00), bytes1(0x01), bytes4(0), bytes4(0), bytes22(0)));
        bytes memory tsig = _signed(t);
        vm.prank(RELAYER);
        vm.expectRevert(ISmartSession.UnsupportedExecutionType.selector);
        wallet.executeWithSession(t.validator, t.mode, t.executionCalldata, tsig, 0, 0, 0);

        // delegatecall and static: neither is a routed call type, so the engine refuses them
        bytes1[2] memory exotic = [bytes1(0xFF), bytes1(0xFE)];
        for (uint256 i; i < exotic.length; ++i) {
            Req memory r = _defaultReq();
            r.mode = bytes32(abi.encodePacked(exotic[i], bytes1(0x00), bytes4(0), bytes4(0), bytes22(0)));
            bytes memory sig = _signed(r);
            vm.prank(RELAYER);
            vm.expectRevert(abi.encodeWithSelector(ISmartSession.UnsupportedCallType.selector, exotic[i]));
            wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);
        }
    }

    // ═══════════════════════════════════ W-28 ═══════════════════════════════════

    /**
     * W-28 — ENABLE and UNSAFE_ENABLE are refused AT THE WALLET, and NO CALL REACHES THE ENGINE.
     *
     * This pins §6.6 step 4: field 5 is unconditionally a permission id. In ENABLE mode the engine
     * does not read bytes [1:33] as a permission id at all (`EncodeLib.sol:29-37`) — it derives the
     * id from the session data — so without the wallet's mode check, arbitrary session bytes would
     * be bound into op-hash field 5.
     *
     * The zero-call assertion uses the recorder rather than `vm.expectCall(..., 0)` because a
     * cheatcode-level expectation failure is not catchable, so its negative branch could never be
     * demonstrated. The recorder's counter is ordinary storage, so both branches are provable.
     */
    function test_W28_AgentDoor_RejectsEnableMode() public {
        bytes memory realEngineCode = address(engine).code;
        etchCallRecorder(address(engine));
        vm.store(address(engine), bytes32(uint256(0)), bytes32(0));

        Req memory r = _defaultReq();

        // a well-formed, >= 33-byte signature whose mode byte is ENABLE
        bytes memory enableSig = abi.encodePacked(uint8(SmartSessionMode.ENABLE), r.pid, new bytes(65));
        vm.prank(RELAYER);
        vm.expectRevert(PushWalletErrors.InvalidSessionSignature.selector);
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, enableSig, 0, 0, 0);

        // and UNSAFE_ENABLE
        bytes memory unsafeSig = abi.encodePacked(uint8(SmartSessionMode.UNSAFE_ENABLE), r.pid, new bytes(65));
        vm.prank(RELAYER);
        vm.expectRevert(PushWalletErrors.InvalidSessionSignature.selector);
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, unsafeSig, 0, 0, 0);

        assertEq(callsRecorded(address(engine)), 0, "NO call reached the engine");

        vm.etch(address(engine), realEngineCode);
    }

    /// A signature too short to carry USE ‖ permissionId is refused by the same guard.
    function test_W28_ShortSignatureRefused() public {
        Req memory r = _defaultReq();

        bytes[3] memory shorts = [bytes(""), abi.encodePacked(uint8(0)), abi.encodePacked(uint8(0), new bytes(31))];
        for (uint256 i; i < shorts.length; ++i) {
            vm.prank(RELAYER);
            vm.expectRevert(PushWalletErrors.InvalidSessionSignature.selector);
            wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, shorts[i], 0, 0, 0);
        }
    }

    // ═══════════════════════════════════ W-18 ═══════════════════════════════════

    /**
     * W-18 — an execution revert unwinds EVERYTHING: the nonce, UCEP's spent counter, and the
     * metering event. This is the atomicity the whole failure model rests on, and it is why
     * dispatch is NEVER wrapped in try/catch (§11 item 3).
     */
    function test_W18_ExecutionRevert_UnwindsAll() public {
        // first, a successful request so there is real state to preserve
        _run(_defaultReq());
        uint64 nonceAfter = wallet.getNonce(0);
        uint256 spentAfter = _spent();
        assertEq(nonceAfter, 1, "state exists");
        assertEq(spentAfter, 1 ether, "spend recorded");

        // now a request whose DISPATCH reverts: the gateway rejects the call
        vm.etch(GATEWAY, type(RevertingGateway).runtimeCode);

        Req memory r = _defaultReq();
        r.nonceSeq = 1;
        bytes memory sig = _signed(r);

        vm.prank(RELAYER);
        vm.expectRevert(RevertingGateway.GatewayRejected.selector); // bubbled from the gateway, verbatim
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 1, 0);

        assertEq(wallet.getNonce(0), nonceAfter, "the NONCE unwound");
        assertEq(_spent(), spentAfter, "UCEP's SPENT counter unwound");

        // The EVENTS are unwound with the frame too. Asserted through STATE rather than through
        // vm.getRecordedLogs: forge records logs emitted inside a frame that later reverts, so a
        // log-scanning assertion here would fail against correct behaviour. What actually matters —
        // and what a chain observer would see — is that no counter moved, which is asserted above.
        //
        // The event's absence is then proven positively: a SECOND, successful request re-emits
        // exactly one of each, so the counters and the events stay in lockstep.
        vm.etch(GATEWAY, "");
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));

        Req memory good = _defaultReq();
        good.nonceSeq = 1;

        vm.expectEmit(true, true, true, true, address(wallet));
        emit IPushAgentWallet.MandateActionAuthorized(good.pid, good.nonceKey, good.nonceSeq, _opHash(good));
        _submit(good, _signed(good));

        assertEq(wallet.getNonce(0), 2, "the retry advanced the lane exactly once");
        assertEq(_spent(), spentAfter + 1 ether, "and metered exactly once");
    }

    // ═══════════════════════════════════ W-23 ═══════════════════════════════════

    /// The agent-door half of the attribution record.
    function test_W23_Events_Attribution_AgentDoor() public {
        etchCallRecorder(GATEWAY);

        Req memory r = _defaultReq();
        bytes32 expectedHash = _opHash(r);

        vm.expectEmit(true, true, true, true, address(wallet));
        emit IPushAgentWallet.MandateActionAuthorized(r.pid, r.nonceKey, r.nonceSeq, expectedHash);

        _submit(r, _signed(r));
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
     *   (a) a 7579-level dispatch target of the wallet never matches the mandate's one configured
     *       action, so it dies at the engine's minimum-one-policy FLOOR before UCEP runs;
     *   (b) a request that DOES match the action (target = gateway) but names the wallet as an
     *       INNER multicall target reaches UCEP gate 14, which forbids it;
     *   (c) with UCEP bypassed entirely via a non-canonical policy, the engine still refuses an
     *       execute-selector self-target with its own InvalidSelfCall.
     */
    function test_W29_AgentDoor_CannotSelfCall() public {
        // ── (a) the engine's no-policy floor ──
        // Dispatch target = the wallet, calling stopAll. The mandate configures exactly one action,
        // (gateway, sendOutbound); this matches nothing, so no policy is found.
        Req memory a = _defaultReq();
        a.executionCalldata = ExecutionLib.encodeSingle(address(wallet), 0, abi.encodeCall(PushAgentWallet.stopAll, ()));
        bytes memory aSig = _signed(a);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(a.pid)));
        wallet.executeWithSession(a.validator, a.mode, a.executionCalldata, aSig, 0, 0, 0);

        // ── (b) UCEP gate 14: the wallet is a forbidden INNER target ──
        // This request DOES match the configured action, so the gauntlet runs. The multicall names
        // the wallet, which gate 14 refuses before the allow-list is even consulted.
        Multicall[] memory selfCalls = new Multicall[](1);
        selfCalls[0] = Multicall({ to: address(wallet), value: 0, data: abi.encodeCall(PushAgentWallet.stopAll, ()) });

        Req memory b = _defaultReq();
        b.executionCalldata = ExecutionLib.encodeSingle(
            GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, address(wallet), selfCalls)
        );
        bytes memory bSig = _signed(b);

        vm.prank(RELAYER);
        expectUcepGate(abi.encodeWithSelector(IUCEP.ForbiddenInnerTarget.selector, address(wallet)));
        wallet.executeWithSession(b.validator, b.mode, b.executionCalldata, bSig, 0, 0, 0);

        // ── (c) with UCEP BYPASSED, the engine's own InvalidSelfCall ──
        // sessionWithPolicy grants a mandate whose action policy is NOT UCEP — a shape grantMandate
        // would refuse — so the gauntlet never runs. The engine still refuses an execute-selector
        // self-target (PolicyLib.sol:196).
        PermissivePolicy permissive = new PermissivePolicy();
        Session memory bypass = sessionWithPolicy(address(permissive), ecdsaConfig(agentAddr), "");
        bypass.actions[0].actionTarget = address(wallet);
        bypass.actions[0].actionTargetSelector = PushAgentWallet.execute.selector;
        bypass.salt = bytes32(uint256(0xE29));

        Session[] memory arr = new Session[](1);
        arr[0] = bypass;
        vm.prank(address(wallet));
        bytes32 bypassPid = PermissionId.unwrap(engine.enableSessions(arr)[0]);

        // The dispatch calldata must carry the EXECUTE selector for this branch to fire:
        // `PolicyLib.sol:195-198` reverts only when targetSig == IERC7579Account.execute.selector
        // AND target == msg.sender. A stopAll payload falls through to the action lookup instead.
        Req memory c = _defaultReq();
        c.pid = bypassPid;
        c.executionCalldata = ExecutionLib.encodeSingle(
            address(wallet),
            0,
            abi.encodeCall(
                PushAgentWallet.execute,
                (
                    _singleMode(),
                    ExecutionLib.encodeSingle(address(wallet), 0, abi.encodeCall(PushAgentWallet.stopAll, ()))
                )
            )
        );
        bytes memory cSig = _signed(c);

        vm.prank(RELAYER);
        vm.expectRevert(ISmartSession.InvalidSelfCall.selector);
        wallet.executeWithSession(c.validator, c.mode, c.executionCalldata, cSig, 0, 0, 0);

        // ── THE POSITIVE CONTROL ──
        // The same stopMandate calldata, through the OWNER door, succeeds via exactly the self-call
        // path the agent door cannot reach. Without this the test could pass against a wallet where
        // self-calls simply never work.
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution({
            target: address(wallet), value: 0, callData: abi.encodeCall(PushAgentWallet.stopMandate, (permissionId))
        });

        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(batch));

        assertFalse(
            engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(wallet)),
            "the owner's self-call path DOES work - the widening is reachable exactly once"
        );
    }

    // ═══════════════════════ U-12 / U-18, the deferred halves ═══════════════════════

    /// U-12's wallet half: a successful positive-amount request advances UCEP's counter AND emits
    /// OutboundMetered, through the real engine path.
    function test_U12_MeteringThroughTheRealPath() public {
        etchCallRecorder(GATEWAY);

        vm.expectEmit(true, true, true, true, address(ucep));
        emit IUCEP.OutboundMetered(_configId(), address(engine), address(wallet), 3 ether);

        Req memory r = _defaultReq();
        r.executionCalldata = _executionCalldata(3 ether, 0);
        _submit(r, _signed(r));

        assertEq(_spent(), 3 ether, "spent advanced by exactly the bridged amount");
    }

    /// U-04's wallet half: a zero-amount request PASSES and meters nothing — the redeploy path.
    function test_U04_ZeroAmountThroughTheRealPath() public {
        etchCallRecorder(GATEWAY);

        Req memory r = _defaultReq();
        r.executionCalldata = _executionCalldata(0, 0);
        _submit(r, _signed(r));

        assertEq(callsRecorded(GATEWAY), 1, "the zero-amount request dispatched");
        assertEq(_spent(), 0, "and metered nothing");
    }

    /// The PC-value path: value decoded from the VALIDATED calldata leaves the wallet's own
    /// balance, bounded by UCEP gate 8. The relayer cannot attach value — this door is not payable.
    function test_AgentRequestMovesPCFromTheWalletsOwnBalance() public {
        etchCallRecorder(GATEWAY);
        uint256 before = address(wallet).balance;

        Req memory r = _defaultReq();
        r.executionCalldata = _executionCalldata(1 ether, 2 ether); // 2 PC, within maxPCPerCall = 5
        _submit(r, _signed(r));

        assertEq(address(wallet).balance, before - 2 ether, "PC left the wallet's own balance");
        assertEq(GATEWAY.balance, 2 ether, "and reached the gateway");
    }

    /// Above UCEP gate 8's ceiling, the request dies and no PC moves.
    function test_PCValueAboveGate8IsRefused() public {
        etchCallRecorder(GATEWAY);
        uint256 before = address(wallet).balance;

        Req memory r = _defaultReq();
        r.executionCalldata = _executionCalldata(1 ether, 6 ether); // maxPCPerCall is 5 ether
        bytes memory sig = _signed(r);

        vm.prank(RELAYER);
        // UCEP gate 8 fired, named through the engine's 32-byte rewrap.
        expectUcepGate(abi.encodeWithSelector(IUCEP.PCValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);

        assertEq(address(wallet).balance, before, "no PC moved");
    }

    // ═══════════════════════════ door-level guards ═══════════════════════════

    function test_UninstalledValidatorIsRefused() public {
        Req memory r = _defaultReq();
        r.validator = makeAddr("neverInstalled");
        bytes memory sig = _signed(r);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidatorNotInstalled.selector, r.validator));
        wallet.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);
    }

    /// W-22's agent half, now that the door is real: a wallet with NO mandates refuses every agent
    /// request — the engine reverts on an unknown permission id.
    function test_W22_EmptyWallet_RejectsAgents_AgentHalf() public {
        PushAgentWallet fresh = newWallet(WALLET_OWNER);
        vm.deal(address(fresh), 10 ether);

        Req memory r = _defaultReq();
        bytes memory sig = _signed(r);

        vm.prank(RELAYER);
        // No mandate exists on this wallet, so the engine refuses the permission id outright.
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.InvalidPermissionId.selector, PermissionId.wrap(r.pid)));
        fresh.executeWithSession(r.validator, r.mode, r.executionCalldata, sig, 0, 0, 0);
    }
}

// ─────────────────────────────── test doubles ───────────────────────────────

/// @dev Records what the wallet BUILT. An observer: it returns a passing verdict and asserts
///      nothing itself, so the assertions live in the test where they are visible.
contract CapturingValidator {
    address public sender;
    uint256 public nonce;
    uint256 public initCodeLength;
    bytes4 public callDataSelector;
    bytes32 public accountGasLimits;
    uint256 public preVerificationGas;
    bytes32 public gasFees;
    uint256 public paymasterAndDataLength;

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 1;
    }

    /// @dev Takes the TYPED struct, exactly as ISmartSession declares it. An earlier version took
    ///      `bytes calldata` and hand-decoded, which does not match the ABI the wallet encodes.
    function validateUserOp(PackedUserOperation calldata op, bytes32) external returns (uint256) {
        sender = op.sender;
        nonce = op.nonce;
        initCodeLength = op.initCode.length;
        callDataSelector = bytes4(op.callData);
        accountGasLimits = op.accountGasLimits;
        preVerificationGas = op.preVerificationGas;
        gasFees = op.gasFees;
        paymasterAndDataLength = op.paymasterAndData.length;
        return 0;
    }
}

/// @dev Returns an arbitrary ValidationData so the wallet's verdict enforcement is testable. The
///      real engine cannot be made to produce these; this is an observer of the wallet's reaction.
contract VerdictValidator {
    uint256 private _vd;

    function setVerdict(uint256 vd) external {
        _vd = vd;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 1;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(_vd);
    }
}

/// @dev Verifies the opHash it is handed against one supplied by the test. An always-succeed mock
///      would accept anything, so a field-binding test built on one could never fail.
contract HashCheckingValidator {
    error HashMismatch();

    bytes32 private _expected;

    function expectHash(bytes32 h) external {
        _expected = h;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 1;
    }

    function validateUserOp(PackedUserOperation calldata, bytes32 opHash) external view returns (uint256) {
        if (opHash != _expected) revert HashMismatch();
        return 0;
    }
}

/// @dev Re-enters the agent door during validation, to prove the position is already consumed.
contract ReenteringValidator {
    address private _wallet;
    bytes private _ecd;
    bytes32 private _mode;
    bool public reentryFailed;

    function arm(address w, bytes calldata ecd, bytes32 m) external {
        _wallet = w;
        _ecd = ecd;
        _mode = m;
    }

    function onInstall(bytes calldata) external { }
    function onUninstall(bytes calldata) external { }

    function isModuleType(uint256 t) external pure returns (bool) {
        return t == 1;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        // Try to reuse position 0 while the outer frame is still validating it.
        (bool ok,) = _wallet.call(
            abi.encodeWithSignature(
                "executeWithSession(address,bytes32,bytes,bytes,uint192,uint64,uint48)",
                address(this),
                _mode,
                _ecd,
                new bytes(33),
                uint192(0),
                uint64(0),
                uint48(0)
            )
        );
        if (!ok) reentryFailed = true;
        return abi.encode(uint256(0));
    }
}

contract RevertingGateway {
    error GatewayRejected();

    fallback() external payable {
        revert GatewayRejected();
    }

    receive() external payable {
        revert GatewayRejected();
    }
}

/// @dev An action policy that permits everything. Used ONLY to BYPASS UCEP in W-29(b), so the
///      engine's own InvalidSelfCall is reachable and provable on its own. It is never used to
///      establish that something is allowed.
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
    ///      InvalidSelfCall with UCEP out of the way. It never establishes that something is allowed.
    function checkAction(ConfigId, address, address, uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}
