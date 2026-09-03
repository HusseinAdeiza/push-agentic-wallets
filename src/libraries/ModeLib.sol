// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ModeLib
 * @notice ERC-7579 execution mode encoding/decoding. Ported verbatim from
 *         erc7579/erc7579-implementation/src/lib/ModeLib.sol.
 *
 * Layout:
 * | CALLTYPE | EXECTYPE |  UNUSED  | ModeSelector | ModePayload |
 * | 1 byte   | 1 byte   |  4 bytes | 4 bytes      | 22 bytes    |
 */
type ModeCode is bytes32;

type CallType is bytes1;

type ExecType is bytes1;

type ModeSelector is bytes4;

type ModePayload is bytes22;

CallType constant CALLTYPE_SINGLE = CallType.wrap(0x00);
CallType constant CALLTYPE_BATCH = CallType.wrap(0x01);
CallType constant CALLTYPE_STATIC = CallType.wrap(0xFE);
CallType constant CALLTYPE_DELEGATECALL = CallType.wrap(0xFF);

ExecType constant EXECTYPE_DEFAULT = ExecType.wrap(0x00);
ExecType constant EXECTYPE_TRY = ExecType.wrap(0x01);

ModeSelector constant MODE_DEFAULT = ModeSelector.wrap(bytes4(0x00000000));

using { _eqCallType as == } for CallType global;
using { _neqCallType as != } for CallType global;
using { _eqExecType as == } for ExecType global;
using { _neqExecType as != } for ExecType global;
using { _eqModeSelector as == } for ModeSelector global;

function _eqCallType(CallType a, CallType b) pure returns (bool) {
    return CallType.unwrap(a) == CallType.unwrap(b);
}

function _neqCallType(CallType a, CallType b) pure returns (bool) {
    return CallType.unwrap(a) != CallType.unwrap(b);
}

function _eqExecType(ExecType a, ExecType b) pure returns (bool) {
    return ExecType.unwrap(a) == ExecType.unwrap(b);
}

function _neqExecType(ExecType a, ExecType b) pure returns (bool) {
    return ExecType.unwrap(a) != ExecType.unwrap(b);
}

function _eqModeSelector(ModeSelector a, ModeSelector b) pure returns (bool) {
    return ModeSelector.unwrap(a) == ModeSelector.unwrap(b);
}

library ModeLib {
    /// @notice Decode a packed mode into its four components.
    function decode(ModeCode mode)
        internal
        pure
        returns (CallType callType, ExecType execType, ModeSelector modeSelector, ModePayload payload)
    {
        assembly {
            callType := mode
            execType := shl(8, mode)
            modeSelector := shl(48, mode)
            payload := shl(80, mode)
        }
    }

    /// @notice Encode four components into a packed mode.
    function encode(CallType callType, ExecType execType, ModeSelector mode, ModePayload payload)
        internal
        pure
        returns (ModeCode)
    {
        return ModeCode.wrap(
            bytes32(
                abi.encodePacked(callType, execType, bytes4(0), ModeSelector.unwrap(mode), ModePayload.unwrap(payload))
            )
        );
    }

    /// @notice Convenience encoder for a default single call.
    function encodeSimpleSingle() internal pure returns (ModeCode) {
        return encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0x00));
    }

    /// @notice Convenience encoder for a default batch call.
    function encodeSimpleBatch() internal pure returns (ModeCode) {
        return encode(CALLTYPE_BATCH, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(0x00));
    }

    /// @notice Extract only the call type from a packed mode.
    function getCallType(ModeCode mode) internal pure returns (CallType callType) {
        assembly {
            callType := mode
        }
    }
}
