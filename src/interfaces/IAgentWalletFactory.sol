// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Deterministic factory for PushAgentWallet clones (PRD §6).
interface IAgentWalletFactory {
    event AgentWalletDeployed(address indexed wallet, address indexed owner, bytes32 indexed mandateId);

    error WalletAlreadyDeployed(address owner, bytes32 mandateId, address existing);

    /// @notice Deploy a wallet for msg.sender under `mandateId`. The caller IS the owner.
    function deployAgentWallet(bytes32 mandateId) external returns (address wallet);

    /// @notice Counterfactual address. Valid before deployment.
    function computeAgentWallet(address owner_, bytes32 mandateId) external view returns (address);

    function isDeployed(address owner_, bytes32 mandateId) external view returns (bool);

    function walletOf(address owner_, bytes32 mandateId) external view returns (address);

    function WALLET_IMPLEMENTATION() external view returns (address);
}
