// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PushWalletErrors } from "./PushWalletErrors.sol";

/// @notice A single ERC-7579 execution entry.
struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

/**
 * @title ExecutionLib
 * @notice Encode/decode ERC-7579 execution calldata.
 *
 * @dev ⚠ REVIEW REQUIRED — the encodings differ per call type and mixing them
 *      produces plausible-looking garbage:
 *        - SINGLE is abi.encodePacked(target, value, callData)  (NOT abi.encode)
 *        - BATCH  is abi.encode(Execution[])                    (standard, padded)
 */
library ExecutionLib {
    /// @notice Decode a packed single execution.
    /// @dev SINGLE — abi.encodePacked(target, value, callData). NOT abi.encode.
    function decodeSingle(bytes calldata ecd)
        internal
        pure
        returns (address target, uint256 value, bytes calldata callData)
    {
        target = address(bytes20(ecd[0:20]));
        value = uint256(bytes32(ecd[20:52]));
        callData = ecd[52:];
    }

    /**
     * @notice Decode an ABI-encoded batch of executions.
     * @dev BATCH — abi.encode(Execution[]). Standard encoding with padding.
     *
     *      DIVERGENCE FROM THE REFERENCE IMPLEMENTATION (deliberate — see DEVIATIONS
     *      D-4). The upstream version reads the array length straight out of
     *      unvalidated calldata. Given SINGLE-encoded calldata it decodes a length of
     *      zero and returns an empty batch, so `execute` in batch mode SUCCEEDS having
     *      performed no call at all — a silent no-op that still consumes a nonce and
     *      emits SessionExecuted. The bounds checks below turn that into a revert.
     *
     *      Each entry is a head slot (one 32-byte offset), so `length` entries require
     *      at least `32 * length` bytes after the length word. That is the minimum
     *      stride used to reject impossible lengths cheaply, before any entry is read.
     */
    function decodeBatch(bytes calldata ecd) internal pure returns (Execution[] calldata execs) {
        if (ecd.length < 32) revert PushWalletErrors.MalformedBatchCalldata();

        uint256 baseOffset;
        uint256 len;
        assembly {
            baseOffset := calldataload(ecd.offset)
        }

        // The offset word must land inside the blob with room for the length word.
        if (baseOffset > ecd.length || ecd.length - baseOffset < 32) {
            revert PushWalletErrors.MalformedBatchCalldata();
        }

        assembly {
            len := calldataload(add(ecd.offset, baseOffset))
        }

        // `len` head slots of 32 bytes each must fit in what remains.
        uint256 remaining = ecd.length - baseOffset - 32;
        if (len > remaining / 32) revert PushWalletErrors.MalformedBatchCalldata();

        assembly {
            execs.offset := add(add(ecd.offset, baseOffset), 0x20)
            execs.length := len
        }
    }

    function encodeSingle(address target, uint256 value, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData);
    }

    function encodeBatch(Execution[] memory execs) internal pure returns (bytes memory) {
        return abi.encode(execs);
    }
}
