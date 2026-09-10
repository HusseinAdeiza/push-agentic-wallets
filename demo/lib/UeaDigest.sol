// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalPayload } from "./BobPayload.sol";

/**
 * @title  UeaDigest
 * @notice The EIP-712 digest a UEA verifies, computed locally.
 *
 * @dev    USE THIS ONLY WHEN THE UEA DOES NOT EXIST YET — the ARRIVAL, where Bob signs inside his
 *         Sepolia bridge transaction and there is no deployed contract to ask. Everywhere else,
 *         call `getUniversalPayloadHash` on the live UEA and sign what it returns.
 *
 *         ── THE TRAP, AND IT IS NOT GUESSABLE ──
 *
 *         The domain is INVERTED relative to every other EIP-712 domain you have seen:
 *
 *           · `chainId` is the SOURCE chain — Sepolia, 11155111 — parsed from the account id;
 *           · `salt` carries PUSH CHAIN's id, `bytes32(uint256(42101))`.
 *
 *         Most implementations put the verifying chain in `chainId`. This one does not. Getting it
 *         the conventional way round produces a digest that is wrong in a way nothing catches
 *         locally: the signature simply fails to verify, one chain away, minutes later.
 *
 *         The domain also uses a NON-STANDARD typehash — `EIP712Domain(string version,uint256
 *         chainId,address verifyingContract,bytes32 salt)`, with no `name` field.
 *
 *         ── THE NONCE COMES FROM STORAGE, NOT FROM THE PAYLOAD ──
 *
 *         `UNIVERSAL_PAYLOAD_TYPEHASH` declares a `nonce` field, but the implementation fills that
 *         slot from the UEA's STORAGE counter and ignores `payload.nonce`. Verified on the live
 *         contract: two payloads differing only in `payload.nonce` (0 vs 999) hash identically,
 *         while advancing the stored counter 1 → 2 changed the hash of a fixed payload.
 *
 *         So `storedNonce` is a separate argument here — it is not read off the payload, because
 *         the contract does not read it off the payload either. Pass the UEA's current counter; for
 *         the arrival that is 0.
 *
 *         ── CHECKED, NOT ASSUMED ──
 *
 *         `demo/test/UeaDigestFork.t.sol` computes a digest with this library against a DEPLOYED
 *         UEA and asserts it equals what that contract answers. An earlier version of this file
 *         was deleted precisely because it failed that check; nothing here is trusted on the
 *         strength of a source reading alone.
 */
library UeaDigest {
    /// @dev `UniversalPayload(address to,uint256 value,bytes data,uint256 gasLimit,uint256
    ///      maxFeePerGas,uint256 maxPriorityFeePerGas,uint256 nonce,uint256 deadline,uint8 vType)`
    bytes32 internal constant UNIVERSAL_PAYLOAD_TYPEHASH =
        0x1d8b43e5066bd20bfdacf7b8f4790c0309403b18434e3699ce3c5e57502ed8c4;

    /**
     * @dev `EIP712Domain(string version,uint256 chainId,address verifyingContract)`
     *
     *      THREE FIELDS, NO `name` AND NO `salt`. Read off the deployed UEA's own
     *      `DOMAIN_SEPARATOR_TYPEHASH()` getter and confirmed by recomputing the preimage, not
     *      taken from source: the audit-fixes branch carries a four-field variant ending in
     *      `bytes32 salt` (`0xb90aaffa…`), and the deployed testnet build does not. Using the
     *      four-field version yields a digest that is wrong in the silent way — the signature
     *      simply fails to verify, one chain away.
     *
     *      Because there is no `salt`, Push Chain's own id appears nowhere in the domain; the only
     *      chain id present is the SOURCE chain's, in `chainId`.
     */
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x2aef22f9d7df5f9d21c56d14029233f3fdaa91917727e1eb68e504d27072d6cd;

    /// @dev The UEA's version string, mixed into the domain.
    string internal constant VERSION = "1.0.0";

    /**
     * @notice The digest an owner signs for `executeUniversalTx`.
     *
     * @dev    Sign the returned value RAW — `vm.sign(pk, digest)`. Never apply
     *         `toEthSignedMessageHash`: `verifyUniversalPayloadSignature` calls `recover` directly
     *         and the `\x19\x01` prefix is already inside this digest. Adding an EIP-191 prefix is
     *         the other classic way to produce a signature that will not verify.
     *
     * @param uea           The UEA that will verify — PREDICTED when it does not exist yet.
     * @param sourceChainId The OWNER's home chain id (11155111 for Sepolia). Goes in `chainId`.
     * @param pushChainId   Push Chain's id (42101 on Donut). Goes in `salt`.
     * @param storedNonce   The UEA's STORAGE nonce, not `payload.nonce`. Zero on a fresh UEA.
     * @param payload       The payload being signed.
     * @return The digest to sign.
     */
    function hash(
        address uea,
        uint256 sourceChainId,
        uint256 pushChainId,
        uint256 storedNonce,
        UniversalPayload memory payload
    ) internal pure returns (bytes32) {
        pushChainId; // unused: the deployed domain has no `salt` field. See the typehash note.

        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPEHASH,
                keccak256(bytes(VERSION)),
                sourceChainId, // the SOURCE chain, not Push
                uea
            )
        );

        bytes32 structHash = keccak256(
            abi.encode(
                UNIVERSAL_PAYLOAD_TYPEHASH,
                payload.to,
                payload.value,
                keccak256(payload.data),
                payload.gasLimit,
                payload.maxFeePerGas,
                payload.maxPriorityFeePerGas,
                storedNonce, // from storage, NOT payload.nonce
                payload.deadline,
                payload.vType
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
