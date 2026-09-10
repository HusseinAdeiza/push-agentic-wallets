// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    UniversalOutboundTxRequest,
    Multicall,
    MULTICALL_SELECTOR,
    SEND_OUTBOUND_SELECTOR
} from "../../src/libraries/PushWalletTypes.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

/**
 * @title  Requests
 * @notice Builders for the outbound request, the multicall payload and the execution calldata.
 *
 * @dev    EVERY STRUCT AND SELECTOR IS IMPORTED, NEVER REDECLARED. `UniversalOutboundTxRequest`,
 *         `Multicall`, `MULTICALL_SELECTOR` and `SEND_OUTBOUND_SELECTOR` all come from
 *         `src/libraries/PushWalletTypes.sol`, which is the authoritative mirror of the gateway's
 *         frozen structs. A local copy would stay correct exactly until someone edited one of
 *         them, and the resulting failure would be silent: a request that encodes cleanly, passes
 *         every Push-side check, emits its event, and then does nothing useful on Sepolia.
 *
 *         THE FIELDS THAT ARE NOT OPTIONAL, and why each is a whole class of wasted act:
 *           · `recipient` is ALWAYS empty. UCEP gate 11 rejects anything else.
 *           · `token` is ALWAYS set, even when `amount` is 0. Gate 5 compares it regardless.
 *           · `maxPCForGas` is ALWAYS non-zero. Gate 9 does not look at amount either.
 *           · `revertRecipient` is ALWAYS the wallet. Gate 10.
 *         Three of those four surprise people specifically on zero-amount requests, which is what
 *         Acts 4a and 4c send.
 */
library Requests {
    /// @notice Thrown when a builder is handed a value the gateway or the policy will reject.
    error EmptyMulticall();
    error ZeroMaxPCForGas();
    error ZeroToken();

    /**
     * @notice Wrap multicall entries in the magic-prefixed payload both the UEA and the CEA parse.
     *
     * @dev    THE PREFIX IS `abi.encodePacked`; THE ARRAY IS `abi.encode`. Reversed, the receiver
     *         does not see a multicall at all — it treats the whole thing as a single call, and the
     *         failure appears one chain away from its cause.
     *
     * @param calls Entries, executed in order; the first failure bubbles and reverts the whole batch.
     * @return The payload.
     */
    function multicallPayload(Multicall[] memory calls) internal pure returns (bytes memory) {
        if (calls.length == 0) revert EmptyMulticall();
        return abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls));
    }

    /// @notice A one-entry multicall — every agent request in the demo, and both owner outbounds.
    /// @param to    Far-chain target.
    /// @param data  Far-chain calldata.
    function singleCall(address to, bytes memory data) internal pure returns (Multicall[] memory calls) {
        calls = new Multicall[](1);
        calls[0] = Multicall({ to: to, value: 0, data: data });
    }

    /**
     * @notice Build the full `sendUniversalTxOutbound` calldata.
     *
     * @dev    The destination chain is NOT a parameter anywhere in this flow. The gateway derives
     *         it from the token, so pinning `token` to the Sepolia-backed PRC20 is what pins the
     *         destination to Sepolia. There is no chain selector to get wrong — and none to set.
     *
     * @param token           The PRC20. Required even when `amount` is zero.
     * @param amount          Amount to burn on Push and unlock on Sepolia. Zero is valid.
     * @param maxPCForGas     Gas-swap cap. Must be non-zero.
     * @param revertRecipient Refund destination — always the wallet.
     * @param calls           Multicall entries for the CEA.
     * @return The calldata for the gateway.
     */
    function outbound(
        address token,
        uint256 amount,
        uint256 maxPCForGas,
        address revertRecipient,
        Multicall[] memory calls
    ) internal pure returns (bytes memory) {
        if (token == address(0)) revert ZeroToken();
        if (maxPCForGas == 0) revert ZeroMaxPCForGas();

        return abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: "", // gate 11
                token: token, // gate 5 — set even when amount is 0
                amount: amount, // gates 6, 7
                gasLimit: 0, // per-chain default
                gasPrice: 0, // per-chain default
                maxPCForGas: maxPCForGas, // gate 9 — non-zero even when amount is 0
                payload: multicallPayload(calls), // gates 12-16
                revertRecipient: revertRecipient // gate 10
            })
        );
    }

    /**
     * @notice The ERC-7579 execution calldata that carries an outbound to the gateway.
     *
     * @dev    `pcValue` travels INSIDE this blob and is what UCEP gate 8 compares against
     *         `maxPCPerCall`. It is Push-native and has nothing to do with gate 16's per-entry
     *         cap, which is in destination-chain units — conflating the two is a real bug this
     *         design once carried.
     *
     * @param gateway         `UniversalGatewayPC`.
     * @param pcValue         Native PC for the protocol fee and gas swap.
     * @param outboundCalldata From `outbound` above.
     * @return The single-execution encoding, `abi.encodePacked(target, value, callData)`.
     */
    function execution(address gateway, uint256 pcValue, bytes memory outboundCalldata)
        internal
        pure
        returns (bytes memory)
    {
        return ExecutionLib.encodeSingle(gateway, pcValue, outboundCalldata);
    }

    /// @notice `CALLTYPE_SINGLE` + `EXECTYPE_DEFAULT` — the only mode the agent door accepts.
    /// @dev    The agent path never batches at the ERC-7579 layer; batching lives inside the
    ///         multicall payload instead, where the policy can bound it.
    function singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }
}
