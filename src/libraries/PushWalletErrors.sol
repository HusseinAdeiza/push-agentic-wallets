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
    ///      shape this system accepts for the DERIVED `MandateType`. Stays for the rules COMMON to
    ///      both types: user-op policies, ERC-7739, the paymaster permit, the session validator, and
    ///      the action-policy count. A target that is wrong FOR THE DERIVED TYPE is
    ///      `MandateTypeMismatch` instead — that distinction is the invariant, stated once.
    error MalformedSessionShape();

    // ──────────────────── native mandate shape (grantMandate) ────────────────────

    /// @dev Action count outside 1..MAX_NATIVE_ACTIONS. Zero is refused too: a mandate that
    ///      authorises nothing is a misconfiguration, not a valid ascetic grant.
    ///
    ///      ZERO IS NOW CHECKED FOR BOTH MODES, BEFORE THE MODE IS KNOWN. The mode is derived from
    ///      action 0's envelope, so action 0 must exist before anything can be derived — with no
    ///      actions there is no envelope, no chain, and therefore no mode. A universal session with
    ///      zero actions consequently reports `TooManyActions(0)` rather than
    ///      `MalformedSessionShape`.
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

    /// @dev The type DERIVED from the envelope's chain does not match the action set: a gateway
    ///      target under the Push chain, or a non-gateway target under a foreign chain. Carries the
    ///      offending action's index and target, which is why it is distinct from
    ///      `MalformedSessionShape` — with up to eight actions, "something was wrong" is not a
    ///      usable diagnostic.
    ///
    ///      IF YOU MEANT A NATIVE MANDATE AND SEE `UNIVERSAL` HERE, THE CHAIN STRING IS NOT
    ///      BYTE-EXACT `eip155:<chainid>` OF THIS CHAIN. `"EIP155:42101"`, `"eip155:042101"` and a
    ///      leading space all hash to not-Push and therefore derive UNIVERSAL. That is deliberate:
    ///      the hash comparison is the whole rule, and a string parser would be a second rulebook
    ///      and a heuristic. The SDK prechecks this so a user sees the real cause.
    ///
    ///      ORDER NOTE: under UNIVERSAL the `n != 1` shape rule runs BEFORE the target check, so a
    ///      malformed chain string on a multi-action session reports `MalformedSessionShape`.
    error MandateTypeMismatch(MandateType derived, uint256 actionIndex, address target);

    /// @dev `grantMandate`: action 0's policy envelope declares an empty chain string. The wallet
    ///      performs no other validation of it — a malformed non-empty string derives UNIVERSAL and
    ///      is then refused against the targets, or against the asset by URP at init.
    error EmptyChain();

    /// @dev `grantMandate`: action `actionIndex` declares a different chain than action 0. A mandate
    ///      is one thing, on one chain, in one mode — which is what makes mixed mandates impossible
    ///      by construction rather than by a rule.
    error InconsistentChain(uint256 actionIndex);

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
