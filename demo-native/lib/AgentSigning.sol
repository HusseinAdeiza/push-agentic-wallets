// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { OP_HASH_DOMAIN } from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  AgentSigning
 * @notice The agent's half of a request: the ten-field operation hash, and the signature envelope
 *         the wallet's agent door expects.
 *
 * @dev    LIFTED, NOT REINVENTED. The wallet's own `_computeOpHash` and the test suite's
 *         `signOpHash` are the originals; this is a transcription for use from scripts, and
 *         `demo/test/AgentSigning.t.sol` asserts byte-identical output against the wallet itself.
 *         That equivalence test is the point of this file existing rather than the logic being
 *         inlined into each script: if a field is reordered or a type widened here, the test fails
 *         instead of the chain silently rejecting every agent request with an opaque signature
 *         error.
 *
 *         `abi.encode`, NEVER `abi.encodePacked`. The ten fields occupy a fixed ten-word layout.
 *         Packed encoding would let two different requests collide on one hash, and the wallet
 *         would then accept a signature produced for the other one.
 */
library AgentSigning {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev SmartSessionMode.USE. The wallet rejects every other mode byte on the agent door.
    uint8 internal constant MODE_USE = 0x00;

    /**
     * @notice The ten-field operation hash, mirroring `PushAgentWallet._computeOpHash`.
     *
     * @dev    Field 7 is why nothing can be substituted: it hashes the entire `executionCalldata`,
     *         which carries the gateway target, the PC value and every nested layer of the payload
     *         down to the beneficiary. Field 5 is why a banked signed request dies the moment a
     *         mandate is revoked and regranted.
     *
     * @param chainId        Push Chain's id — 42101 on Donut. Read from the live chain, never typed.
     * @param wallet         The AGW the request is bound to.
     * @param validator      The SmartSession engine.
     * @param permissionId   The mandate this request spends against.
     * @param mode           ERC-7579 mode word: single call, default exec type.
     * @param executionCalldata The encoded single execution, hashed into field 7.
     * @param nonceKey       Nonce lane.
     * @param nonceSeq       Sequence within the lane.
     * @param requestExpiry  Unix timestamp after which the request is dead; 0 disables expiry.
     * @return The digest the agent key signs.
     */
    function opHash(
        uint256 chainId,
        address wallet,
        address validator,
        bytes32 permissionId,
        bytes32 mode,
        bytes memory executionCalldata,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint48 requestExpiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN, //  1 cross-protocol isolation
                chainId, //  2 cross-chain replay
                wallet, //  3 cross-account replay
                validator, //  4 validator substitution
                permissionId, //  5 cross-mandate substitution
                mode, //  6 single->batch substitution
                keccak256(executionCalldata), //  7 payload integrity — covers every nested layer
                nonceKey, //  8 lane substitution
                nonceSeq, //  9 straight replay
                requestExpiry //  10 expiry substitution
            )
        );
    }

    /**
     * @notice Sign a digest with the agent key.
     * @dev    65 bytes, `r ‖ s ‖ v`. EIP-2098 compact signatures are deliberately unsupported by
     *         the validator, so producing one here would fail at verification.
     * @param pk     The agent's private key.
     * @param digest The operation hash.
     * @return The 65-byte signature.
     */
    function sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Assemble the signature envelope the agent door parses.
     *
     * @dev    98 bytes: one mode byte, then the 32-byte permission id, then the 65-byte signature.
     *         The wallet requires `length >= 33` and byte 0 == USE; it reads the permission id from
     *         bytes 1:33 and hands the remainder to the engine.
     *
     * @param permissionId The mandate.
     * @param sessionSig   The 65-byte signature over the op hash.
     * @return The envelope.
     */
    function envelope(bytes32 permissionId, bytes memory sessionSig) internal pure returns (bytes memory) {
        return abi.encodePacked(MODE_USE, permissionId, sessionSig);
    }

    /**
     * @notice Hash, sign and wrap in one step — what every agent script actually needs.
     * @return sig The 98-byte envelope, ready to pass to `executeWithSession`.
     */
    function signRequest(
        uint256 pk,
        uint256 chainId,
        address wallet,
        address validator,
        bytes32 permissionId,
        bytes32 mode,
        bytes memory executionCalldata,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint48 requestExpiry
    ) internal pure returns (bytes memory sig) {
        bytes32 digest = opHash(
            chainId, wallet, validator, permissionId, mode, executionCalldata, nonceKey, nonceSeq, requestExpiry
        );
        return envelope(permissionId, sign(pk, digest));
    }
}
