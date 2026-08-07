// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { PushAgentWallet } from "./PushAgentWallet.sol";
import { PushWalletErrors } from "./libraries/PushWalletErrors.sol";

/**
 * @title  AgentWalletFactory
 * @notice Deterministic deployment of PushAgentWallet clones (PRD §6).
 * @dev    No admin. No configuration. The implementation address is fixed at
 *         construction. One wallet per owner, for life — D-03v2 (Rule 2).
 *
 *         Rule 2 rewrite: the salt is `keccak256(abi.encode(owner))` with NO mandate
 *         input, so a user has exactly one wallet forever and therefore exactly one CEA
 *         per external chain. A mandate is a *session* inside SmartSession, not a
 *         contract. What this buys (§B.2): every mandate after the first skips wallet
 *         deploy, module install and a destination-chain CEA proxy deployment; one CEA
 *         aggregates protocol rewards; destination approvals persist per
 *         (protocol, token); one legible external address per user.
 */
contract AgentWalletFactory {
    using Clones for address;

    /// @notice The PushAgentWallet implementation all clones delegate to. Immutable.
    address public immutable WALLET_IMPLEMENTATION;

    /// @notice owner => deployed wallet. Zero if not deployed.
    mapping(address => address) public walletOf;

    event AgentWalletDeployed(address indexed wallet, address indexed owner);

    constructor(address walletImplementation_) {
        if (walletImplementation_ == address(0)) revert PushWalletErrors.ZeroAddress();
        WALLET_IMPLEMENTATION = walletImplementation_;
    }

    /**
     * @notice Deploy (or return) the wallet for `msg.sender`. The caller IS the owner.
     * @param  guardian_ Emergency address that may pause/revoke sessions. May be
     *                   address(0) for no guardian; the owner can set one later via
     *                   `setGuardian`.
     *
     * @dev    IDEMPOTENT (F-13). Returns the existing wallet rather than reverting: under
     *         Rule 2 a duplicate deploy can damage nothing, whereas a revert inside the
     *         atomic Stage B multicall would fail an otherwise benign grant. No event on
     *         a re-call — the wallet was already announced once.
     *
     * @dev    `guardian_` is deliberately NOT in the salt. The counterfactual address
     *         stays `keccak256(abi.encode(owner))`, which keeps the one-signature flow
     *         working and the CEA stable across guardian rotation (D-02 holds: the
     *         address still derives from `owner` alone).
     *
     * @dev    There is deliberately no `deployFor(owner, ...)` variant. A third-party
     *         deployment path would let an attacker deploy a user's wallet against an
     *         implementation the user did not choose.
     */
    function deployAgentWallet(address guardian_) external returns (address wallet) {
        wallet = walletOf[msg.sender];
        if (wallet != address(0)) return wallet;

        wallet = WALLET_IMPLEMENTATION.cloneDeterministic(_salt(msg.sender));

        PushAgentWallet(payable(wallet)).initialize(msg.sender, guardian_);

        walletOf[msg.sender] = wallet;
        emit AgentWalletDeployed(wallet, msg.sender);
    }

    /// @notice Counterfactual address. Valid before deployment.
    function computeAgentWallet(address owner_) external view returns (address) {
        return WALLET_IMPLEMENTATION.predictDeterministicAddress(_salt(owner_), address(this));
    }

    function isDeployed(address owner_) external view returns (bool) {
        return walletOf[owner_] != address(0);
    }

    function _salt(address owner_) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner_));
    }
}
