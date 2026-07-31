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
    error ModuleNotInstalled(uint256 moduleTypeId, address module);
    error ValidatorNotInstalled(address validator);
    error InvalidNonce(uint192 key, uint64 expected, uint64 provided);
    error SignatureValidationFailed(address validator, uint256 validationData);
    error OperationNotYetValid(uint48 validAfter);
    error OperationExpired(uint48 validUntil);
    error ExecutionFailed();
    error NativeTransferFailed();
    error DelegatecallNotSupported();
}
