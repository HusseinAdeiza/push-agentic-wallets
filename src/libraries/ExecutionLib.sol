// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A single ERC-7579 execution entry.
struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

/**
 * @title ExecutionLib
 * @notice Encode/decode ERC-7579 execution calldata (PRD §9.2).
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

    /// @notice Decode an ABI-encoded batch of executions.
    /// @dev BATCH — abi.encode(Execution[]). Standard encoding with padding.
    function decodeBatch(bytes calldata ecd) internal pure returns (Execution[] calldata execs) {
        assembly {
            let baseOffset := add(ecd.offset, calldataload(ecd.offset))
            execs.offset := add(baseOffset, 0x20)
            execs.length := calldataload(baseOffset)
        }
    }

    function encodeSingle(address target, uint256 value, bytes memory callData) internal pure returns (bytes memory) {
        return abi.encodePacked(target, value, callData);
    }

    function encodeBatch(Execution[] memory execs) internal pure returns (bytes memory) {
        return abi.encode(execs);
    }
}
