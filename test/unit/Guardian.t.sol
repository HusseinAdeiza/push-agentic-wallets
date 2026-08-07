// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MandateFixture } from "../helpers/MandateFixture.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

import { Session, PermissionId, ConfigId } from "smartsessions/DataTypes.sol";
import { ValueLimitPolicy } from "smartsessions/external/policies/ValueLimitPolicy.sol";

/**
 * @notice v2 Step 7 — the guardian surface (T-33 … T-41). Closes A-16.
 *
 * @dev WHY A GUARDIAN EXISTS. The owner is a UEA driven from the origin chain, so every
 *      owner action costs an Ethereum round trip: minutes. A compromised session key can
 *      do real damage in minutes. The guardian is any Push address the user designates,
 *      able to act in ONE Push transaction — seconds — and able to do only two things:
 *      pause and revoke.
 *
 * @dev THE ASYMMETRY IS THE DESIGN (P-8). The guardian can only ever REDUCE permissions.
 *      It cannot spend, cannot grant, and cannot unpause. A compromised guardian is
 *      therefore a liveness problem, never a solvency one — which is what makes the role
 *      safe to hand to a watchtower or a hot key.
 */
contract GuardianTest is MandateFixture {
    event GuardianSet(address indexed previous, address indexed guardian);
    event SessionsPausedSet(bool paused, address indexed by);
    event GuardianRevokedAll(uint256 removed, uint256 remaining);
    event MandateRevoked(bytes32 indexed permissionId);

    bytes32 internal pidA;
    bytes32 internal pidB;
    bytes32 internal pidC;

    function setUp() public {
        _deployStack();
        pidA = _grant(_session(mandateA, agentKey, type(uint256).max));
        pidB = _grant(_session(mandateB, agentKey, type(uint256).max));
        pidC = _grant(_session(keccak256("mandate-C"), agentKey, type(uint256).max));
    }

    // ── T-33 / T-34 — pause ───────────────────────────────────────────

    /// @dev The reflex is GLOBAL: one transaction blocks every mandate at once. A
    ///      per-mandate response would require N transactions during an incident.
    function test_T33_pauseBlocksEverySession() public {
        vm.expectEmit(false, true, false, true);
        emit SessionsPausedSet(true, guardian);
        vm.prank(guardian);
        wallet.guardianPause();

        assertTrue(wallet.sessionsPaused());

        (bool okA,) = _tryExecuteSession(pidA, agentPk, expectedCEA, 10e6, 0);
        (bool okB,) = _tryExecuteSession(pidB, agentPk, expectedCEA, 10e6, 0);
        (bool okC,) = _tryExecuteSession(pidC, agentPk, expectedCEA, 10e6, 0);
        assertFalse(okA, "A blocked");
        assertFalse(okB, "B blocked");
        assertFalse(okC, "C blocked");
    }

    /// @dev The revert must be the specific `SessionsArePaused`, and it must fire BEFORE
    ///      any nonce is consumed — otherwise a pause would silently burn nonces.
    function test_T33b_pauseRevertsWithSessionsArePausedAndConsumesNoNonce() public {
        vm.prank(guardian);
        wallet.guardianPause();

        uint192 key = uint192(uint256(pidA));
        uint64 nonceBefore = wallet.nonce(key);

        bytes memory execCd = _execCalldataWithValue(expectedCEA, 10e6, 0);
        bytes memory sig = _sign(agentPk, pidA, _opHash(ModeLib.encodeSimpleSingle(), execCd, key, 0));

        vm.expectRevert(PushWalletErrors.SessionsArePaused.selector);
        wallet.executeWithSession(address(smartSession), ModeLib.encodeSimpleSingle(), execCd, sig, key, 0);

        assertEq(wallet.nonce(key), nonceBefore, "a paused op must not consume a nonce");
    }

    function test_T34_pauseFromNonGuardianReverts() public {
        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(attacker);
        wallet.guardianPause();

        // Not even the owner may use the guardian entrypoint; the owner has its own path.
        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(ownerUEA);
        wallet.guardianPause();
    }

    // ── T-35 / T-36 — unpause is OWNER-ONLY (P-8) ─────────────────────

    function test_T35_guardianCannotUnpause() public {
        vm.prank(guardian);
        wallet.guardianPause();

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.unpauseSessions();

        assertTrue(wallet.sessionsPaused(), "still paused");
    }

    /**
     * T-36 — WHY PAUSE EXISTS ALONGSIDE REVOKE.
     *
     * Pause is reversible WITHOUT re-granting. Revoking and re-granting would re-run
     * `initializeWithMultiplexer`, which resets ACP `spent` and ValueLimitPolicy
     * `limitUsed` to zero — so a false alarm handled by revoke would silently re-arm the
     * mandate's caps. This test asserts both counters survive a pause/unpause cycle.
     */
    function test_T36_unpauseRestoresExecutionAndPreservesCounters() public {
        _executeSession(pidA, agentPk, expectedCEA, 40e6, 0);

        ConfigId cid = _acpConfigId(pidA);
        (,,,,,,, uint256 spentBefore,) = acp.getConfig(cid, address(smartSession), address(wallet));
        uint256 usedBefore = valueLimit.getUsed(cid, address(smartSession), address(wallet));
        assertEq(spentBefore, 40e6);

        vm.prank(guardian);
        wallet.guardianPause();
        vm.prank(ownerUEA);
        wallet.unpauseSessions();

        assertFalse(wallet.sessionsPaused());

        (,,,,,,, uint256 spentAfter,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(spentAfter, spentBefore, "ACP spent must survive the pause cycle");
        assertEq(
            valueLimit.getUsed(cid, address(smartSession), address(wallet)),
            usedBefore,
            "ValueLimit limitUsed must survive the pause cycle"
        );

        // And execution resumes against the SAME budget, not a fresh one.
        _executeSession(pidA, agentPk, expectedCEA, 10e6, 1);
        (,,,,,,, uint256 spentFinal,) = acp.getConfig(cid, address(smartSession), address(wallet));
        assertEq(spentFinal, 50e6, "spend accumulated across the cycle");
    }

    // ── T-37 / T-38 — revoke ──────────────────────────────────────────

    function test_T37_guardianRevokeKillsOnlyTheNamedMandate() public {
        vm.prank(guardian);
        wallet.guardianRevoke(pidB);

        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pidA), address(wallet)));
        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pidB), address(wallet)));
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pidC), address(wallet)));

        _executeSession(pidA, agentPk, expectedCEA, 10e6, 0);
        (bool ok,) = _tryExecuteSession(pidB, agentPk, expectedCEA, 10e6, 0);
        assertFalse(ok, "B is dead");
    }

    /// @dev Q15 — a typo'd pid during an incident must revert loudly rather than emit a
    ///      phantom `MandateRevoked` that reads as "revoked ✓".
    function test_T37b_guardianRevokeUnknownPidReverts() public {
        bytes32 unknown = keccak256("never-granted");
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.MandateNotFound.selector, unknown));
        vm.prank(guardian);
        wallet.guardianRevoke(unknown);
    }

    /**
     * T-38 — `guardianRevokeAll` must NOT brick the wallet.
     *
     * This is the whole reason it exists separately from `emergencyRevokeAll`. The latter
     * skips module callbacks (so a hostile module cannot resist removal) and therefore
     * leaves `$enabledSessions` populated, permanently blocking `onInstall`. Looping
     * `removeSession` clears that set properly, so reinstall still works.
     */
    function test_T38_guardianRevokeAllDoesNotBrick() public {
        vm.expectEmit(false, false, false, true);
        emit GuardianRevokedAll(3, 0);
        vm.prank(guardian);
        wallet.guardianRevokeAll(10);

        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pidA), address(wallet)));
        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pidB), address(wallet)));
        assertFalse(smartSession.isPermissionEnabled(PermissionId.wrap(pidC), address(wallet)));

        // NOT bricked: uninstall then reinstall succeeds, and a fresh grant works.
        vm.prank(ownerUEA);
        wallet.uninstallModule(1, address(smartSession), "");
        vm.prank(ownerUEA);
        wallet.installModule(1, address(smartSession), "");

        bytes32 fresh = _grant(_session(keccak256("mandate-D"), agentKey, type(uint256).max));
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(fresh), address(wallet)));
    }

    /// @dev Q4 — the guardian must be able to tell whether `maxIterations` covered
    ///      everything, otherwise a partial sweep looks like a complete one.
    function test_T38b_partialRevokeAllReportsRemaining() public {
        vm.expectEmit(false, false, false, true);
        emit GuardianRevokedAll(2, 1);
        vm.prank(guardian);
        wallet.guardianRevokeAll(2);

        vm.expectEmit(false, false, false, true);
        emit GuardianRevokedAll(1, 0);
        vm.prank(guardian);
        wallet.guardianRevokeAll(2);
    }

    // ── T-39 / T-40 — configuration ───────────────────────────────────

    /// @dev With no guardian set, every guardian function is inert. `msg.sender` can never
    ///      be address(0), so no separate "configured" flag is needed.
    function test_T39_zeroGuardianMakesEveryEntrypointInert() public {
        address alice = address(0xA11CE0);
        vm.prank(alice);
        PushAgentWallet w = PushAgentWallet(payable(factory.deployAgentWallet(address(0))));
        assertEq(w.guardian(), address(0));

        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(alice);
        w.guardianPause();

        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(attacker);
        w.guardianRevoke(bytes32(uint256(1)));

        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(attacker);
        w.guardianRevokeAll(1);
    }

    function test_T40_setGuardianRotates() public {
        address newGuardian = address(0x6DB);

        vm.expectEmit(true, true, false, false);
        emit GuardianSet(guardian, newGuardian);
        vm.prank(ownerUEA);
        wallet.setGuardian(newGuardian);

        assertEq(wallet.guardian(), newGuardian);

        // The old guardian is powerless.
        vm.expectRevert(PushWalletErrors.NotGuardian.selector);
        vm.prank(guardian);
        wallet.guardianPause();

        // The new one works.
        vm.prank(newGuardian);
        wallet.guardianPause();
        assertTrue(wallet.sessionsPaused());
    }

    function test_T40b_setGuardianIsOwnerOnly() public {
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.setGuardian(attacker);

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(attacker);
        wallet.setGuardian(attacker);
    }

    // ── T-41 — the guardian has NO other powers ───────────────────────

    /**
     * T-41 — sweep every owner-only entrypoint and assert the guardian is rejected.
     *
     * This is the test that makes the guardian safe to delegate. If any of these ever
     * starts succeeding, the guardian has become a spending or granting authority and the
     * P-8 asymmetry is gone.
     */
    function test_T41_guardianCannotSpendGrantOrConfigure() public {
        Session memory s = _session(keccak256("mandate-X"), agentKey, type(uint256).max);
        bytes memory execCd = ExecutionLib.encodeSingle(address(gateway), 0, _outboundCalldata(expectedCEA, 10e6));
        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);

        // execute — cannot spend
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.execute(ModeLib.encodeSimpleSingle(), execCd);

        // grantMandate — cannot grant
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.grantMandate(s);

        // reconfigureMandate — cannot widen
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.reconfigureMandate(s);

        // sweepPC — cannot move funds
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.sweepPC(payable(attacker), 0);

        // installModule — cannot change the module set
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.installModule(1, address(sessionValidator), "");

        // uninstallModule
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.uninstallModule(1, address(smartSession), "");

        // purgeDanglingSessions — recovery is the owner's job (F-19)
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.purgeDanglingSessions(10);

        // emergencyRevokeAll — the BRICKING variant stays owner-only, deliberately: a
        // guardian able to brick but not to purge would be a nastier griefing vector.
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.emergencyRevokeAll(vs);

        // callValidator — the raw escape hatch
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.callValidator(address(smartSession), "");

        // revokeMandate — owner's surgical path (the guardian has guardianRevoke instead)
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.revokeMandate(pidA);

        // unpauseSessions — can reduce, never restore
        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(guardian);
        wallet.unpauseSessions();
    }
}
