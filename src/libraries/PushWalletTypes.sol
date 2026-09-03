// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice Mirror of push-chain-gateway .../libraries/TypesUGPC.sol
 * @dev MUST match field-for-field and in order. Verified against
 *      contracts/evm-gateway/src/libraries/TypesUGPC.sol.
 */
struct UniversalOutboundTxRequest {
    bytes recipient; // raw destination address on source chain (bytes for SVM compat)
    address token; // PRC20 token address on Push Chain
    uint256 amount; // amount to withdraw (burn on Push, unlock at origin)
    uint256 gasLimit; // gas limit for fee quote; 0 = per-chain default
    uint256 gasPrice; // gas price override; 0 = per-chain default
    uint256 maxPCForGas; // max native PC for gas swap; 0 = no cap
    bytes payload; // ABI-encoded calldata to execute on origin chain
    address revertRecipient; // address to receive funds in case of revert
}

/**
 * @notice Mirror of push-chain-core .../libraries/Types.sol
 * @dev Batch call entry for multicall execution.
 */
struct Multicall {
    address to;
    uint256 value;
    bytes data;
}

/// @dev bytes4(keccak256("UEA_MULTICALL")) — magic prefix for multicall payloads.
bytes4 constant MULTICALL_SELECTOR = bytes4(keccak256("UEA_MULTICALL"));

/**
 * @dev The gateway's outbound entry point — the ONE selector an agent mandate may ever name.
 *
 *      DECLARED HERE, BESIDE THE STRUCT IT TAKES, AND NOWHERE ELSE. The wallet's grant-shape check
 *      and the policy's request-decode gate must agree on this value exactly: the wallet refuses to
 *      grant a mandate naming any other selector, and the policy refuses to validate a request
 *      carrying any other selector. Two independently hand-typed copies of the same signature
 *      string is the kind of duplication that stays correct only until one of them is edited, and
 *      the failure would be silent in the safe direction for one contract and open in the other.
 *
 *      The signature string spells out `UniversalOutboundTxRequest` field-for-field because that is
 *      how Solidity encodes a struct parameter into a selector. It is therefore load-bearing on the
 *      mirror above: reorder or retype a field there without editing this string and the selector
 *      silently stops matching the deployed gateway.
 */
bytes4 constant SEND_OUTBOUND_SELECTOR =
    bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

/**
 * @dev Domain separator for the wallet's operation hash — distinct from every other protocol's, so
 *      a signature produced for this system can never be replayed as one for another.
 *
 *      The `v3` is the ARCHITECTURE GENERATION and is frozen: it is mixed into every agent
 *      signature, so changing the string invalidates every outstanding signed request. It is
 *      deliberately not tied to the wallet contract's own semver, which advances with releases.
 */
bytes32 constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v3");
