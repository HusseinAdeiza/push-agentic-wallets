// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";

import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";

import { AllowedCall, Config, NativeConfig, RulesType } from "../../src/libraries/Types.sol";

import { AGW } from "../../src/AGW.sol";

import { IAGW } from "../../src/interfaces/IAGW.sol";

import { AGWErrors } from "../../src/libraries/Errors.sol";

import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";

import { UniversalRulesPolicy } from "../../src/policies/UniversalRulesPolicy.sol";

import { Session, PermissionId, ConfigId, ActionData, PolicyData, ERC7739Context } from "smartsessions/DataTypes.sol";

import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { IdLib } from "smartsessions/lib/IdLib.sol";

/**
 * @notice AGW — Phase 3b: the mandate lifecycle.
 *         grantRules (§6.3) · revokeRules (§6.4) · revokeAllRules (§6.5).
 *
 * @dev    grantRules does EXACTLY TWO JOBS: the canonical-shape check, and the salt. Everything
 *         about URP's config CONTENTS is URP's own business and is deliberately untested here —
 *         Phase 1 covers it.
 */
contract PushAgentWalletLifecycleTest is BaseTest {
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

    function _addr(string memory label) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(label)))));
    }

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
                maxGasPerCall: 5 ether,
                assets: oneAsset(PRC20, 100 ether, 1000 ether),
                allowedCalls: rules
            })
        );
    }

    /// @dev THE canonical session — the only shape v3 permits.
    function _canonical() internal view returns (Session memory) {
        return canonicalSession(agentConfig(AGENT), _urpInitData());
    }

    function _grant(Session memory s) internal returns (bytes32) {
        vm.prank(WALLET_OWNER);
        return wallet.grantRules(s);
    }

    /// @dev Assert a deviation is refused with the ONE error the shape check ever raises.
    function _expectMalformed(Session memory s) internal {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        wallet.grantRules(s);
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
        s.userOpPolicies[0] = PolicyData({ policy: address(urp), initData: "" });
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
        s.erc7739Policies.erc1271Policies[0] = PolicyData({ policy: address(urp), initData: "" });
        _expectMalformed(s);
    }

    /// Rule 5: dead surface, and paymasterAndData is always empty anyway.
    function test_W24_Deviation_PaymasterTrue() public {
        Session memory s = _canonical();
        s.permitERC4337Paymaster = true;
        _expectMalformed(s);
    }

    /**
     * Rule 1: a mandate must authorise at least one action.
     *
     * THE ERROR CHANGED ON 2026-09-17 AND THE "PRESERVED VERBATIM" NOTE THIS CARRIED IS GONE WITH
     * IT, because it is no longer true. Zero actions is now `TooManyActions(0)` rather than
     * `MalformedSessionShape`, for both modes, and the reason is structural rather than cosmetic:
     * the mode is derived from action 0's policy envelope, so with no actions there is no envelope,
     * no chain, and therefore no mode to report a shape violation against. The count check must run
     * before the derivation, so it answers first.
     *
     * The one-action rule under UNIVERSAL is unchanged and still `MalformedSessionShape` — see
     * `test_W24_Deviation_TwoActions`.
     */
    function test_W24_Deviation_ZeroActions() public {
        Session memory s = _canonical();
        s.actions = new ActionData[](0);

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.TooManyActions.selector, uint256(0)));
        wallet.grantRules(s);
    }

    /// ⚠️ THE ASSERTION §8.2 REQUIRES BE PRESERVED. Under `UNIVERSAL` a second action is still
    /// `MalformedSessionShape`. Only `NATIVE` admits more than one, and it admits at most eight.
    function test_W24_Deviation_TwoActions() public {
        Session memory s = _canonical();
        ActionData[] memory actions = new ActionData[](2);
        actions[0] = s.actions[0];
        actions[1] = s.actions[0];
        s.actions = actions;
        _expectMalformed(s);
    }

    // ─────────────────── W-24, the NATIVE branch (added 2026-09-09) ───────────────────

    /// @dev A native action on an arbitrary Push-side target, carrying the canonical policy.
    function _nativeAction(address target, bytes4 selector) internal view returns (ActionData memory) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: _nativeInitDataFor(target, selector) });
        return ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: ps });
    }

    function _nativeInitDataFor(address target, bytes4 selector) internal view returns (bytes memory) {
        NativeConfig memory cfg;
        cfg.validUntil = uint48(block.timestamp + 365 days);
        cfg.target = target;
        cfg.selector = selector;
        return nativeInitData(cfg);
    }

    function _nativeSession(ActionData[] memory actions) internal view returns (Session memory s) {
        s = _canonical();
        s.actions = actions;
    }

    function _grantNative(Session memory s) internal returns (bytes32) {
        vm.prank(WALLET_OWNER);
        return wallet.grantRules(s);
    }

    /// One action is a legal native mandate.
    function test_W24_Native_OneActionGrants() public {
        ActionData[] memory a = new ActionData[](1);
        a[0] = _nativeAction(_addr("stakeDummy"), bytes4(keccak256("stake(uint256)")));
        bytes32 pid = _grantNative(_nativeSession(a));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "one native action grants");
    }

    /// And so are eight — the ceiling, inclusive.
    function test_W24_Native_EightActionsGrant() public {
        ActionData[] memory a = new ActionData[](8);
        for (uint256 i; i < 8; ++i) {
            a[i] = _nativeAction(_addr(string(abi.encodePacked("proto", i))), bytes4(uint32(0x11000000 + i)));
        }
        bytes32 pid = _grantNative(_nativeSession(a));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "eight native actions grant");
    }

    function test_W24_Native_ZeroActionsRejected() public {
        Session memory s = _nativeSession(new ActionData[](0));
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.TooManyActions.selector, uint256(0)));
        wallet.grantRules(s);
    }

    function test_W24_Native_NineActionsRejected() public {
        ActionData[] memory a = new ActionData[](9);
        for (uint256 i; i < 9; ++i) {
            a[i] = _nativeAction(_addr(string(abi.encodePacked("proto", i))), bytes4(uint32(0x11000000 + i)));
        }
        Session memory s = _nativeSession(a);
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.TooManyActions.selector, uint256(9)));
        wallet.grantRules(s);
    }

    /// The same (target, selector) twice would hash to one actionId.
    function test_W24_Native_DuplicateActionRejected() public {
        address t = _addr("stakeDummy");
        bytes4 sel = bytes4(keccak256("stake(uint256)"));
        ActionData[] memory a = new ActionData[](2);
        a[0] = _nativeAction(t, sel);
        a[1] = _nativeAction(t, sel);

        Session memory s = _nativeSession(a);
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.DuplicateAction.selector, t, sel));
        wallet.grantRules(s);
    }

    /// The COMMON rules apply identically to both types.
    function test_W24_Native_CommonRulesStillApply() public {
        ActionData[] memory a = new ActionData[](1);
        a[0] = _nativeAction(_addr("stakeDummy"), bytes4(keccak256("stake(uint256)")));

        Session memory s = _nativeSession(a);
        s.permitERC4337Paymaster = true;
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        wallet.grantRules(s);
    }

    /// A wrong POLICY is `MalformedSessionShape` in BOTH modes — the invariant, stated once.
    function test_W24_Native_WrongPolicyIsMalformed() public {
        UniversalRulesPolicy otherUrp = new UniversalRulesPolicy();
        address t = _addr("stakeDummy");
        bytes4 sel = bytes4(keccak256("stake(uint256)"));

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(otherUrp), initData: _nativeInitDataFor(t, sel) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: sel, actionTarget: t, actionPolicies: ps });

        Session memory s = _nativeSession(a);
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        wallet.grantRules(s);
    }

    /**
     * ⚠️ SEMANTIC REWRITE, 2026-09-09 (§8.2). Same name, same intent, a more precise error.
     *
     * A target wrong FOR THE DECLARED TYPE is now `RulesTypeMismatch`, not
     * `MalformedSessionShape` — the wallet can say WHICH action was wrong and what it named, which
     * matters once a mandate may hold eight of them. The rule is unchanged: a `UNIVERSAL` mandate
     * may name nothing but the gateway.
     */
    function test_W24_Deviation_WrongTarget() public {
        Session memory s = _canonical();
        address wrong = _addr("notTheGateway");
        s.actions[0].actionTarget = wrong;

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.RulesTypeMismatch.selector, RulesType.UNIVERSAL, uint256(0), wrong)
        );
        wallet.grantRules(s);
    }

    /// Same rewrite: the gateway with the wrong selector is still a type mismatch, and the reported
    /// target is the gateway — which is what tells an integrator the SELECTOR was the problem.
    function test_W24_Deviation_WrongSelector() public {
        Session memory s = _canonical();
        s.actions[0].actionTargetSelector = bytes4(keccak256("somethingElse()"));

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.RulesTypeMismatch.selector, RulesType.UNIVERSAL, uint256(0), GATEWAY)
        );
        wallet.grantRules(s);
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

    /// A policy that is not URP — built with sessionWithPolicy, the harness helper that exists
    /// precisely so a negative test cannot accidentally use the canonical wiring.
    function test_W24_Deviation_WrongPolicyAddress() public {
        // Only its ADDRESS matters — the wallet rejects any policy that is not the canonical one
        // before it ever calls it, so this needs no proxy and no initialisation.
        UniversalRulesPolicy otherUrp = new UniversalRulesPolicy();
        Session memory s = sessionWithPolicy(address(otherUrp), agentConfig(AGENT), _urpInitData());
        _expectMalformed(s);
    }

    function test_W24_Deviation_WrongValidator() public {
        Session memory s = _canonical();
        s.sessionValidator = ISessionValidator(_addr("notOurValidator"));
        _expectMalformed(s);
    }

    /**
     * Every malformed agent config is refused `MalformedSessionShape`.
     *
     * The canonical validator's `validateConfig` is two-valued and never reverts, so every malformed
     * config takes the `false` branch. The wallet's bare `catch` around that call is retained
     * defensively — it guards a future validator that might revert — and is expected to show as
     * uncovered.
     */
    function test_W24_Deviation_MalformedKeyConfig_BothVariants() public {
        bytes[] memory configs = new bytes[](7);
        configs[0] = abi.encode(address(0));
        configs[1] = "";
        configs[2] = hex"0102030405";
        configs[3] = new bytes(31);
        configs[4] = new bytes(33);
        configs[5] = abi.encode(AGENT, AGENT);
        configs[6] = abi.encodePacked(uint256(0xff) << 248 | uint256(uint160(AGENT))); // dirty upper bytes

        for (uint256 i; i < configs.length; ++i) {
            Session memory s = _canonical();
            s.sessionValidatorInitData = configs[i];
            assertFalse(validator.validateConfig(configs[i]), "precondition: returns false, does not revert");
            _expectMalformed(s);
        }
    }

    /// Non-owner cannot grant.
    function test_W24_GrantIsOwnerOnly() public {
        Session memory s = _canonical();
        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.grantRules(s);
    }

    /// grantRules does NOT validate URP's config CONTENTS — that is URP's own job, and it fails
    /// closed at init. Here URP's init reverts on its own terms (zero asset), and the error that
    /// surfaces is URP's, NOT MalformedSessionShape: proof the shape check did not overreach.
    function test_W24_ShapeCheckDoesNotValidateUrpContents() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: _addr("p"), selector: bytes4(0x11223344), beneficiaryOffset: 0, hasBeneficiary: false, maxValue: 0
        });
        Config memory bad = Config({
            initialized: false,
            validUntil: uint48(block.timestamp + 1 days),
            destChainHash: bytes32(0),
            expectedCEA: _addr("cea"),
            maxGasPerCall: 1,
            assets: oneAsset(address(0), 1, 1), // URP's own guard rejects this
            allowedCalls: rules
        });

        // Correctly WRAPPED — the point of this test is that URP's own TERM guard fires, so the
        // config has to get past the mode decoder to reach it. A bare `abi.encode(bad)` would now
        // die at `InvalidPolicyMode` instead and the test would prove nothing about overreach.
        Session memory s = canonicalSession(agentConfig(AGENT), universalInitData(bad));
        // URP's OWN error, surfacing through the engine — NOT MalformedSessionShape. Naming it is
        // the whole point of this test: it proves the shape check did not overreach into term
        // validation. URP reverts during initializeWithMultiplexer, which the engine does not
        // rewrap (the 32-byte PolicyCheckReverted rewrap is on the checkAction path), so this
        // arrives as itself.
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidAsset.selector, address(0)));
        wallet.grantRules(s);
    }

    // ═══════════════════════════════════ W-17 ═══════════════════════════════════

    /**
     * W-17 — the salt. Supplying it is grantRules's only other job.
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
        wallet.revokeRules(pid1);

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
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnknownPermission.selector, ghost));
        wallet.revokeRules(ghost);
        assertEq(vm.getRecordedLogs().length, 0, "nothing emitted");

        // A typo'd id — one bit off a real one — is equally refused.
        bytes32 real = _grant(_canonical());
        bytes32 typo = bytes32(uint256(real) ^ 1);
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnknownPermission.selector, typo));
        wallet.revokeRules(typo);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(real), address(wallet)), "the real one survives");
    }

    /// An id belonging to ANOTHER wallet is a ghost here — isPermissionEnabled is account-scoped.
    function test_W15_OtherWalletsIdIsAGhost() public {
        AGW other = newWallet(WALLET_OWNER);
        vm.prank(WALLET_OWNER);
        bytes32 theirs = other.grantRules(_canonical());

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.UnknownPermission.selector, theirs));
        wallet.revokeRules(theirs);

        assertTrue(
            engine.isPermissionEnabled(PermissionId.wrap(theirs), address(other)), "still live on its own wallet"
        );
    }

    function test_StopMandate_IsOwnerOnly() public {
        bytes32 pid = _grant(_canonical());
        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeRules(pid);
    }

    // ═══════════════════════════════════ W-16 ═══════════════════════════════════

    /// N permissions => N RulesRevoked events, and getPermissionIDs empty afterwards.
    function test_W16_StopAll_Empties() public {
        bytes32[] memory pids = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            pids[i] = _grant(_canonical());
        }
        assertEq(engine.getPermissionIDs(address(wallet)).length, 4, "four live");

        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        wallet.revokeAllRules();

        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "all gone");
        for (uint256 i; i < 4; ++i) {
            assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pids[i]), address(wallet)), "each revoked");
        }

        // Exactly four RulesRevoked events, one per id.
        uint256 revoked;
        bytes32 topic = keccak256("RulesRevoked(bytes32)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wallet) && logs[i].topics[0] == topic) revoked++;
        }
        assertEq(revoked, 4, "one RulesRevoked per id");
    }

    /// revokeAllRules on an empty wallet is a no-op, not a revert — incident response must never fail.
    function test_W16_StopAll_EmptyIsNoop() public {
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "nothing to stop");
        vm.prank(WALLET_OWNER);
        wallet.revokeAllRules();
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "still nothing");
    }

    function test_StopAll_IsOwnerOnly() public {
        vm.prank(AGENT);
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeAllRules();
    }

    // ═══════════════════════════════════ W-10 ═══════════════════════════════════

    /**
     * W-10 — THE CANONICAL PERMISSION-CHANGE FLOW, in ONE owner signature, ONE execute batch.
     *
     * There is no "reconfigure". Change is atomic revoke-and-regrant:
     *     URP.assertSpent(old) -> revokeRules(old) -> grantRules(new) -> approval payload
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
            target: address(urp),
            value: 0,
            // `assertSpent` is overloaded since native mode landed, and `abi.encodeCall` cannot
            // disambiguate a function reference by arity. Encode the universal (per-asset array)
            // form by its explicit signature instead.
            callData: abi.encodeWithSignature(
                "assertSpent(bytes32,address,uint256[])", configId, address(wallet), oneSpent(believedSpent)
            )
        });
        batch[1] = Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.revokeRules, (oldPid)) });
        batch[2] =
            Execution({ target: address(wallet), value: 0, callData: abi.encodeCall(AGW.grantRules, (_canonical())) });
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
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.AssetSpentMismatch.selector, PRC20, uint256(5 ether), uint256(0)
            )
        );
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
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeRules(pid);

        vm.prank(address(engine));
        vm.expectRevert(AGWErrors.CallerIsNotOwner.selector);
        wallet.revokeAllRules();
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
                    && grantLogs[i].topics[0] == keccak256("RulesGranted(bytes32,uint8,bytes32,string)")
            ) {
                assertEq(grantLogs[i].topics[1], pid, "RulesGranted carries the returned id");
                assertEq(grantLogs[i].topics[2], keccak256(bytes(CHAIN_SEPOLIA)), "and the chain it was granted for");
                // The type and the chain string are unindexed, so they land in `data`.
                (uint8 mode, string memory chain) = abi.decode(grantLogs[i].data, (uint8, string));
                assertEq(mode, uint8(RulesType.UNIVERSAL), "RulesGranted carries the DERIVED type");
                assertEq(chain, CHAIN_SEPOLIA, "and the chain string, for human readers");
                sawGrant = true;
            }
        }
        assertTrue(sawGrant, "RulesGranted emitted");

        // revoke
        vm.expectEmit(true, true, true, true, address(wallet));
        emit IAGW.RulesRevoked(pid);
        vm.prank(WALLET_OWNER);
        wallet.revokeRules(pid);
    }

    // ═══════════════════════════════════ U-19 ═══════════════════════════════════

    /**
     * U-19 (deferred from Phase 1 — it needed removeSession on a real wallet).
     *
     * Configs are NEVER deleted. Upstream `removeSession` is pure storage deletion on the engine's
     * side and calls no policy de-init, so a revoked permission's URP config persists as inert
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
        Config memory before = urp.getConfig(ConfigId.wrap(configId), address(wallet));
        assertTrue(before.initialized, "URP config written during the grant");
        assertEq(before.assets[0].token, PRC20, "and carries the terms");

        vm.prank(WALLET_OWNER);
        wallet.revokeRules(pid);

        // the permission validates nothing any more
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "permission gone");

        // ...but the config PERSISTS and getConfig still reads it
        Config memory orphan = urp.getConfig(ConfigId.wrap(configId), address(wallet));
        assertTrue(orphan.initialized, "the config persists as inert orphan data");
        assertEq(orphan.assets[0].token, before.assets[0].token, "unchanged");
        assertEq(orphan.assets[0].maxTotal, before.assets[0].maxTotal, "unchanged");
        assertEq(orphan.allowedCalls.length, before.allowedCalls.length, "including the allow-list");

        // and a late credit still lands on it, harmlessly
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(ConfigId.wrap(configId), address(wallet), keccak256("late"), PRC20, 1 ether);
        assertEq(urp.getConfig(ConfigId.wrap(configId), address(wallet)).assets[0].spent, 0, "saturated, harmless");

        // The orphan is NOT reusable: re-initialising that config id is refused.
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, ConfigId.wrap(configId))
        );
        urp.initializeWithMultiplexer(address(wallet), ConfigId.wrap(configId), _urpInitData());
    }
}

/// @dev A token whose approve() reverts, for the failing-last-leg atomicity test.
contract RevertingApproval {
    error ApprovalRejected();

    fallback() external {
        revert ApprovalRejected();
    }
}
