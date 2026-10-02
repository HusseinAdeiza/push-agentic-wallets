// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IAgentValidator
 * @notice Upstream `ISessionValidator` does not carry `validateConfig`. The wallet's
 *         `grantRules` compiles against THIS interface, and `AgentValidator` inheriting
 *         it is what makes the compiler check the two against each other.
 *
 * @dev    `pure` is PERMANENT, not provisional. It cannot need to become `view` for a future
 *         scheme, because the validator can never be upgraded: its address is an input to every
 *         permissionId (`IdLib.sol:79`), so any change to how an agent is identified means a NEW
 *         validator at a NEW address with its own permission-id namespace — never a mutability
 *         change here. Future-proofing an immutable contract's function mutability is a null
 *         operation.
 */
interface IAgentValidator {
    /// @notice Pure agent-config check for grant-time use by the wallet, the SDK and grant screens.
    /// @dev    Returns true iff `data` is exactly `abi.encode(address agent)` with a non-zero agent (see
    ///         `AgentConfigLib`). Never reverts — the function is two-valued. The wallet still wraps
    ///         the call in `try/catch`; keep that wrapper, it costs nothing and guards a future
    ///         validator.
    function validateConfig(bytes calldata data) external pure returns (bool);
}
