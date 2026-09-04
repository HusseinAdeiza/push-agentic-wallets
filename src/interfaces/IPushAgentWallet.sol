// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IPushAgentWallet — the wallet's observable event surface.
 * @notice Every event `PushAgentWallet` emits is declared here, so indexers, monitoring and the SDK
 *         compile against an interface rather than against the implementation. This matches the
 *         other two contracts in the system, whose events live in `IAGWFactory` and `IUCEP`.
 *
 * @dev    EVENTS ONLY, DELIBERATELY. The wallet's function ABI is specified in the contract itself
 *         and nowhere else. Restating it here would create a second place for it to be edited, and
 *         a signature that drifts between the two compiles cleanly in both.
 *
 * @dev    These signatures are a CONSUMED WIRE FORMAT. Changing a name, a parameter type, or which
 *         parameters are indexed changes the topic hash and silently breaks every deployed indexer
 *         and monitoring rule reading the old one. Add events freely; alter an existing one only as
 *         a deliberate, announced break.
 */
interface IPushAgentWallet {
    // ───────────────────────────────── lifecycle ─────────────────────────────────

    /// @notice The one-shot factory initialisation completed; the wallet is live.
    event AccountInitialized(address indexed owner, address indexed engine);

    // ──────────────────────────────── the owner door ────────────────────────────────

    /// @notice The owner executed directly, with no policy consulted.
    /// @dev    The calldata is hashed rather than logged: an owner batch can be large, and the
    ///         hash is what an observer needs to tie the event to the transaction it came from.
    event OwnerExecuted(bytes32 indexed mode, bytes32 executionCalldataHash);

    // ─────────────────────────────── module manager ───────────────────────────────

    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);

    /// @notice A module's uninstall callback reverted or exhausted its gas stipend.
    /// @dev    THE MODULE WAS STILL REMOVED. This is the audit trail for a module that tried to
    ///         resist its own removal, not a failure of the uninstall.
    event UninstallCallbackFailed(address module);

    // ────────────────────────────── mandate lifecycle ──────────────────────────────

    event MandateGranted(bytes32 indexed permissionId);
    event MandateRevoked(bytes32 indexed permissionId);

    /// @notice An agent request passed validation and was dispatched.
    /// @dev    Mandate-level attribution on the Push side, without touching the gateway's own
    ///         frozen event. The operation hash is what ties this record to the exact signed
    ///         request the agent produced.
    event MandateActionAuthorized(
        bytes32 indexed permissionId, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash
    );
}
