// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ModeCode } from "../libraries/ModeLib.sol";

/// @notice The PushAgentWallet-specific surface beyond IERC7579Account (PRD §5).
interface IPushAgentWallet {
    event WalletInitialized(address indexed owner);
    event SessionExecuted(address indexed validator, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash);
    event EmergencyRevokeAll(address indexed caller);
    event PCSwept(address indexed to, uint256 amount);

    /// @notice Called exactly once by AgentWalletFactory immediately after cloning.
    function initialize(address owner_) external;

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

    function owner() external view returns (address);

    /// @notice Current expected sequence number for a 2D nonce key.
    function nonce(uint192 nonceKey) external view returns (uint64);
}
