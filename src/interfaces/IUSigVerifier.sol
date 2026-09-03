// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IUSigVerifier
 * @notice Minimal interface for the Push Chain signature-verification precompile at
 *         0xEC00000000000000000000000000000000000001.
 * @dev    ⚠ DOCUMENTATION ONLY — do NOT call the precompile through this interface.
 *         Solidity inserts an `extcodesize(target) > 0` check before any high-level
 *         call that ABI-decodes return data, and reverts when the target has no code.
 *         Precompiles have no code, so such a call always reverts on-chain.
 *         `PushSessionValidator` uses a raw staticcall instead, mirroring the audited
 *         `UEA_SVM`. This interface exists to document the ABI.
 *
 * @dev    Declared locally rather than imported, to avoid a cross-repo build
 *         dependency on the Push Chain node repo.
 *         Both methods cost 4,000 gas. `pubKey` MUST be raw 32 bytes — the
 *         precompile performs a direct ed25519.PublicKey(pubKey) cast, so
 *         base58 input will fail. Signatures MUST be 64 bytes.
 */
interface IUSigVerifier {
    /// @notice Verifies over the ASCII of "0x" + hex(msgDigest). Wallet-display oriented.
    function verifyEd25519(bytes calldata pubKey, bytes32 msgDigest, bytes calldata signature)
        external
        view
        returns (bool);

    /// @notice Verifies over raw message bytes. Standard ed25519.Sign semantics.
    function verifyEd25519RawMessage(bytes calldata pubKey, bytes calldata message, bytes calldata signature)
        external
        view
        returns (bool);
}
