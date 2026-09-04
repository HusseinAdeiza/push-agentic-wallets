// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IUSigVerifier } from "../interfaces/IUSigVerifier.sol";
import { IPushSessionValidator } from "../interfaces/IPushSessionValidator.sol";

/**
 * @title  PushSessionValidator
 * @notice A stateless ISessionValidator (ERC-7579 module type 7) that answers
 *         exactly one question for SmartSession: did the session key sign this hash?
 *         Supports secp256k1 (ECDSA) and Ed25519 via the signature-verification precompile.
 *
 * @dev    - Makes a Solana-keyed agent a first-class operator on an EVM account.
 *         - Holds no storage, so one deployment serves every account.
 *         - Every parameter arrives as calldata.
 */
contract PushSessionValidator is ISessionValidator, IPushSessionValidator {
    /// @notice Push Chain signature-verification precompile (fixed, chain-level).
    address public constant USV = 0xEC00000000000000000000000000000000000001;

    /// @notice Scheme byte selecting secp256k1 signatures.
    uint8 public constant SCHEME_ECDSA = 0;

    /// @notice Scheme byte selecting Ed25519 signatures.
    uint8 public constant SCHEME_ED25519 = 1;

    /// @dev ERC-7579 stateless-validator module type.
    uint256 internal constant MODULE_TYPE_STATELESS_VALIDATOR = 7;

    /// @dev Thrown when the scheme byte is neither of the two supported values.
    error UnsupportedScheme(uint8 scheme);

    /// @dev Thrown when the key length does not match the scheme it is paired with.
    error MalformedConfig();

    /**
     * @notice Validate a session signature.
     *
     * @dev    - ECDSA: reverts `MalformedConfig` on a key that is not 20 bytes; returns false on a
     *           signature that is not 65 bytes or that fails to recover.
     *         - Ed25519: reverts `MalformedConfig` on a key that is not 32 bytes; returns false on a
     *           signature that is not 64 bytes or on a failed precompile call.
     *         - Reverts `UnsupportedScheme` on anything else.
     *         - Recovery uses `tryRecover` rather than `recover`, so a malformed signature returns
     *           false instead of reverting: a revert inside validation is indistinguishable from a
     *           policy failure and degrades error reporting. The Ed25519 branch fails closed for the
     *           same reason.
     *
     * @param hash The opHash produced by PushAgentWallet._computeOpHash
     * @param sig  ECDSA: 65 bytes (r,s,v).  Ed25519: 64 bytes.
     * @param data abi.encode(uint8 scheme, bytes key)
     *             scheme 0 → key is abi.encodePacked(address signer)   — 20 bytes
     *             scheme 1 → key is the raw Ed25519 public key         — 32 bytes
     * @return validSig Whether the signature is valid for the configured key.
     */
    function validateSignatureWithData(bytes32 hash, bytes calldata sig, bytes calldata data)
        external
        view
        override
        returns (bool validSig)
    {
        (uint8 scheme, bytes memory key) = abi.decode(data, (uint8, bytes));

        if (scheme == SCHEME_ECDSA) {
            if (key.length != 20) revert MalformedConfig();
            if (sig.length != 65) return false;
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
            if (err != ECDSA.RecoverError.NoError) return false;
            // forge-lint: disable-next-line(unsafe-typecast)
            return recovered == address(bytes20(key));
        }

        if (scheme == SCHEME_ED25519) {
            if (key.length != 32) revert MalformedConfig();
            if (sig.length != 64) return false;
            // Raw-message variant: the message is the 32 bytes of hash. Not verifyEd25519, which
            // verifies over the ASCII of a hex string that a standard signing library will not
            // produce.
            //
            // Must be a raw staticcall. Solidity inserts an extcodesize check before any high-level
            // call that ABI-decodes return data, and precompiles have no code, so an interface call
            // would revert on-chain. IUSigVerifier is documentation only.
            (bool ok, bytes memory ret) = USV.staticcall(
                abi.encodeWithSignature("verifyEd25519RawMessage(bytes,bytes,bytes)", key, abi.encodePacked(hash), sig)
            );
            if (!ok || ret.length < 32) return false;
            return abi.decode(ret, (bool));
        }

        revert UnsupportedScheme(scheme);
    }

    /**
     * @notice Pure config sanity check, for grant screens and the SDK.
     *
     * @dev    - Closes a gap in the engine's grant path, which checks only the module type and never
     *           inspects the key config. Without this, an owner can grant a permission with a
     *           19-byte key: the grant succeeds and every later agent request reverts forever.
     *         - Returns true only for scheme 0 with a 20-byte key, or scheme 1 with a 32-byte key.
     *         - Three-valued, and must stay consistent with `validateSignatureWithData`: true means
     *           the runtime call will not revert, though it may still return false, which is a
     *           signature failure and a different thing; false means the runtime call reverts with a
     *           named error; a revert here means the runtime call also reverts, at the same decode
     *           step, not necessarily with a named error.
     *         - Callers must treat a revert as an invalid config.
     *
     * @param  data abi.encode(uint8 scheme, bytes key) — the frozen encoding.
     * @return Whether the config is a supported scheme and key-length pair.
     */
    function validateConfig(bytes calldata data) external pure returns (bool) {
        (uint8 scheme, bytes memory key) = abi.decode(data, (uint8, bytes));
        if (scheme == SCHEME_ECDSA) return key.length == 20;
        if (scheme == SCHEME_ED25519) return key.length == 32;
        return false;
    }

    // --- IERC7579Module ---

    /// @dev No-op: the validator holds no per-account state.
    function onInstall(bytes calldata) external pure { }

    /// @dev No-op: the validator holds no per-account state.
    function onUninstall(bytes calldata) external pure { }

    /**
     * @notice Whether this module implements an ERC-7579 module type.
     * @param  moduleTypeId  Module type to query.
     * @return True only for the stateless-validator type.
     */
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_STATELESS_VALIDATOR;
    }

    /**
     * @notice Whether this module is initialised for an account.
     * @dev    Always true: the validator is stateless, so there is nothing to initialise.
     * @return Always true.
     */
    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}
