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
 * @dev    This is the contract that makes a Solana-keyed agent a first-class
 *         operator on an EVM account.
 *
 *         MUST hold no storage — every parameter arrives as calldata. That is
 *         what makes one deployment serve every account.
 */
contract PushSessionValidator is ISessionValidator, IPushSessionValidator {
    /// @notice Push Chain USV precompile (fixed, chain-level).
    address public constant USV = 0xEC00000000000000000000000000000000000001;

    uint8 public constant SCHEME_ECDSA = 0;
    uint8 public constant SCHEME_ED25519 = 1;

    uint256 internal constant MODULE_TYPE_STATELESS_VALIDATOR = 7;

    error UnsupportedScheme(uint8 scheme);
    error MalformedConfig();

    /**
     * @notice Validate a session signature.
     * @param hash The opHash produced by PushAgentWallet._computeOpHash
     * @param sig  ECDSA: 65 bytes (r,s,v).  Ed25519: 64 bytes.
     * @param data abi.encode(uint8 scheme, bytes key)
     *             scheme 0 → key is abi.encodePacked(address signer)   — 20 bytes
     *             scheme 1 → key is the raw Ed25519 public key         — 32 bytes
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
            // tryRecover (not recover) so a malformed signature returns false rather
            // than reverting — a revert inside validation is indistinguishable from a
            // policy failure and degrades error reporting.
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
            if (err != ECDSA.RecoverError.NoError) return false;
            // key.length is checked to be exactly 20 above, so this is exact, not truncating.
            // forge-lint: disable-next-line(unsafe-typecast)
            return recovered == address(bytes20(key));
        }

        if (scheme == SCHEME_ED25519) {
            if (key.length != 32) revert MalformedConfig();
            if (sig.length != 64) return false;
            // D-18: raw-message variant. message = the 32 bytes of `hash`.
            // MUST NOT use verifyEd25519 — that verifies over the ASCII of a hex
            // string, which a headless agent signing with a standard library will
            // not produce.
            //
            // SECURITY: this MUST be a raw staticcall, not a high-level call through
            // IUSigVerifier. Solidity inserts an `extcodesize(target) > 0` check before
            // any high-level call that ABI-decodes return data, and reverts when the
            // target has no code. Precompiles have no code, so the interface call
            // reverts on-chain. The audited UEA_SVM uses a raw staticcall for exactly
            // this reason. IUSigVerifier is retained for documentation only.
            (bool ok, bytes memory ret) = USV.staticcall(
                abi.encodeWithSignature("verifyEd25519RawMessage(bytes,bytes,bytes)", key, abi.encodePacked(hash), sig)
            );
            // Fail closed. Consistent with the ECDSA branch: a revert inside validation
            // is indistinguishable from a policy failure and degrades error reporting.
            if (!ok || ret.length < 32) return false;
            return abi.decode(ret, (bool));
        }

        revert UnsupportedScheme(scheme);
    }

    /**
     * @notice Pure config sanity check for grant-time use by the SDK and grant screens.
     * @dev    THE GAP THIS CLOSES: the engine's grant path checks only `isModuleType(7)`; it never
     *         inspects the key config. An owner could grant a permission with a 19-byte key — the
     *         grant succeeds, and every subsequent agent request reverts `MalformedConfig` forever:
     *         a dead permission that looks alive.
     *
     *         THREE-VALUED, and the consistency law with `validateSignatureWithData` is therefore
     *         three cases, not one biconditional:
     *           1. `validateConfig == true`  ⟺ the runtime does NOT revert
     *              — a non-reverting runtime call may still return false; that is a SIGNATURE
     *                failure, outside this law entirely.
     *           2. `validateConfig == false` ⇒ the runtime reverts with a NAMED error
     *              (`UnsupportedScheme` or `MalformedConfig`)
     *           3. `validateConfig` REVERTS  ⇒ the runtime also reverts, at the same `abi.decode`
     *              step, not necessarily with a named error
     *
     *         Each of the three cases has its own test; the suite is what holds the two functions
     *         together, since nothing in the type system can.
     *
     *         Callers MUST treat a revert as "invalid config". The two functions must never drift.
     * @param  data abi.encode(uint8 scheme, bytes key) — the frozen encoding.
     */
    function validateConfig(bytes calldata data) external pure returns (bool) {
        (uint8 scheme, bytes memory key) = abi.decode(data, (uint8, bytes));
        if (scheme == SCHEME_ECDSA) return key.length == 20;
        if (scheme == SCHEME_ED25519) return key.length == 32;
        return false;
    }

    // ── IERC7579Module ────────────────────────────────────────────────

    function onInstall(bytes calldata) external pure { } // stateless

    function onUninstall(bytes calldata) external pure { } // stateless

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_STATELESS_VALIDATOR;
    }

    function isInitialized(address) external pure returns (bool) {
        return true; // stateless — always "initialized"
    }
}
