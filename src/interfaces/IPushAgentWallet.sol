// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Session } from "smartsessions/DataTypes.sol";
import { ModeCode } from "../libraries/ModeLib.sol";

/**
 * @notice The PushAgentWallet-specific surface beyond IERC7579Account (PRD §5).
 *
 * @dev    v2 authority model (C.4, P-8) — three paths, deliberately unequal:
 *         - OWNER (the UEA, driven from the origin chain): everything. Slow (TSS).
 *         - GUARDIAN (any Push address): pause and revoke ONLY. Cannot spend, cannot
 *           grant, cannot unpause. Fast (one Push tx).
 *         - SESSION (agent key, submitted by anyone): policy-gated, terminates at the
 *           gateway, bounded by the Mandate Bound.
 */
interface IPushAgentWallet {
    event WalletInitialized(address indexed owner);
    event SessionExecuted(address indexed validator, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash);
    event EmergencyRevokeAll(address indexed caller);
    event PCSwept(address indexed to, uint256 amount);

    // ── v2 mandate lifecycle ──
    event MandateGranted(bytes32 indexed permissionId, bytes32 indexed mandateId);
    event MandateRevoked(bytes32 indexed permissionId);
    event MandateReconfigured(bytes32 indexed permissionId);
    event DanglingSessionsPurged(uint256 removed, uint256 remaining);

    // ── v2 guardian (F-06) ──
    event GuardianSet(address indexed previous, address indexed guardian);
    event SessionsPausedSet(bool paused, address indexed by);
    event GuardianRevokedAll(uint256 removed, uint256 remaining);

    /// @notice Called exactly once by AgentWalletFactory immediately after cloning.
    function initialize(address owner_, address guardian_) external;

    /// @notice Native account-abstraction entry point. Replaces EntryPoint.handleOps.
    function executeWithSession(
        address validator,
        ModeCode mode,
        bytes calldata executionCalldata,
        bytes calldata signature,
        uint192 nonceKey,
        uint64 nonceSeq
    ) external;

    /// @notice Owner-gated passthrough so SmartSession sees msg.sender == address(this).
    function callValidator(address smartSession, bytes calldata data) external returns (bytes memory);

    /// @notice Uninstalls validators WITHOUT calling onUninstall.
    function emergencyRevokeAll(address[] calldata validators) external;

    /// @notice Return unspent native PC to a destination. Owner only.
    function sweepPC(address payable to, uint256 amount) external;

    // ==============================
    //     MANDATE LIFECYCLE (owner)
    // ==============================

    /// @notice Grant one mandate as a SmartSession session. Fully guarded (G1–G3, A-11).
    function grantMandate(Session calldata session) external returns (bytes32 pid);

    /// @notice Kill exactly one mandate.
    function revokeMandate(bytes32 pid) external;

    /// @notice Deliberate update of an existing mandate. RESETS caps and counters by design.
    function reconfigureMandate(Session calldata session) external returns (bytes32 pid);

    /// @notice Recovery from the `onInstall` brick. Chunkable; repeat until remaining == 0.
    function purgeDanglingSessions(uint256 maxIterations) external;

    // ==============================
    //          GUARDIAN
    // ==============================

    function setGuardian(address g) external;

    /// @notice REFLEX. Blocks the session path globally, in one Push transaction.
    function guardianPause() external;

    /// @notice Owner only — the guardian can reduce permissions, never restore them.
    function unpauseSessions() external;

    function guardianRevoke(bytes32 pid) external;

    /// @notice Kills all mandates WITHOUT bricking the wallet (contrast emergencyRevokeAll).
    function guardianRevokeAll(uint256 maxIterations) external;

    // ==============================
    //            VIEWS
    // ==============================

    function owner() external view returns (address);

    function guardian() external view returns (address);

    function sessionsPaused() external view returns (bool);

    /// @notice Current expected sequence number for a 2D nonce key.
    function nonce(uint192 nonceKey) external view returns (uint64);
}
