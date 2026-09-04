// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PushWalletErrors
/// @notice Shared custom errors for the Push Agentic Wallet system.
/// @dev    Errors used by ExecutionLib live here too, so the libraries do not need an error home
///         of their own.
library PushWalletErrors {
    // ───────────────────── access control ─────────────────────

    error NotOwner();
    error NotFactory();

    // ─────────────────── initialisation ───────────────────

    error AlreadyInitialized();
    /// @dev Zero address, or a codeless target on install. Also raised by the wallet's constructor
    ///      when any of the four wiring addresses is zero.
    error InvalidModuleAddress();

    // ──────────────────── module manager ────────────────────

    error ModuleAlreadyInstalled(address module);
    error UnsupportedModuleType(uint256 moduleTypeId);
    error ValidatorNotInstalled(address validator);
    /// @dev The engine-scoped uninstall guard: uninstalling the permission engine while it still
    ///      holds live permissions would strand rows it then refuses to reinstall over. Revoke
    ///      everything first.
    error EngineStillHoldsPermissions();

    // ──────────────────── execution modes ────────────────────

    /// @dev ONE error for every rejected mode — delegatecall, static, try-exec, and, on the agent
    ///      door specifically, batch.
    error UnsupportedExecutionMode();

    // ──────────────────── the agent door ────────────────────

    /// @dev Signature too short to carry the mode byte followed by a permission id, or a mode byte
    ///      that is not USE.
    error InvalidSessionSignature();
    error RequestExpired();
    error InvalidNonce(uint192 nonceKey, uint64 expected, uint64 provided);
    error ValidationFailed(address authorizer);
    error OutsideTimeWindow(uint48 validAfter, uint48 validUntil);

    // ──────────────────── mandate lifecycle ────────────────────

    error UnknownPermission(bytes32 permissionId);
    /// @dev Raised by grantMandate's canonical-shape check — the granted session deviates from the
    ///      one permission shape this system accepts.
    error MalformedSessionShape();

    // ──────────────────── used by ExecutionLib ────────────────────

    /// @dev ExecutionLib.decodeBatch — the only error any library in src/ actually references.
    error MalformedBatchCalldata();
}
