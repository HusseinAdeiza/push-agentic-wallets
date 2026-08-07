// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { CallType, ExecType } from "./ModeLib.sol";

/// @title PushWalletErrors
/// @notice Shared custom errors for the Push Agentic Wallet system (PRD §5.6).
library PushWalletErrors {
    error AlreadyInitialized();
    error ZeroAddress();
    error Unauthorized();
    error UnsupportedModuleType(uint256 moduleTypeId);
    error UnsupportedCallType(CallType callType);
    error UnsupportedExecType(ExecType execType);
    error ModuleAlreadyInstalled(uint256 moduleTypeId, address module);
    error HookAlreadyInstalled(address current);
    error MalformedBatchCalldata();
    error EmptyBatch();
    error ModuleNotInstalled(uint256 moduleTypeId, address module);
    error ValidatorNotInstalled(address validator);
    error InvalidNonce(uint192 key, uint64 expected, uint64 provided);
    error SignatureValidationFailed(address validator, uint256 validationData);
    error OperationNotYetValid(uint48 validAfter);
    error OperationExpired(uint48 validUntil);
    error ExecutionFailed();
    error NativeTransferFailed();
    error DelegatecallNotSupported();

    // ==============================
    //   v2 — MANDATE LIFECYCLE
    // ==============================

    /// @dev `session.salt` carries the mandateId; bytes32(0) would make mandates
    ///      indistinguishable and is rejected at grant time.
    error InvalidMandateId();
    /// @dev A-04. Re-granting an existing PermissionId would silently reset ACP `spent`
    ///      and every cap. `reconfigureMandate` is the explicit, authorised form.
    error MandateAlreadyExists(bytes32 permissionId);
    error MandateNotFound(bytes32 permissionId);
    /// @dev F-17. Enabling a session before SmartSession is installed recreates the
    ///      `onInstall` brick through the front door.
    error SessionModuleNotInstalled();

    // ── grant-time session shape guards ──
    error MissingTimeFramePolicy();
    /// @dev A-11. `validUntil == 0` means NO EXPIRY in TimeFramePolicy — on a shared
    ///      one-per-user wallet that is a permanent unrevoked key.
    error NonExpiringSessionForbidden();
    error MissingValueLimitPolicy();
    error MalformedPolicyInitData();
    /// @dev Q9. ValueLimitPolicy reverts on a zero limit three calls deep as an opaque
    ///      `PolicyNotInitialized`; reject it here with a clean grant-time error.
    error ZeroValueLimit();
    /// @dev W-1. Both fallback ActionIds are configured with actionTarget == address(1).
    error FallbackActionForbidden();
    /// @dev W-2. SmartSession as an action target maps to
    ///      FALLBACK_ACTIONID_SMARTSESSION_CALL, which would expose enableSessions /
    ///      removeSession to the session key.
    error SmartSessionActionForbidden();
    /// @dev G3a. v2.0 scope lock (P-5, F-25): the gateway is the only session target.
    error ActionTargetNotGateway(address target);
    /// @dev W-3. `minPolicies == 1` is satisfied by any single policy, so an action
    ///      carrying only TimeFramePolicy would bypass ACP entirely.
    error GatewayActionMissingACP();
    /// @dev Q8. Duplicate (target, selector) entries collapse to one ConfigId and
    ///      ConfigLib overwrites config per entry — the loose entry would win by array
    ///      position. G3a pins the only legal target, so one action is the only shape.
    error ExactlyOneActionRequired(uint256 provided);

    // ── guardian (F-06, P-8) ──
    error NotGuardian();
    error SessionsArePaused();
}
