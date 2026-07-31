// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IUSigVerifier } from "../interfaces/IUSigVerifier.sol";

/**
 * @title  PushSessionValidator
 * @notice A stateless ISessionValidator (ERC-7579 module type 7) that answers
 *         exactly one question for SmartSession: did the session key sign this hash?
 *         Supports secp256k1 (ECDSA) and Ed25519 via the USV precompile (PRD §7).
 *
 * @dev    This is the contract that makes a Solana-keyed agent a first-class
 *         operator on an EVM account.
 *
 *         MUST hold no storage — every parameter arrives as calldata. That is
 *         what makes one deployment serve every account.
 */
contract PushSessionValidator is ISessionValidator {
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
            return IUSigVerifier(USV).verifyEd25519RawMessage(key, abi.encodePacked(hash), sig);
        }

        revert UnsupportedScheme(scheme);
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
