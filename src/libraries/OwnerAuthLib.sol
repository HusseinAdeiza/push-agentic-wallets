// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {
    OwnerIntent,
    OWNER_INTENT_TYPEHASH,
    OWNER_INTENT_DOMAIN_TYPEHASH,
    OWNER_INTENT_DOMAIN_NAME_HASH,
    OWNER_INTENT_DOMAIN_VERSION_HASH
} from "./PushWalletTypes.sol";

/**
 * @title  OwnerAuthLib
 * @notice The one implementation of "did this wallet's owner sign this intent", shared by the factory
 *         and the wallet so the two cannot drift. Internal functions only; no storage.
 *
 * @dev    WHY NOT ERC-1271 ALONE. The usual owner is a UEA, and UEAs do not implement ERC-1271. What
 *         they expose is `verifyUniversalPayloadSignature(bytes32, bytes)` — a raw ECDSA recover
 *         against the origin key on EVM, the Ed25519 precompile on SVM — which answers for any digest.
 *         That is tried first; ERC-1271 is the fallback for Safes and other contract owners.
 *
 *         WHY LOW-LEVEL STATICCALLS AND NOT `try`. A contract owner without the UEA selector but with a
 *         non-reverting fallback returns success with EMPTY data. `try` does not catch the resulting
 *         return-data decode failure — it is raised in the caller — so a high-level call would revert
 *         the door instead of falling through. Every contract path here therefore checks the raw
 *         return shape itself, and this library never reverts.
 */
library OwnerAuthLib {
    /// @dev ERC-1271's success value.
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;

    /// @dev `IUEA.verifyUniversalPayloadSignature(bytes32,bytes)`.
    bytes4 internal constant UEA_VERIFY_SELECTOR = bytes4(keccak256("verifyUniversalPayloadSignature(bytes32,bytes)"));

    /// @dev `IERC1271.isValidSignature(bytes32,bytes)`.
    bytes4 internal constant ERC1271_SELECTOR = bytes4(keccak256("isValidSignature(bytes32,bytes)"));

    /**
     * @notice The intent's EIP-712 domain separator.
     * @param  factory        The factory proxy — the verifying contract for the factory AND its wallets.
     * @param  signerChainId  The chain id the signer's wallet signed under (its home chain).
     */
    function domainSeparator(address factory, uint256 signerChainId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                OWNER_INTENT_DOMAIN_TYPEHASH,
                OWNER_INTENT_DOMAIN_NAME_HASH,
                OWNER_INTENT_DOMAIN_VERSION_HASH,
                signerChainId,
                factory,
                bytes32(block.chainid)
            )
        );
    }

    /**
     * @notice EIP-712 `hashStruct(OwnerIntent)`.
     * @dev    Every OwnerIntent field is a static atomic type, so `abi.encode(typehash, i)` lays the
     *         twelve fields out as twelve consecutive words in declaration order — exactly the EIP-712
     *         `encodeData`. Pinned field-by-field against a hand-built reference in OwnerAuthLib.t.sol.
     */
    function hashIntent(OwnerIntent calldata i) internal pure returns (bytes32) {
        return keccak256(abi.encode(OWNER_INTENT_TYPEHASH, i));
    }

    /// @notice The digest the owner signs: `keccak256("\x19\x01" ‖ domainSeparator ‖ hashStruct)`.
    function intentDigest(address factory, OwnerIntent calldata i) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(factory, i.signerChainId), hashIntent(i)));
    }

    /**
     * @notice Whether `sig` is `owner`'s signature over `digest`. Never reverts.
     * @dev    - Order: EOA (no code) → ECDSA; contract → UEA selector, then ERC-1271. A contract path is
     *           accepted only on success with a return of exactly 32 bytes whose WHOLE word is the
     *           expected value — `true` for the UEA method, `bytes32(0x1626ba7e)` for ERC-1271. Comparing
     *           only the first four bytes would accept an owner whose fallback echoes calldata, because
     *           the ERC-1271 calldata itself starts with the magic value.
     *         - The branch is chosen by `owner.code.length` AT VERIFICATION TIME. Two consequences:
     *           (a) a counterfactual owner — a UEA not yet deployed on Push — has no code, so its
     *               signature is judged by the secp256k1 branch. For an Ed25519 (Solana) owner that fails
     *               closed: the UEA must exist on Push before its first owner-intent door call. Nobody can
     *               produce a secp256k1 signature that recovers to a predicted UEA address, so this is a
     *               liveness edge, never a bypass.
     *           (b) if the chain ever enables EIP-7702, a delegated EOA owner has code and is judged by
     *               its delegate's UEA method or ERC-1271, which most delegates do not implement. The
     *               owner keeps the direct `execute` door but loses the three signature doors.
     */
    function isOwnerSig(address owner, bytes32 digest, bytes calldata sig) internal view returns (bool) {
        if (owner.code.length == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, sig);
            return err == ECDSA.RecoverError.NoError && recovered == owner;
        }

        (bool ok, bytes memory ret) = owner.staticcall(abi.encodeWithSelector(UEA_VERIFY_SELECTOR, digest, sig));
        if (ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1) return true;

        (ok, ret) = owner.staticcall(abi.encodeWithSelector(ERC1271_SELECTOR, digest, sig));
        return ok && ret.length == 32 && abi.decode(ret, (bytes32)) == bytes32(ERC1271_MAGIC);
    }
}
