// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice Deterministic factory for PushAgentWallet clones (PRD §6).
 *
 * @dev    v2 / Rule 2: ONE wallet per owner, for life. The salt is
 *         `keccak256(abi.encode(owner))` with no mandate input, so a user's wallet
 *         address — and therefore their CEA on every external chain — is fixed
 *         forever. Mandates multiply inside SmartSession's session set, not as
 *         contracts (D-03v2).
 */
interface IAgentWalletFactory {
    event AgentWalletDeployed(address indexed wallet, address indexed owner);

    /**
     * @notice Deploy (or return) the wallet for `msg.sender`. The caller IS the owner.
     * @param  guardian_ Emergency address that may pause/revoke sessions. May be
     *                   address(0) for no guardian; the owner can set one later.
     * @dev    IDEMPOTENT (F-13). Returns the existing wallet instead of reverting, so a
     *         benign re-run inside the atomic Stage B multicall cannot fail a grant.
     *         `guardian_` is deliberately NOT in the salt — the counterfactual address
     *         stays derived from `owner` alone, which is what keeps the one-signature
     *         flow and a stable CEA. There is deliberately no `deployFor(owner, ...)`.
     */
    function deployAgentWallet(address guardian_) external returns (address wallet);

    /// @notice Counterfactual address. Valid before deployment.
    function computeAgentWallet(address owner_) external view returns (address);

    function isDeployed(address owner_) external view returns (bool);

    /// @notice owner => deployed wallet. Zero if not deployed.
    function walletOf(address owner_) external view returns (address);

    function WALLET_IMPLEMENTATION() external view returns (address);
}
