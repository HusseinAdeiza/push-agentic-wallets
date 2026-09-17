// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

import { AddressBook } from "./AddressBook.sol";
import { AgentSigning } from "./AgentSigning.sol";

/// @dev The agent door. Argument order is frozen; see `PushAgentWallet.executeWithSession`.
interface IAgentDoor {
    function executeWithSession(
        address validator,
        bytes32 mode,
        bytes calldata executionCalldata,
        bytes calldata signature,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint48 requestExpiry
    ) external;

    /// @dev The lane counter. READ IMMEDIATELY BEFORE SIGNING, never cached — see `build`.
    function getNonce(uint192 nonceKey) external view returns (uint64);
}

/**
 * @title  NativeRequest
 * @notice Builds a complete Push-native agent request: the execution calldata, and the signature
 *         over the ten-field op hash.
 *
 * @dev    THE WHOLE DIFFERENCE FROM THE CROSS-CHAIN DEMO IS ONE LINE. Compare:
 *
 *           cross-chain, four layers:
 *             encodeSingle(gateway, pcValue,
 *               sendUniversalTxOutbound(UniversalOutboundTxRequest{ …,
 *                 payload: MULTICALL_SELECTOR ‖ abi.encode([Multicall{ stakeDummy, 0, stakeFor(cea, amt) }]) }))
 *
 *           native, one layer:
 *             encodeSingle(stakeDummy, 0, stakeFor(wallet, amt))
 *
 *         Everything AROUND it is identical — the same agent door, the same ten-field op hash, the
 *         same 98-byte envelope, the same mode word, the same lane semantics. That is why
 *         `AgentSigning.sol` is reused BYTE-FOR-BYTE from `demo/lib/` rather than forked, and why
 *         `demo-native/test/AgentSigning.t.sol` asserts the two copies are identical. If this file
 *         ever needs to fork it, the two modes have diverged somewhere they should not have, and
 *         that is a finding to report rather than a change to make.
 *
 *         THE REQUEST CARRIES NO VALUE AND NEEDS NO QUOTE. There is no protocol fee, no gas swap,
 *         no `UniversalCore` call. The relayer pays ordinary transaction gas and that is the only
 *         cost — which is why there is no `GasSwap` or `PushCore` equivalent in this folder.
 */
library NativeRequest {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Long enough to relay by hand, short enough that the expiry field is genuinely
    ///      exercised. Zero would disable expiry; this demo never sends zero.
    uint48 internal constant EXPIRY_WINDOW = 30 minutes;

    /// @dev Everything a script needs to submit, and everything a gauntlet script mutates.
    struct Built {
        address wallet;
        address engine;
        bytes32 permissionId;
        bytes32 mode;
        bytes executionCalldata;
        bytes signature;
        uint192 nonceKey;
        uint64 nonceSeq;
        uint48 requestExpiry;
        // Mirrors of what the calldata encodes, so a script can print them without re-decoding.
        address target;
        uint256 value;
        uint256 amount;
    }

    /**
     * @notice Build and sign a request that calls `target` with `data`, carrying no value.
     *
     * @param agentPk   The agent's key. Never logged.
     * @param wallet    The wallet the request is bound to.
     * @param lane      Nonce lane. ONE LANE PER MANDATE (SDK convention).
     * @param target    The contract the wallet will call — a real contract on Push, not a gateway.
     * @param data      The calldata.
     * @param amount    Informational mirror for on-screen output; not part of the encoding.
     */
    function build(
        uint256 agentPk,
        address wallet,
        bytes32 permissionId,
        uint192 lane,
        address target,
        bytes memory data,
        uint256 amount
    ) internal view returns (Built memory b) {
        return buildWithValue(agentPk, wallet, permissionId, lane, target, data, amount, 0);
    }

    /**
     * @notice Build and sign a request carrying native value. Used ONLY by G5, which exists to be
     *         refused by gate N6 against a cap of zero.
     */
    function buildWithValue(
        uint256 agentPk,
        address wallet,
        bytes32 permissionId,
        uint192 lane,
        address target,
        bytes memory data,
        uint256 amount,
        uint256 value
    ) internal view returns (Built memory b) {
        b.wallet = wallet;
        b.engine = AddressBook.ours("sessionEngine");
        b.permissionId = permissionId;
        b.mode = singleMode();
        b.nonceKey = lane;
        // READ FROM THE CHAIN, NEVER FROM THE LEDGER. The lane survives regrants by design, so a
        // cached zero is wrong the moment a mandate is granted twice — which is exactly the bug the
        // cross-chain demo shipped (`InvalidNonce(0, 1, 0)` on the second rehearsal).
        b.nonceSeq = IAgentDoor(wallet).getNonce(lane);
        b.requestExpiry = uint48(block.timestamp) + EXPIRY_WINDOW;
        b.target = target;
        b.value = value;
        b.amount = amount;

        b.executionCalldata = ExecutionLib.encodeSingle(target, value, data);
        b.signature = sign(agentPk, b);

        return b;
    }

    /**
     * @notice Sign (or RE-sign) a request.
     *
     * @dev    Exposed so a gauntlet script can mutate one field and produce a VALID signature over
     *         the mutated request. Without this, every negative would be refused for a bad
     *         signature rather than by the gate it claims to demonstrate — which is the one defect
     *         that would make the gauntlet dishonest rather than merely broken.
     *
     *         G6 is the deliberate exception: it re-submits the ORIGINAL bytes unchanged, because a
     *         replay is precisely a request that was valid once.
     */
    function sign(uint256 agentPk, Built memory b) internal view returns (bytes memory) {
        return AgentSigning.signRequest(
            agentPk,
            block.chainid,
            b.wallet,
            b.engine,
            b.permissionId,
            b.mode,
            b.executionCalldata,
            b.nonceKey,
            b.nonceSeq,
            b.requestExpiry
        );
    }

    /// @notice Submit. THE CALLER IS NOT THE AUTHORITY — the signature is, so anyone may relay.
    function submit(Built memory b) internal {
        IAgentDoor(b.wallet)
            .executeWithSession(
                b.engine, b.mode, b.executionCalldata, b.signature, b.nonceKey, b.nonceSeq, b.requestExpiry
            );
    }

    /// @notice The raw call, for scripts that must inspect a revert rather than let it bubble.
    function encodeSubmit(Built memory b) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IAgentDoor.executeWithSession,
            (b.engine, b.mode, b.executionCalldata, b.signature, b.nonceKey, b.nonceSeq, b.requestExpiry)
        );
    }

    /// @notice `CALLTYPE_SINGLE` + `EXECTYPE_DEFAULT` — the only mode the agent door accepts.
    function singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }
}
