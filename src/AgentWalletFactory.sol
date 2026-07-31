// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { PushAgentWallet } from "./PushAgentWallet.sol";
import { PushWalletErrors } from "./libraries/PushWalletErrors.sol";

/**
 * @title  AgentWalletFactory
 * @notice Deterministic deployment of PushAgentWallet clones (PRD §6).
 * @dev    No admin. No configuration. The implementation address is fixed at
 *         construction. One wallet per (owner, mandateId) pair — D-03.
 */
contract AgentWalletFactory {
    using Clones for address;

    /// @notice The PushAgentWallet implementation all clones delegate to. Immutable.
    address public immutable WALLET_IMPLEMENTATION;

    /// @notice owner => mandateId => deployed wallet. Zero if not deployed.
    mapping(address => mapping(bytes32 => address)) public walletOf;

    event AgentWalletDeployed(address indexed wallet, address indexed owner, bytes32 indexed mandateId);

    error WalletAlreadyDeployed(address owner, bytes32 mandateId, address existing);

    constructor(address walletImplementation_) {
        if (walletImplementation_ == address(0)) revert PushWalletErrors.ZeroAddress();
        WALLET_IMPLEMENTATION = walletImplementation_;
    }

    /// @notice Deploy a wallet for `msg.sender` under `mandateId`.
    /// @dev    The caller IS the owner. There is no third-party deployment path —
    ///         this prevents an attacker deploying a wallet on a user's behalf
    ///         with an implementation the user did not choose.
    function deployAgentWallet(bytes32 mandateId) external returns (address wallet) {
        address existing = walletOf[msg.sender][mandateId];
        if (existing != address(0)) {
            revert WalletAlreadyDeployed(msg.sender, mandateId, existing);
        }

        bytes32 salt = _salt(msg.sender, mandateId);
        wallet = WALLET_IMPLEMENTATION.cloneDeterministic(salt);

        PushAgentWallet(payable(wallet)).initialize(msg.sender);

        walletOf[msg.sender][mandateId] = wallet;
        emit AgentWalletDeployed(wallet, msg.sender, mandateId);
    }

    /// @notice Counterfactual address. Valid before deployment.
    function computeAgentWallet(address owner_, bytes32 mandateId) external view returns (address) {
        return WALLET_IMPLEMENTATION.predictDeterministicAddress(_salt(owner_, mandateId), address(this));
    }

    function isDeployed(address owner_, bytes32 mandateId) external view returns (bool) {
        return walletOf[owner_][mandateId] != address(0);
    }

    function _salt(address owner_, bytes32 mandateId) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner_, mandateId));
    }
}
