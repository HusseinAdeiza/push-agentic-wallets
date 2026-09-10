// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

/// @dev Bob's identity as Push core keys it. `owner` is 20 RAW bytes — see `accountId` below.
struct UniversalAccountId {
    string chainNamespace;
    string chainId;
    bytes owner;
}

/// @dev The nine fields Bob signs. Mirrors Push core's `UniversalPayload`.
struct UniversalPayload {
    address to;
    uint256 value;
    bytes data;
    uint256 gasLimit;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 nonce;
    uint256 deadline;
    uint8 vType;
}

/// @dev Minimal surface of Bob's UEA. Declared locally rather than vendored: the demo needs three
///      functions, and copying Push core's whole interface would be surface to keep in sync.
interface IUEA {
    /// @notice EIP-712 digest over the nine payload fields. THE authority on what to sign.
    function getUniversalPayloadHash(UniversalPayload calldata payload) external view returns (bytes32);
    /// @notice The UEA's own nonce. Read immediately before signing, never cached.
    function nonce() external view returns (uint256);
    /// @notice Anyone may submit; the signature is the authority.
    function executeUniversalTx(UniversalPayload calldata payload, bytes calldata signature) external;
}

/// @dev Minimal surface of `UEAFactory`.
interface IUEAFactory {
    function computeUEA(UniversalAccountId calldata id) external view returns (address);
}

/**
 * @title  BobPayload
 * @notice Builds and signs the payloads Bob authorises on Push Chain with his Ethereum key.
 *
 * @dev    AFTER THE INITIAL BRIDGE, BOB SIGNS AND THE RELAYER SUBMITS. No further Ethereum
 *         transaction is needed for any owner action — which is the claim Act 1 exists to make
 *         concrete.
 *
 *         THE DIGEST IS ASKED FOR, NOT REBUILT. Once the UEA exists, `getUniversalPayloadHash` is
 *         called on it and whatever it returns is signed. That cannot drift from Push core's
 *         typehashes, whereas a local EIP-712 reimplementation silently can — and a wrong digest
 *         produces a signature that verifies against nothing, with the failure surfacing far from
 *         its cause. The pre-deployment case is the one exception and is handled by the caller.
 *
 *         THE NONCE IS ALWAYS READ FROM THE UEA, NEVER FROM THE LEDGER. It increments on every
 *         execution; a cached value produces exactly the same undebuggable failure as a wrong
 *         digest. `payloadFor` below takes the nonce as an argument so the caller must fetch it.
 *
 *         ENTRIES ARE ASSEMBLED BY THE CALLER, NOT HARDCODED HERE. Whether the arrival is one
 *         three-entry multicall or three separate signed payloads is not yet settled — it depends
 *         on whether Push's inbound pipeline forwards an attached payload, which the probe script
 *         decides. Keeping the entries an array the caller builds makes that a loop change rather
 *         than a rewrite.
 */
library BobPayload {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev `signedVerification`. The path where the signature is the authority.
    uint8 internal constant V_TYPE_SIGNED = 0;

    /// @dev Push core's namespace for EVM chains.
    string internal constant NAMESPACE = "eip155";

    /**
     * @notice Bob's `UniversalAccountId`.
     *
     * @dev    `owner` IS 20 RAW BYTES, NOT PADDED. `UEA_EVM.verifyUniversalPayloadSignature`
     *         compares against `address(bytes20(id.owner))`; a 32-byte padded value yields a
     *         different address and every signature check fails.
     *
     * @param sourceChainId Bob's chain as a decimal string — "11155111" for Sepolia.
     * @param bobEOA        Bob's Ethereum address.
     */
    function accountId(string memory sourceChainId, address bobEOA) internal pure returns (UniversalAccountId memory) {
        return UniversalAccountId({
            chainNamespace: NAMESPACE,
            chainId: sourceChainId,
            owner: abi.encodePacked(bobEOA) // 20 raw bytes
        });
    }

    /**
     * @notice The chain hash Push core derives from a namespace and id.
     * @dev    Reused as the mandate's `destChainHash` so the two agree and an indexer can join on
     *         it. Stored by URP but never gated — the destination is already pinned by the asset.
     */
    function chainHash(string memory chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(NAMESPACE, chainId));
    }

    /// @notice Predict Bob's UEA. Deterministic, and computable long before it exists.
    function predictUEA(address ueaFactory, string memory sourceChainId, address bobEOA)
        internal
        view
        returns (address)
    {
        return IUEAFactory(ueaFactory).computeUEA(accountId(sourceChainId, bobEOA));
    }

    // ──────────────────────────────── payloads ────────────────────────────────

    /**
     * @notice A payload whose data is a MULTICALL — the branch the UEA takes when `data` begins
     *         with `MULTICALL_SELECTOR`.
     *
     * @param calls    Entries, executed in order. Assembled by the caller.
     * @param nonce    Read from the UEA immediately before signing.
     * @param deadline Absolute timestamp; 0 means no deadline.
     */
    function multicallPayload(Multicall[] memory calls, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (UniversalPayload memory)
    {
        return UniversalPayload({
            to: address(0), // ignored on the multicall branch
            value: 0,
            data: abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls)),
            gasLimit: 3_000_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: nonce,
            deadline: deadline,
            vType: V_TYPE_SIGNED
        });
    }

    /**
     * @notice A payload that makes ONE call — every owner action after the arrival.
     *
     * @param to       Target on Push Chain: the AGW, or a PRC20.
     * @param data     Calldata. Must not begin with `MULTICALL_SELECTOR`, or the UEA takes the
     *                 other branch and ignores `to` entirely.
     * @param nonce    Read from the UEA immediately before signing.
     * @param deadline Absolute timestamp; 0 means no deadline.
     */
    function callPayload(address to, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (UniversalPayload memory)
    {
        return UniversalPayload({
            to: to,
            value: 0,
            data: data,
            gasLimit: 3_000_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: nonce,
            deadline: deadline,
            vType: V_TYPE_SIGNED
        });
    }

    // ──────────────────────────────── signing ────────────────────────────────

    /**
     * @notice Sign a payload against a DEPLOYED UEA.
     *
     * @dev    THE PREFERRED PATH. The digest is whatever the UEA itself says it is, so it cannot
     *         drift from Push core's typehashes.
     *
     * @param uea     Bob's deployed UEA.
     * @param payload The payload to sign.
     * @param bobPk   Bob's private key.
     * @return 65-byte `r ‖ s ‖ v`.
     */
    function sign(address uea, UniversalPayload memory payload, uint256 bobPk) internal view returns (bytes memory) {
        return _sign(IUEA(uea).getUniversalPayloadHash(payload), bobPk);
    }

    /// @notice Read the UEA's current nonce. Call immediately before signing.
    function currentNonce(address uea) internal view returns (uint256) {
        return IUEA(uea).nonce();
    }

    /**
     * @notice Sign a digest computed elsewhere.
     * @dev    For the arrival only, where the UEA does not exist yet and so cannot be asked. The
     *         digest must be derived against the PREDICTED UEA address, since the EIP-712 domain
     *         binds the verifying contract.
     */
    function signDigest(bytes32 digest, uint256 bobPk) internal pure returns (bytes memory) {
        return _sign(digest, bobPk);
    }

    // ────────────────────────── the proven owner path ──────────────────────────

    /**
     * @notice Sign an owner payload against the live UEA and hand back everything needed to submit
     *         it — the shape every owner action after the arrival takes.
     *
     * @dev    PROVEN ON-CHAIN: Donut tx `0x88b2ac09…`, block 22638186. The owner signed, a relayer
     *         with no authority submitted, the multicall executed, and the UEA's nonce advanced
     *         0 → 1. Resubmitting the same signed payload then reverted, so replay is refused by
     *         the nonce rather than by anything the caller has to remember.
     *
     *         THE NONCE IS READ HERE, NOT PASSED IN. That is the whole point: a caller holding a
     *         stale nonce produces a signature that verifies against nothing, and the failure
     *         appears far from its cause. Reading it immediately before signing makes that
     *         impossible to get wrong.
     *
     *         `deadline` is a duration from now, not an absolute stamp, because every caller wants
     *         "valid for the next few minutes" and converting by hand is one more chance to pass a
     *         timestamp already in the past.
     *
     * @param uea      The owner's deployed UEA.
     * @param calls    Multicall entries, executed in order.
     * @param bobPk    The owner's private key. Never logged.
     * @param validFor Seconds the payload stays valid; 0 means no deadline.
     * @return payload   The payload to submit.
     * @return signature The owner's 65-byte signature over it.
     */
    function signedMulticall(address uea, Multicall[] memory calls, uint256 bobPk, uint256 validFor)
        internal
        view
        returns (UniversalPayload memory payload, bytes memory signature)
    {
        payload = multicallPayload(calls, currentNonce(uea), validFor == 0 ? 0 : block.timestamp + validFor);
        signature = sign(uea, payload, bobPk);
    }

    /**
     * @notice The single-call equivalent of `signedMulticall`.
     * @param uea      The owner's deployed UEA.
     * @param to       Target on Push Chain.
     * @param data     Calldata. Must not begin with `MULTICALL_SELECTOR`.
     * @param bobPk    The owner's private key.
     * @param validFor Seconds the payload stays valid; 0 means no deadline.
     */
    function signedCall(address uea, address to, bytes memory data, uint256 bobPk, uint256 validFor)
        internal
        view
        returns (UniversalPayload memory payload, bytes memory signature)
    {
        payload = callPayload(to, data, currentNonce(uea), validFor == 0 ? 0 : block.timestamp + validFor);
        signature = sign(uea, payload, bobPk);
    }

    function _sign(bytes32 digest, uint256 bobPk) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
