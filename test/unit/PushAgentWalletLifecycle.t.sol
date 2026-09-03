// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { UCEP } from "../../src/policies/UCEP.sol";
import { Session, PermissionId, ConfigId, ActionData, PolicyData, ERC7739Context } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";

/**
 * @notice PushAgentWallet — Phase 3b: the mandate lifecycle.
 *         grantMandate (§6.3) · stopMandate (§6.4) · stopAll (§6.5).
 *
 * @dev    grantMandate does EXACTLY TWO JOBS: the canonical-shape check, and the salt. Everything
 *         about UCEP's config CONTENTS is UCEP's own business and is deliberately untested here —
 *         Phase 1 covers it.
 */
contract PushAgentWalletLifecycleTest is BaseTest {
    PushAgentWallet internal wallet;
    address internal WALLET_OWNER;

    function setUp() public override {
        super.setUp();
        WALLET_OWNER = makeAddr("walletOwner");
        wallet = newWallet(WALLET_OWNER);
        vm.deal(address(wallet), 100 ether);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }

    function _ucepInitData() internal view returns (bytes memory) {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: _addr("farProtocol"),
            selector: bytes4(keccak256("swap(uint256,address)")),
            beneficiaryOffset: 36,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
        return abi.encode(
            IUCEP.Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 365 days),
                destChainHash: keccak256("eip155:11155111"),
                expectedCEA: _addr("cea"),
                asset: _addr("prc20"),
                maxAmountPerCall: 100 ether,
                maxAmountTotal: 1000 ether,
                maxPCPerCall: 5 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    /// @dev THE canonical session — the only shape v3 permits.
    function _canonical() internal view returns (Session memory) {
        return canonicalSession(ecdsaConfig(AGENT), _ucepInitData());
    }

    function _grant(Session memory s) internal returns (bytes32) {
        vm.prank(WALLET_OWNER);
        return wallet.grantMandate(s);
    }

    /// @dev Assert a deviation is refused with the ONE error the shape check ever raises.
    function _expectMalformed(Session memory s) internal {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(PushWalletErrors.MalformedSessionShape.selector);
        wallet.grantMandate(s);
    }

    // ═══════════════════════════════════ W-24 ═══════════════════════════════════

    /**
     * W-24 — the canonical session grants, and EVERY deviation reverts MalformedSessionShape.
     *
     * This is where the deployment spec's five wiring rules stop being doctrine and become code.
     * Two of them were orphan register rows until this check existed.
     */
    function test_W24_CanonicalSessionGrants() public {
        bytes32 pid = _grant(_canonical());
        assertTrue(pid != bytes32(0), "the canonical session grants");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "and is enabled");
    }

    /// Rule 2: nothing may live in the zero-floor policy class.
    function test_W24_Deviation_ExtraUserOpPolicy() public {
        Session memory s = _canonical();
        s.userOpPolicies = new PolicyData[](1);
        s.userOpPolicies[0] = PolicyData({ policy: address(ucep), initData: "" });
        _expectMalformed(s);
    }

    function test_W24_Deviation_NonEmpty7739Content() public {
        Session memory s = _canonical();
        s.erc7739Policies.allowedERC7739Content = new ERC7739Context[](1);
        _expectMalformed(s);
    }

    function test_W24_Deviation_NonEmpty7739Policies() public {
        Session memory s = _canonical();
        s.erc7739Policies.erc1271Policies = new PolicyData[](1);
        s.erc7739Policies.erc1271Policies[0] = PolicyData({ policy: address(ucep), initData: "" });
        _expectMalformed(s);
    }

    /// Rule 5: dead surface, and paymasterAndData is always empty anyway.
    function test_W24_Deviation_PaymasterTrue() public {
        Session memory s = _canonical();
        s.permitERC4337Paymaster = true;
        _expectMalformed(s);
    }

    /// Rule 1, both directions: exactly one action, so no wildcard/fallback action can exist.
    function test_W24_Deviation_ZeroActions() public {
        Session memory s = _canonical();
        s.actions = new ActionData[](0);
        _expectMalformed(s);
    }

    function test_W24_Deviation_TwoActions() public {
        Session memory s = _canonical();
        ActionData[] memory actions = new ActionData[](2);
        actions[0] = s.actions[0];
        actions[1] = s.actions[0];
        s.actions = actions;
        _expectMalformed(s);
    }

    function test_W24_Deviation_WrongTarget() public {
        Session memory s = _canonical();
        s.actions[0].actionTarget = _addr("notTheGateway");
        _expectMalformed(s);
    }

    function test_W24_Deviation_WrongSelector() public {
        Session memory s = _canonical();
        s.actions[0].actionTargetSelector = bytes4(keccak256("somethingElse()"));
        _expectMalformed(s);
    }

    /// Rule 4 — THE FAIL-CLOSED ANCHOR. Zero action policies would mean the engine's minimum-one
    /// floor kills every request... but the grant must not be creatable in the first place.
    function test_W24_Deviation_ZeroActionPolicies() public {
        Session memory s = _canonical();
        s.actions[0].actionPolicies = new PolicyData[](0);
        _expectMalformed(s);
    }

    function test_W24_Deviation_TwoActionPolicies() public {
        Session memory s = _canonical();
        PolicyData[] memory ps = new PolicyData[](2);
        ps[0] = s.actions[0].actionPolicies[0];
        ps[1] = s.actions[0].actionPolicies[0];
        s.actions[0].actionPolicies = ps;
        _expectMalformed(s);
    }

    /// A policy that is not UCEP — built with sessionWithPolicy, the harness helper that exists
    /// precisely so a negative test cannot accidentally use the canonical wiring.
    function test_W24_Deviation_WrongPolicyAddress() public {
        UCEP otherUcep = new UCEP(GATEWAY, EXECUTOR_MODULE, address(engine));
        Session memory s = sessionWithPolicy(address(otherUcep), ecdsaConfig(AGENT), _ucepInitData());
        _expectMalformed(s);
    }

    function test_W24_Deviation_WrongValidator() public {
        Session memory s = _canonical();
        s.sessionValidator = ISessionValidator(_addr("notOurValidator"));
        _expectMalformed(s);
    }

    /**
     * BOTH malformed-key variants. THIS PAIR IS THE POINT OF THE TEST.
     *
     * `validateConfig` is three-valued. A test covering only variant (a) passes against an
     * UNWRAPPED call and is therefore worthless — variant (b) is the one that proves the bare
     * `catch` exists, because without it the owner sees a raw `Panic(0x41)` from inside another
     * contract instead of `MalformedSessionShape()`.
     */
    function test_W24_Deviation_MalformedKeyConfig_BothVariants() public {
        // (a) validateConfig RETURNS FALSE — scheme 2 is reserved and unsupported.
        Session memory a = _canonical();
        a.sessionValidatorInitData = abi.encode(uint8(2), abi.encodePacked(AGENT));
        assertFalse(validator.validateConfig(a.sessionValidatorInitData), "precondition: returns false");
        _expectMalformed(a);

        // (b) validateConfig REVERTS — initData too short to decode as (uint8, bytes).
        Session memory b = _canonical();
        b.sessionValidatorInitData = hex"0102030405";
        (bool ok,) = address(validator)
            .staticcall(abi.encodeWithSelector(validator.validateConfig.selector, b.sessionValidatorInitData));
        assertFalse(ok, "precondition: validateConfig REVERTS on this input");
        _expectMalformed(b);

        // (c) a wrong key LENGTH also returns false (19-byte ECDSA key).
        Session memory c = _canonical();
        c.sessionValidatorInitData = abi.encode(uint8(0), new bytes(19));
        _expectMalformed(c);
    }

    /// Non-owner cannot grant.
    function test_W24_GrantIsOwnerOnly() public {
        Session memory s = _canonical();
        vm.prank(AGENT);
        vm.expectRevert(PushWalletErrors.NotOwner.selector);
        wallet.grantMandate(s);
    }

    /// grantMandate does NOT validate UCEP's config CONTENTS — that is UCEP's own job, and it fails
    /// closed at init. Here UCEP's init reverts on its own terms (zero asset), and the error that
    /// surfaces is UCEP's, NOT MalformedSessionShape: proof the shape check did not overreach.
    function test_W24_ShapeCheckDoesNotValidateUcepContents() public {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: _addr("p"), selector: bytes4(0x11223344), beneficiaryOffset: 0, hasBeneficiary: false, maxValue: 0
        });
        IUCEP.Config memory bad = IUCEP.Config({
            initialized: false,
            validUntil: uint48(block.timestamp + 1 days),
            destChainHash: bytes32(0),
            expectedCEA: _addr("cea"),
            asset: address(0), // UCEP's own guard rejects this
            maxAmountPerCall: 1,
            maxAmountTotal: 1,
            maxPCPerCall: 1,
            spent: 0,
            allowedCalls: rules
        });

        Session memory s = canonicalSession(ecdsaConfig(AGENT), abi.encode(bad));
        // UCEP's OWN error, surfacing through the engine — NOT MalformedSessionShape. Naming it is
        // the whole point of this test: it proves the shape check did not overreach into term
        // validation. UCEP reverts during initializeWithMultiplexer, which the engine does not
        // rewrap (the 32-byte PolicyCheckReverted rewrap is on the checkAction path), so this
        // arrives as itself.
        vm.prank(WALLET_OWNER);
        vm.expectRevert(IUCEP.InvalidConfigField.selector);
        wallet.grantMandate(s);
    }

    // ═══════════════════════════════════ W-17 ═══════════════════════════════════

    /**
     * W-17 — the salt. Supplying it is grantMandate's only other job.
     *
     * Byte-identical terms granted twice MUST yield two distinct ids, and a replaced id must never
     * recur. That is what makes a banked signed request die on regrant (op-hash field 5), which is
     * one of the four permanent guarantees of the whole system.
     */
    function test_W17_GrantSalt_Monotonic() public {
        assertEq(wallet.grantNonce(), 0, "starts at zero");

        Session memory s = _canonical();
        bytes32 pid1 = _grant(s);
        assertEq(wallet.grantNonce(), 1, "advanced");

        // BYTE-IDENTICAL terms, granted again
        bytes32 pid2 = _grant(_canonical());
        assertEq(wallet.grantNonce(), 2, "advanced again");

        assertTrue(pid1 != pid2, "identical terms yield DISTINCT ids");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid1), address(wallet)), "both live");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid2), address(wallet)), "both live");

        // A caller-supplied salt is IGNORED — overwritten by the counter.
        Session memory salted = _canonical();
        salted.salt = bytes32(uint256(0xDEADBEEF));
        bytes32 pid3 = _grant(salted);

        Session memory expected = _canonical();
        expected.salt = bytes32(uint256(2)); // the grantNonce value at that moment
        assertEq(pid3, PermissionId.unwrap(IdLib.toPermissionIdMemory(expected)), "salt came from the counter");
        assertTrue(pid3 != PermissionId.unwrap(IdLib.toPermissionIdMemory(salted)), "NOT the caller's salt");
    }

    /// A REPLACED id never recurs: revoke, regrant identical terms, and the new id differs.
    function test_W17_ReplacedIdNeverRecurs() public {
        bytes32 pid1 = _grant(_canonical());

        vm.prank(WALLET_OWNER);
        wallet.stopMandate(pid1);

        bytes32 pid2 = _grant(_canonical());
        assertTrue(pid1 != pid2, "the regranted mandate has a NEW id - banked signatures die here");
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pid1), address(wallet)), "old id is gone");
    }

    // ═══════════════════════════════════ W-15 ═══════════════════════════════════

    /// The loud-revocation guard. Upstream removeSession silently no-ops on ghost ids, and an
    /// incident operator must never read "revoked OK" while the mandate lives.
    function test_W15_StopMandate_GhostReverts() public {
        bytes32 ghost = keccak256("never granted");

        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnknownPermission.selector, ghost));
        wallet.stopMandate(ghost);
        assertEq(vm.getRecordedLogs().length, 0, "nothing emitted");

        // A typo'd id — one bit off a real one — is equally refused.
        bytes32 real = _grant(_canonical());
        bytes32 typo = bytes32(uint256(real) ^ 1);
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnknownPermission.selector, typo));
        wallet.stopMandate(typo);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(real), address(wallet)), "the real one survives");
    }

    /// An id belonging to ANOTHER wallet is a ghost here — isPermissionEnabled is account-scoped.
    function test_W15_OtherWalletsIdIsAGhost() public {
        PushAgentWallet other = newWallet(WALLET_OWNER);
        vm.prank(WALLET_OWNER);
        bytes32 theirs = other.grantMandate(_canonical());

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnknownPermission.selector, theirs));
        wallet.stopMandate(theirs);

        assertTrue(
            engine.isPermissionEnabled(PermissionId.wrap(theirs), address(other)), "still live on its own wallet"
        );
    }

    function test_StopMandate_IsOwnerOnly() public {
        bytes32 pid = _grant(_canonical());
        vm.prank(AGENT);
        vm.expectRevert(PushWalletErrors.NotOwner.selector);
        wallet.stopMandate(pid);
    }

    // ═══════════════════════════════════ W-16 ═══════════════════════════════════

    /// N permissions => N MandateRevoked events, and getPermissionIDs empty afterwards.
    function test_W16_StopAll_Empties() public {
        bytes32[] memory pids = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            pids[i] = _grant(_canonical());
        }
        assertEq(engine.getPermissionIDs(address(wallet)).length, 4, "four live");

        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        wallet.stopAll();

        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "all gone");
        for (uint256 i; i < 4; ++i) {
            assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pids[i]), address(wallet)), "each revoked");
        }

        // Exactly four MandateRevoked events, one per id.
        uint256 revoked;
        bytes32 topic = keccak256("MandateRevoked(bytes32)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wallet) && logs[i].topics[0] == topic) revoked++;
        }
        assertEq(revoked, 4, "one MandateRevoked per id");
    }

    /// stopAll on an empty wallet is a no-op, not a revert — incident response must never fail.
    function test_W16_StopAll_EmptyIsNoop() public {
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "nothing to stop");
        vm.prank(WALLET_OWNER);
        wallet.stopAll();
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "still nothing");
    }

    function test_StopAll_IsOwnerOnly() public {
        vm.prank(AGENT);
        vm.expectRevert(PushWalletErrors.NotOwner.selector);
        wallet.stopAll();
    }

    // ═══════════════════════════════════ W-10 ═══════════════════════════════════

    /**
     * W-10 — THE CANONICAL PERMISSION-CHANGE FLOW, in ONE owner signature, ONE execute batch.
     *
     * There is no "reconfigure". Change is atomic revoke-and-regrant:
     *     UCEP.assertSpent(old) -> stopMandate(old) -> grantMandate(new) -> approval payload
     *
     * The two lifecycle legs target the WALLET, so they arrive with `msg.sender == address(this)`
     * and reach `onlyOwnerOrSelf`. That modifier exists for exactly this batch (ruling A).
     *
     * assertSpent goes FIRST and is the race guard: if a spend — or a credit — landed between the
     * owner reading the counter and submitting, the whole batch reverts and the owner recomposes.
     * Atomicity matters in BOTH directions, which is why both failure legs are tested below.
     */
    function test_W10_OwnerBatch_CanonicalChangeFlow() public {
        bytes32 oldPid = _grant(_canonical());
        bytes32 configId = _configIdFor(oldPid);

        address token = makeAddr("someToken");
        etchCallRecorder(token);
        vm.store(token, bytes32(uint256(0)), bytes32(0));

        Execution[] memory batch = _changeBatch(configId, oldPid, 0, token);

        vm.prank(WALLET_OWNER);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(batch));

        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(oldPid), address(wallet)), "old revoked");
        assertEq(engine.getPermissionIDs(address(wallet)).length, 1, "exactly one live mandate after the swap");
        assertEq(wallet.grantNonce(), 2, "the replacement was granted");
        assertEq(callsRecorded(token), 1, "the approval leg ran");
    }

    /// @dev The four-leg change batch: race guard, revoke, regrant, approval.
    function _changeBatch(bytes32 configId, bytes32 oldPid, uint256 believedSpent, address token)
        internal
        view
        returns (Execution[] memory batch)
    {
        batch = new Execution[](4);
        batch[0] = Execution({
            target: address(ucep),
            value: 0,
            callData: abi.encodeCall(UCEP.assertSpent, (ConfigId.wrap(configId), address(wallet), believedSpent))
        });
        batch[1] = Execution({
            target: address(wallet), value: 0, callData: abi.encodeCall(PushAgentWallet.stopMandate, (oldPid))
        });
        batch[2] = Execution({
            target: address(wallet), value: 0, callData: abi.encodeCall(PushAgentWallet.grantMandate, (_canonical()))
        });
        batch[3] = Execution({
            target: token,
            value: 0,
            callData: abi.encodeWithSignature("approve(address,uint256)", _addr("spender"), uint256(1 ether))
        });
    }

    /// A STALE assertSpent reverts the WHOLE batch — nothing moves. This is the half that makes the
    /// race guard worth having.
    function test_W10_StaleAssertSpent_RevertsTheWholeBatch() public {
        bytes32 oldPid = _grant(_canonical());
        bytes32 configId = _configIdFor(oldPid);

        address token = makeAddr("someToken");
        etchCallRecorder(token);
        vm.store(token, bytes32(uint256(0)), bytes32(0));

        // the owner believes 5 ether has been spent; the real figure is 0
        Execution[] memory batch = _changeBatch(configId, oldPid, 5 ether, token);

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(IUCEP.SpentMismatch.selector, uint256(5 ether), uint256(0)));
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(batch));

        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(oldPid), address(wallet)), "old permission INTACT");
        assertEq(engine.getPermissionIDs(address(wallet)).length, 1, "no new mandate was created");
        assertEq(wallet.grantNonce(), 1, "the grant counter did not advance");
        assertEq(callsRecorded(token), 0, "the approval was NOT made");
    }

    /// And atomicity in the other direction: a failing LAST leg unwinds the revoke and the regrant
    /// that already succeeded before it.
    function test_W10_FailingApprovalLeg_UnwindsTheWholeChange() public {
        bytes32 oldPid = _grant(_canonical());
        bytes32 configId = _configIdFor(oldPid);

        // a token whose approve() reverts
        address token = makeAddr("revertingToken");
        vm.etch(token, type(RevertingApproval).runtimeCode);

        Execution[] memory batch = _changeBatch(configId, oldPid, 0, token);

        vm.prank(WALLET_OWNER);
        vm.expectRevert(RevertingApproval.ApprovalRejected.selector);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(batch));

        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(oldPid), address(wallet)), "old permission INTACT");
        assertEq(engine.getPermissionIDs(address(wallet)).length, 1, "the replacement was unwound");
        assertEq(wallet.grantNonce(), 1, "the grant counter did not advance");
    }

    /// The self-call path is genuinely open now, and only to the wallet itself: an arbitrary caller
    /// impersonating neither the owner nor the wallet is still refused.
    function test_W10_SelfCallPath_IsNotOpenToAnyoneElse() public {
        bytes32 pid = _grant(_canonical());

        vm.prank(AGENT);
        vm.expectRevert(PushWalletErrors.NotOwner.selector);
        wallet.stopMandate(pid);

        vm.prank(address(engine));
        vm.expectRevert(PushWalletErrors.NotOwner.selector);
        wallet.stopAll();
    }

    /// @dev configId = keccak256(abi.encodePacked(account, actionPolicyId)), where
    ///      actionPolicyId = keccak256(abi.encodePacked(permissionId, actionId)) and
    ///      actionId = keccak256(abi.encodePacked(target, selector)).  IdLib.sol:19,30,41 —
    ///      encodePacked at all three layers, while permissionId above uses abi.encode.
    function _configIdFor(bytes32 permissionId) internal view returns (bytes32) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(permissionId, actionId));
        return keccak256(abi.encodePacked(address(wallet), actionPolicyId));
    }

    // ═══════════════════════════════════ W-23 ═══════════════════════════════════

    /// The lifecycle half of the attribution record.
    function test_W23_Events_Attribution_Lifecycle() public {
        // grant
        vm.recordLogs();
        bytes32 pid = _grant(_canonical());
        Vm.Log[] memory grantLogs = vm.getRecordedLogs();
        bool sawGrant;
        for (uint256 i; i < grantLogs.length; ++i) {
            if (
                grantLogs[i].emitter == address(wallet)
                    && grantLogs[i].topics[0] == keccak256("MandateGranted(bytes32)")
            ) {
                assertEq(grantLogs[i].topics[1], pid, "MandateGranted carries the returned id");
                sawGrant = true;
            }
        }
        assertTrue(sawGrant, "MandateGranted emitted");

        // revoke
        vm.expectEmit(true, true, true, true, address(wallet));
        emit PushAgentWallet.MandateRevoked(pid);
        vm.prank(WALLET_OWNER);
        wallet.stopMandate(pid);
    }

    // ═══════════════════════════════════ U-19 ═══════════════════════════════════

    /**
     * U-19 (deferred from Phase 1 — it needed removeSession on a real wallet).
     *
     * Configs are NEVER deleted. Upstream `removeSession` is pure storage deletion on the engine's
     * side and calls no policy de-init, so a revoked permission's UCEP config persists as inert
     * orphan data. This is HARMLESS AND DOCUMENTED, not a leak to "fix": the permission id can
     * never validate again, so the orphan config is unreachable through the agent door.
     *
     * A creditRevert arriving after revocation still lands on that orphan — also correct: the
     * accounting record survives the permission.
     */
    function test_U19_ConfigOrphan_Harmless() public {
        bytes32 pid = _grant(_canonical());
        bytes32 configId = _configIdFor(pid);

        // the config exists and is initialised
        IUCEP.Config memory before = ucep.getConfig(ConfigId.wrap(configId), address(wallet));
        assertTrue(before.initialized, "UCEP config written during the grant");
        assertEq(before.asset, _addr("prc20"), "and carries the terms");

        vm.prank(WALLET_OWNER);
        wallet.stopMandate(pid);

        // the permission validates nothing any more
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "permission gone");

        // ...but the config PERSISTS and getConfig still reads it
        IUCEP.Config memory orphan = ucep.getConfig(ConfigId.wrap(configId), address(wallet));
        assertTrue(orphan.initialized, "the config persists as inert orphan data");
        assertEq(orphan.asset, before.asset, "unchanged");
        assertEq(orphan.maxAmountTotal, before.maxAmountTotal, "unchanged");
        assertEq(orphan.allowedCalls.length, before.allowedCalls.length, "including the allow-list");

        // and a late credit still lands on it, harmlessly
        vm.prank(EXECUTOR_MODULE);
        ucep.creditRevert(ConfigId.wrap(configId), address(wallet), keccak256("late"), 1 ether);
        assertEq(ucep.getConfig(ConfigId.wrap(configId), address(wallet)).spent, 0, "saturated, harmless");

        // The orphan is NOT reusable: re-initialising that config id is refused.
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IUCEP.AlreadyInitialized.selector, ConfigId.wrap(configId)));
        ucep.initializeWithMultiplexer(address(wallet), ConfigId.wrap(configId), _ucepInitData());
    }
}

/// @dev A token whose approve() reverts, for the failing-last-leg atomicity test.
contract RevertingApproval {
    error ApprovalRejected();

    fallback() external {
        revert ApprovalRejected();
    }
}
