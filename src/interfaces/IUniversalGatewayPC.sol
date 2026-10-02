// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalOutboundTxRequest } from "../libraries/Types.sol";

/**
 * @title IUniversalGatewayPC
 * @notice Minimal local interface for the Push Chain outbound gateway.
 * @dev    Only the signatures we call are declared, to avoid a cross-repo build
 *         dependency. `sendUniversalTxOutbound` burns PRC20 from msg.sender and
 *         stamps msg.sender into the emitted event — which is what determines
 *         the CEA that executes on the destination chain.
 */
interface IUniversalGatewayPC {
    /// @notice Send a universal outbound transaction from Push Chain to an origin chain.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable;
}
