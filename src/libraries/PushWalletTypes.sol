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
