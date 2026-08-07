// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MandateFixture, IAavePool } from "../helpers/MandateFixture.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ACPActionPolicy, AllowedCall, Config } from "../../src/policies/ACPActionPolicy.sol";

import { ISmartSession } from "smartsessions/ISmartSession.sol";
import { Session, PolicyData, ActionData, PermissionId, ConfigId } from "smartsessions/DataTypes.sol";
import { SudoPolicy } from "smartsessions/external/policies/SudoPolicy.sol";
import { TimeFrameConfig, TimeFrameConfigLib } from "smartsessions/external/policies/TimeFramePolicy.sol";

/**
 * @notice v2 Steps 4–6 — mandate lifecycle (T-09 … T-32).
 *
 * @dev These tests exist because upstream `enableSessions` is SILENT on every failure
 *      mode a shared one-wallet-per-user account cares about: it accepts duplicate
 *      PermissionIds (overwriting caps), non-expiring sessions, wildcard action slots,
 *      and actions carrying the wrong policy set. `grantMandate` is the gate that turns
 *      each of those into a revert.
 */
contract MandateLifecycleTest is MandateFixture {
    using TimeFrameConfigLib for TimeFrameConfig;

    event MandateGranted(bytes32 indexed permissionId, bytes32 indexed mandateId);
    event MandateRevoked(bytes32 indexed permissionId);
    event MandateReconfigured(bytes32 indexed permissionId);
    event DanglingSessionsPurged(uint256 removed, uint256 remaining);

    function setUp() public {
        _deployStack();
    }

    // ── T-09 / T-10 — grant works and tracks IdLib ────────────────────

    function test_T09_grantEmitsAndEnables() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        _installSmartSession();

        vm.expectEmit(true, true, false, false);
        emit MandateGranted(_expectedPid(s), mandateA);

        vm.prank(ownerUEA);
        bytes32 pid = wallet.grantMandate(s);

        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
    }

    /**
     * T-10 — MIRROR-VALIDITY GATE. NEVER DELETE.
     *
     * The wallet's `_permissionId` must equal the PermissionId SmartSession itself
     * derives. If upstream ever changes `IdLib.toPermissionId`, every guard in
     * `grantMandate` would be validating a different session than the one enabled — a
     * silent, total bypass. `grantMandate` asserts this inline; this test proves the
     * assertion is meaningful rather than tautological.
     */
    function test_T10_walletPidMatchesSmartSession() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        bytes32 pid = _grant(s);

        assertEq(pid, _expectedPid(s), "wallet pid must equal IdLib derivation");
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
    }

    // ── T-11 … T-14 — the duplicate-grant defect ──────────────────────

    function test_T11_duplicateGrantReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        bytes32 pid = _grant(s);

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.MandateAlreadyExists.selector, pid));
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    function test_T12_zeroSaltReverts() public {
        Session memory s = _session(bytes32(0), agentKey, type(uint256).max);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.InvalidMandateId.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    function test_T13_grantBeforeInstallReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);

        vm.expectRevert(PushWalletErrors.SessionModuleNotInstalled.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /**
     * T-14 — THE DEFECT THIS CLOSES.
     *
     * Grant mandate A with a 100e6 ceiling, spend against it, then attempt a second grant
     * with the SAME (validator, key, salt) but a 500e6 ceiling. Without `grantMandate`
     * this overwrite is SILENT: `$enabledSessions.add` is idempotent and
     * `ConfigLib.enable` re-runs `initializeWithMultiplexer`, whose `_store` resets
     * `spent` to zero and replaces every cap. An agent that exhausted its mandate could
     * be handed a fresh, larger one without the user signing anything new.
     */
    function test_T14_duplicateGrantCannotSilentlyRaiseCap() public {
        Session memory s = _session(mandateA, agentKey, 100e6);
        bytes32 pid = _grant(s);

        _executeSession(pid, agentPk, expectedCEA, 60e6, 0);

        ConfigId cid = _acpConfigId(pid);
        (,,,,, uint256 totalBefore,, uint256 spentBefore,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(totalBefore, 100e6);
        assertEq(spentBefore, 60e6);

        // The laundering attempt.
        Session memory bigger = _session(mandateA, agentKey, 500e6);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.MandateAlreadyExists.selector, pid));
        vm.prank(ownerUEA);
        wallet.grantMandate(bigger);

        (,,,,, uint256 totalAfter,, uint256 spentAfter,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(totalAfter, 100e6, "cap must be untouched");
        assertEq(spentAfter, 60e6, "spent must be untouched");
    }

    // ── T-15 … T-19 — bounded-session guards ──────────────────────────

    function test_T15_missingTimeFramePolicyReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        s.userOpPolicies = new PolicyData[](0);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.MissingTimeFramePolicy.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev A-11. `validUntil == 0` means NO EXPIRY upstream, which on the user's only
    ///      wallet is a permanent unrevoked key.
    function test_T16_nonExpiringSessionReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        s.userOpPolicies = _timeFramePolicies(0, 12);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.NonExpiringSessionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /**
     * T-16b — ENCODING CROSS-CHECK. NEVER DELETE.
     *
     * Our guard reads `validUntil` from `initData[0:6]`. TimeFramePolicy reads
     * `uint96(bytes12(initData[0:12]))` and takes `unwrap >> 48`. Those agree only while
     * `validUntil` occupies the HIGH 6 bytes. This test pins our decode against the
     * policy's OWN getter, so if the initData layout ever changes at a future pin this
     * fails loudly instead of T-16 passing vacuously (a vacuous A-11 guard would let a
     * permanent key through).
     */
    function test_T16b_ourDecodeMatchesPolicyDecode() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        bytes32 pid = _grant(s);

        TimeFrameConfig cfg = timeFrame.getTimeFrameConfig(_userOpConfigId(pid), address(smartSession), address(wallet));

        assertEq(cfg.validUntil(), VALID_UNTIL, "policy must read the value our guard checked");
        assertEq(cfg.validAfter(), 0);

        // And the raw blob our guard inspects agrees.
        bytes memory raw = abi.encodePacked(VALID_UNTIL, uint48(0));
        assertEq(uint48(bytes6(_first6(raw))), VALID_UNTIL, "guard reads the HIGH 6 bytes");
    }

    function test_T17_shortTimeFrameInitDataReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        s.userOpPolicies = _timeFramePolicies(VALID_UNTIL, 11);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.MalformedPolicyInitData.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    function test_T18_missingValueLimitPolicyReverts() public {
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.withValueLimit = false;
        Session memory s = _sessionFull(spec);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.MissingValueLimitPolicy.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    function test_T19_shortValueLimitInitDataReverts() public {
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        s.actions[0].actionPolicies[1].initData = hex"deadbeef"; // 4 bytes, not 32
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.MalformedPolicyInitData.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev Q9 — a well-formed but ZERO limit is rejected here with a clean error rather
    ///      than three calls deep as an opaque `PolicyNotInitialized`.
    function test_T19b_zeroValueLimitReverts() public {
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.vLimit = 0;
        Session memory s = _sessionFull(spec);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.ZeroValueLimit.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    // ── T-20 … T-24 — the three wildcards (A-14) ──────────────────────

    /**
     * T-20 — W-1. A fallback ActionId's policies apply to EVERY unregistered
     * (target, selector). Built here WITH SudoPolicy attached to show what is being
     * denied: a session that could call anything, with ACP never running.
     */
    function test_T20_fallbackActionForbidden() public {
        SudoPolicy sudo = new SudoPolicy();
        Session memory s = _session(mandateA, agentKey, type(uint256).max);
        s.actions[0].actionTarget = address(1); // FALLBACK_TARGET_FLAG
        s.actions[0].actionPolicies = new PolicyData[](1);
        s.actions[0].actionPolicies[0] = PolicyData({ policy: address(sudo), initData: "" });
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.FallbackActionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev T-21 — W-2. SmartSession as a target maps to
    ///      FALLBACK_ACTIONID_SMARTSESSION_CALL, exposing enableSessions / removeSession.
    function test_T21_smartSessionActionForbidden() public {
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.actionTarget = address(smartSession);
        Session memory s = _sessionFull(spec);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.SmartSessionActionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev T-22 — G3a. Any non-gateway target is out of v2.0 scope (P-5, F-25).
    function test_T22_nonGatewayTargetForbidden() public {
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.actionTarget = usdc;
        Session memory s = _sessionFull(spec);
        _installSmartSession();

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ActionTargetNotGateway.selector, usdc));
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev T-23 — W-3. `minPolicies == 1` upstream is satisfied by TimeFramePolicy alone,
    ///      which would leave every ACP rule unenforced.
    function test_T23_gatewayActionWithoutACPReverts() public {
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.withACP = false;
        spec.withValueLimit = false;
        Session memory s = _sessionFull(spec);
        _installSmartSession();

        vm.expectRevert(PushWalletErrors.GatewayActionMissingACP.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(s);
    }

    /// @dev T-24 — Q8. Zero actions AND two actions both rejected. Two gateway actions
    ///      collapse to one ConfigId, so the second `initializeWithMultiplexer` overwrites
    ///      the first: a tight entry followed by a loose one would let the loose one win
    ///      by array position.
    function test_T24_exactlyOneActionRequired() public {
        _installSmartSession();

        Session memory none = _session(mandateA, agentKey, type(uint256).max);
        none.actions = new ActionData[](0);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ExactlyOneActionRequired.selector, uint256(0)));
        vm.prank(ownerUEA);
        wallet.grantMandate(none);

        Session memory two = _session(mandateA, agentKey, type(uint256).max);
        ActionData[] memory dup = new ActionData[](2);
        dup[0] = two.actions[0];
        // Same (target, selector) but a LOOSER cap: the overwrite shape.
        Session memory loose = _session(mandateA, agentKey, type(uint256).max);
        loose.actions[0].actionPolicies[0].initData = _acpConfig(type(uint256).max);
        dup[1] = loose.actions[0];
        two.actions = dup;

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ExactlyOneActionRequired.selector, uint256(2)));
        vm.prank(ownerUEA);
        wallet.grantMandate(two);
    }

    function test_T25_canonicalTemplatePasses() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
    }

    // ── T-26 … T-30 — revoke / reconfigure ────────────────────────────

    /**
     * T-26 — ISOLATION REGRESSION GATE. NEVER DELETE.
     *
     * Under Rule 2 all mandates share one wallet, so revoking one must not disturb the
     * others. This is the closest thing v2 has to v1's withdrawn structural-isolation
     * claim, and it is now a property of SmartSession's per-PermissionId keying rather
     * than of separate contracts.
     */
    function test_T26_revokingOneMandateLeavesOthersLive() public {
        bytes32 pidA = _grant(_session(mandateA, agentKey, type(uint256).max));
        bytes32 pidB = _grant(_session(mandateB, agentKey, type(uint256).max));
        bytes32 pidC = _grant(_session(keccak256("mandate-C"), agentKey, type(uint256).max));

        vm.prank(ownerUEA);
        wallet.revokeMandate(pidB);

        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pidA), address(wallet)), "A live");
        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pidB), address(wallet)), "B dead");
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pidC), address(wallet)), "C live");

        // A and C still execute; B cannot.
        _executeSession(pidA, agentPk, expectedCEA, 10e6, 0);
        _executeSession(pidC, agentPk, expectedCEA, 10e6, 0);

        // B's op fails validation: its session validator is disabled, so SmartSession
        // returns a non-zero authorizer and our _requireValidationData reverts.
        (bool ok,) = _tryExecuteSession(pidB, agentPk, expectedCEA, 10e6, 0);
        assertFalse(ok, "the revoked mandate must not execute");
    }

    /**
     * T-27 — Q15. `revokeMandate` on an unknown pid must revert.
     *
     * Upstream `removeSession` guards ONLY `EMPTY_PERMISSIONID`; for any other unknown
     * pid every internal `removeAll` is a no-op and it succeeds silently, emitting
     * `SessionRemoved`. Without our existence check a typo'd pid during an incident would
     * emit `MandateRevoked` and read as "revoked ✓" while the real mandate stayed live.
     */
    function test_T27_revokeUnknownPidReverts() public {
        _installSmartSession();
        bytes32 unknown = keccak256("never-granted");

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.MandateNotFound.selector, unknown));
        vm.prank(ownerUEA);
        wallet.revokeMandate(unknown);
    }

    /// @dev Dangling sessions (post-`emergencyRevokeAll`) still report enabled, so
    ///      individual revocation remains available during recovery.
    function test_T27b_revokeWorksOnDanglingSession() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));

        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);

        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "still dangling");
        vm.prank(ownerUEA);
        wallet.revokeMandate(pid);
        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
    }

    /// @dev T-28 — F-16. `reconfigureMandate` RESETS counters by design. Asserted rather
    ///      than merely documented, because it is the difference between reconfigure and
    ///      pause: a false alarm must not silently re-arm a mandate's caps.
    function test_T28_reconfigureResetsSpent() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, 100e6));
        _executeSession(pid, agentPk, expectedCEA, 60e6, 0);

        ConfigId cid = _acpConfigId(pid);
        (,,,,,,, uint256 spentBefore,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(spentBefore, 60e6);

        // Build the session BEFORE pranking: argument evaluation makes staticcalls of its
        // own (acp.SEND_OUTBOUND_SELECTOR), which would consume the one-shot prank.
        Session memory replacement = _session(mandateA, agentKey, 200e6);
        vm.prank(ownerUEA);
        wallet.reconfigureMandate(replacement);

        (,,,,, uint256 total,, uint256 spentAfter,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(total, 200e6, "new cap applied");
        assertEq(spentAfter, 0, "counters reset BY DESIGN (F-16)");
    }

    /// @dev The zero-salt guard applies to reconfigure too, not just grant. Without it a
    ///      caller could aim reconfigure at the unnamed mandate slot.
    function test_T28b_reconfigureZeroSaltReverts() public {
        _installSmartSession();
        Session memory s = _session(bytes32(0), agentKey, type(uint256).max);

        vm.expectRevert(PushWalletErrors.InvalidMandateId.selector);
        vm.prank(ownerUEA);
        wallet.reconfigureMandate(s);
    }

    function test_T29_reconfigureAbsentPidReverts() public {
        _installSmartSession();
        Session memory s = _session(mandateA, agentKey, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.MandateNotFound.selector, _expectedPid(s)));
        vm.prank(ownerUEA);
        wallet.reconfigureMandate(s);
    }

    /// @dev T-30 — the guards apply equally to reconfigure. A mandate cannot be widened
    ///      into a wildcard after the fact.
    function test_T30_reconfigureAppliesGuards() public {
        _grant(_session(mandateA, agentKey, type(uint256).max));

        Session memory bad = _session(mandateA, agentKey, type(uint256).max);
        bad.actions[0].actionTarget = address(1);

        vm.expectRevert(PushWalletErrors.FallbackActionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.reconfigureMandate(bad);
    }

    /// @dev Q3 — reconfigure requires the module installed (asymmetric vs revoke,
    ///      deliberately): it ENABLES, and enabling on a dangling session would undermine
    ///      the purge → install → grant recovery sequence.
    function test_T30b_reconfigureRequiresModuleInstalled() public {
        _grant(_session(mandateA, agentKey, type(uint256).max));

        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);
        assertFalse(wallet.isModuleInstalled(1, address(smartSession), ""), "module is off");

        // Build the replacement session BEFORE expectRevert: constructing it makes
        // staticcalls that would otherwise consume the cheatcode.
        Session memory replacement = _session(mandateA, agentKey, 200e6);

        vm.expectRevert(PushWalletErrors.SessionModuleNotInstalled.selector);
        vm.prank(ownerUEA);
        wallet.reconfigureMandate(replacement);
    }

    // ── T-31 / T-32 — brick recovery (A-05) ───────────────────────────

    /**
     * T-31 — FULL BRICK-RECOVERY DRILL. This is the proof the wallet is not permanently
     * bricked by its own emergency function.
     *
     * `emergencyRevokeAll` deliberately skips module callbacks so a hostile module cannot
     * resist removal. The cost is that SmartSession's `$enabledSessions` stays populated,
     * and `onInstall` then reverts `SmartSessionModuleAlreadyInstalled` forever.
     * `purgeDanglingSessions` clears that set in owner-chosen chunks.
     */
    function test_T31_brickRecoveryDrill() public {
        _grant(_session(mandateA, agentKey, type(uint256).max));
        _grant(_session(mandateB, agentKey, type(uint256).max));
        _grant(_session(keccak256("mandate-C"), agentKey, type(uint256).max));

        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);

        // The brick: reinstalling is impossible while sessions dangle.
        vm.expectRevert(
            abi.encodeWithSelector(ISmartSession.SmartSessionModuleAlreadyInstalled.selector, address(wallet))
        );
        vm.prank(ownerUEA);
        wallet.installModule(1, address(smartSession), "");

        // Purge in chunks.
        vm.expectEmit(false, false, false, true);
        emit DanglingSessionsPurged(2, 1);
        vm.prank(ownerUEA);
        wallet.purgeDanglingSessions(2);

        vm.expectEmit(false, false, false, true);
        emit DanglingSessionsPurged(1, 0);
        vm.prank(ownerUEA);
        wallet.purgeDanglingSessions(2);

        // Recovered: install works, and a fresh grant works.
        vm.prank(ownerUEA);
        wallet.installModule(1, address(smartSession), "");

        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)));
    }

    function test_T32_purgeIsOwnerOnly() public {
        _grant(_session(mandateA, agentKey, type(uint256).max));

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(attacker);
        wallet.purgeDanglingSessions(10);

        // The guardian cannot purge either: a guardian able to brick but not purge would
        // be a nastier griefing vector than anything it defends against (F-19).
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.purgeDanglingSessions(10);
    }

    // ── helpers ───────────────────────────────────────────────────────

    function _expectedPid(Session memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s.sessionValidator, s.sessionValidatorInitData, s.salt));
    }

    function _first6(bytes memory raw) internal pure returns (bytes memory out) {
        out = new bytes(6);
        for (uint256 i; i < 6; ++i) {
            out[i] = raw[i];
        }
    }
}
