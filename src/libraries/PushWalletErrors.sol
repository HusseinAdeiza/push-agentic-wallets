// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MandateType } from "./PushWalletTypes.sol";

/// @title PushWalletErrors
/// @notice Shared custom errors for the Push Agentic Wallet system.
/// @dev    Errors used by ExecutionLib live here too, so the libraries do not need an error home
///         of their own.
/// @dev    THE ERRORS BELOW ARE NEVER TRUNCATED. They revert directly from the wallet, not through
///         the engine's 32-byte `PolicyCheckReverted` wrapper, so every argument survives intact.
///         URP's diagnostic-first argument ordering (which exists only because of that truncation)
///         deliberately does NOT apply here — do not reorder these for consistency with it.
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
    ///      shape this system accepts for the declared `MandateType`. Stays for the rules COMMON to
    ///      both types: user-op policies, ERC-7739, the paymaster permit, the session validator, and
    ///      the action-policy count. A target that is wrong FOR THE DECLARED TYPE is
    ///      `MandateTypeMismatch` instead — that distinction is the invariant, stated once.
    error MalformedSessionShape();

    // ──────────────────── native mandate shape (grantMandate) ────────────────────

    /// @dev NATIVE action count outside 1..MAX_NATIVE_ACTIONS. Zero is refused too: a mandate that
    ///      authorises nothing is a misconfiguration, not a valid ascetic grant.
    error TooManyActions(uint256 count);

    /// @dev The same (target, selector) pair twice in one mandate. Both would hash to one actionId,
    ///      so the second config would overwrite the first — or be refused — depending on engine
    ///      internals. Refused here instead, where the error can name the pair.
    error DuplicateAction(address target, bytes4 selector);

    /// @dev A NATIVE action naming a target no mandate may ever reach: the zero address, the
    ///      engine's fallback flag, the wallet itself, the engine, URP, the validator, or the
    ///      factory. Self and engine are the severe ones — both would let an agent reach the
    ///      wallet's own lifecycle functions through `onlyOwnerOrSelf`.
    error ForbiddenActionTarget(address target);

    /// @dev A NATIVE action naming one of the engine's fallback selectors. `0xFFFFFFFF`
    ///      (value-only) is permitted and is not one of these.
    error ForbiddenActionSelector(bytes4 selector);

    /// @dev The declared type does not match the action set: a gateway target declared NATIVE, or a
    ///      non-gateway target declared UNIVERSAL. Carries the offending action's index and target,
    ///      which is why it is distinct from `MalformedSessionShape` — with up to eight actions,
    ///      "something was wrong" is not a usable diagnostic.
    error MandateTypeMismatch(MandateType declared, uint256 actionIndex, address target);

    // ──────────────────── the agent door, dispatch ────────────────────

    /// @dev The validated execution's target is the wallet itself or the engine. Fires in
    ///      `_gateAndDispatch`, AFTER validation — it is the last layer, and it holds even for a
    ///      session the owner enabled directly on the engine through the owner door, bypassing
    ///      `grantMandate` entirely. Do not move this check before `_validate`.
    error ForbiddenDispatchTarget(address target);

    // ──────────────────── used by ExecutionLib ────────────────────

    /// @dev ExecutionLib.decodeBatch — the only error any library in src/ actually references.
    error MalformedBatchCalldata();
}
