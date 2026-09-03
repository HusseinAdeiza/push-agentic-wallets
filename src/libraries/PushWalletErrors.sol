// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PushWalletErrors
/// @notice Shared custom errors for the Push Agentic Wallet system.
/// @dev    The authority for the wallet-level set is PushAGW_prd.md §5. Errors used by
///         ExecutionLib live here too, so the libraries do not need an error home of their own.
library PushWalletErrors {
    // ───────────────────── access control (§5) ─────────────────────

    error NotOwner();
    error NotFactory();

    // ─────────────────── initialisation (§5, §6.1) ───────────────────

    error AlreadyInitialized();
    /// @dev Zero address, or a codeless target on install (§5, §6.7 step 2, §3 constructor).
    error InvalidModuleAddress();

    // ──────────────────── module manager (§5, §6.7–6.8) ────────────────────

    error ModuleAlreadyInstalled(address module);
    error UnsupportedModuleType(uint256 moduleTypeId);
    error ValidatorNotInstalled(address validator);
    /// @dev Q1 ruling — the engine-scoped uninstall wedge guard (§6.8 step 3).
    error EngineStillHoldsPermissions();

    // ──────────────────── execution modes (§5, §6.2, §6.6 step 9) ────────────────────

    /// @dev ONE error for every rejected mode — delegatecall, static, try-exec, and (on the
    ///      agent door) batch. It replaces the v2 pair UnsupportedCallType/UnsupportedExecType,
    ///      which §5 does not carry.
    error UnsupportedExecutionMode();

    // ──────────────────── the agent door (§5, §6.6) ────────────────────

    /// @dev Signature too short to carry USE ‖ permissionId, or a non-USE mode byte (§6.6 step 4).
    error InvalidSessionSignature();
    error RequestExpired();
    error InvalidNonce(uint192 nonceKey, uint64 expected, uint64 provided);
    error ValidationFailed(address authorizer);
    error OutsideTimeWindow(uint48 validAfter, uint48 validUntil);

    // ──────────────────── mandate lifecycle (§5, §6.3–6.4) ────────────────────

    error UnknownPermission(bytes32 permissionId);
    /// @dev grantMandate's canonical-shape check (§6.3 step 0, 2026-08-31 ruling).
    error MalformedSessionShape();

    // ──────────────────── used by ExecutionLib ────────────────────

    /// @dev ExecutionLib.decodeBatch — the only error any library in src/ actually references.
    error MalformedBatchCalldata();
}
