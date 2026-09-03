// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IPushSessionValidator — the v3 addition to the session-validator surface.
 * @notice Upstream `ISessionValidator` does not carry `validateConfig`. The wallet's
 *         `grantMandate` compiles against THIS interface, and `PushSessionValidator` inheriting
 *         it is what makes the compiler check the two against each other.
 *
 * @dev    `pure` is PERMANENT, not provisional. It cannot need to become `view` for a future
 *         scheme, because the validator can never be upgraded: its address is an input to every
 *         permissionId (`IdLib.sol:79`), so a scheme-2 contract-signer capability means a NEW
 *         validator at a NEW address with its own permission-id namespace — never a mutability
 *         change here. Future-proofing an immutable contract's function mutability is a null
 *         operation.
 */
interface IPushSessionValidator {
    /// @notice Pure config sanity check for grant-time use by the SDK and grant screens.
    /// @dev    Returns true iff `data` decodes to a supported (scheme, key) pair with the correct
    ///         key length. Structurally garbled bytes REVERT on decode — callers MUST treat a
    ///         revert as "invalid config". The function is three-valued: true, false, or revert.
    function validateConfig(bytes calldata data) external pure returns (bool);
}
