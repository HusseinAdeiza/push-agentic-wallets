// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  PushCore interfaces
 * @notice Minimal local surfaces for the Push core contracts the demo drives.
 *
 * @dev    DECLARED LOCALLY AND KEPT MINIMAL, NEVER VENDORED. Each interface carries only the
 *         functions the demo actually calls. Copying Push core's full interfaces would be surface
 *         to keep in sync for no benefit, and none of this may live in `src/` — the demo does not
 *         add production code.
 *
 *         Every signature here is transcribed from a named source and each is pinned by an
 *         assertion somewhere in the demo, so a drift shows up as a failed check rather than as an
 *         outbound that silently does nothing.
 */

/// @dev `UniversalCore` — fee quotes and the PRC20 registry, on Donut.
interface IUniversalCore {
    /**
     * @notice Quote an outbound. Also the demo's proof that a PRC20 resolves to the chain expected.
     * @param  prc20    The token whose destination chain is being asked about.
     * @param  gasLimit 0 for the per-chain default.
     * @return gasToken       PRC20 the gas fee is denominated in.
     * @return gasFee         Gas cost in that token.
     * @return protocolFee    Protocol fee in native PC. Currently 0 on Donut — read, never assumed.
     * @return gasPrice       Destination gas price.
     * @return chainNamespace e.g. "eip155:11155111" — what pins the destination.
     * @return gasLimitUsed   The limit actually applied.
     */
    function getOutboundTxGasAndFees(address prc20, uint256 gasLimit)
        external
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 protocolFee,
            uint256 gasPrice,
            string memory chainNamespace,
            uint256 gasLimitUsed
        );
}

/// @dev `UniversalGatewayPC` — the one Push-side target an agent action may reach.
interface IUniversalGatewayPC {
    function universalCore() external view returns (address);
}

/// @dev `CEAFactory` on Sepolia. Both getters return the same address for a given account.
interface ICEAFactory {
    function computeCEA(address pushAccount) external view returns (address);
    function getCEAForPushAccount(address pushAccount) external view returns (address);
    function getPushAccountForCEA(address cea) external view returns (address);
}

/**
 * @dev The CEA's one function the demo calls, and it is only reachable as a SELF-CALL from inside
 *      the CEA's own multicall — `sendUniversalTxToUEA` requires `msg.sender == address(this)`.
 *
 *      Selector `0xe7c1e3fc`. Source: `src/Interfaces/ICEA.sol` in push-chain-core-contracts,
 *      branch `core-testnet`; implementation at `src/cea/CEA.sol`.
 *
 *      `revertRecipient` must be non-zero — `address(0)` reverts `CEAErrors.InvalidInput()`.
 *      `amount` must be <= the CEA's live balance or it reverts `InsufficientBalance`, which is
 *      why callers read the balance rather than hardcoding a figure.
 */
interface ICEA {
    function sendUniversalTxToUEA(address token, uint256 amount, bytes calldata payload, address revertRecipient)
        external;
}

/// @dev `UniversalGateway` on Sepolia — Bob's inbound entry point, and the only place he transacts.
interface ISepoliaGateway {
    /**
     * @param recipient       `address(0)` credits the sender's UEA on Push.
     * @param token           `address(0)` selects the native path.
     * @param amount          Amount to bridge.
     * @param payload         The abi-encoded `UniversalPayload` to run on Push Chain.
     * @param revertRecipient Refund destination on Sepolia.
     * @param signatureData   Bob's signature over the payload digest.
     */
    struct UniversalTxRequest {
        address recipient;
        address token;
        uint256 amount;
        bytes payload;
        address revertRecipient;
        bytes signatureData;
    }

    function sendUniversalTx(UniversalTxRequest calldata req) external payable;
}

/**
 * @dev Selector pin for the struct mirror above. `sendUniversalTx` encodes its struct parameter
 *      field-for-field into the selector, so reordering or retyping a field in
 *      `UniversalTxRequest` silently stops matching the deployed gateway — and the failure is the
 *      quiet kind: the call reverts as an unknown selector, or worse, decodes into different
 *      fields.
 *
 *      `0xd372b8b3` was read out of the live implementation's bytecode
 *      (`0xb2da9444ae2b88e339e6511b034ffe0e6d290a75`, behind the Sepolia gateway proxy). Preflight
 *      asserts this constant still equals the computed selector.
 */
bytes4 constant SEND_UNIVERSAL_TX_SELECTOR =
    bytes4(keccak256("sendUniversalTx((address,address,uint256,bytes,address,bytes))"));
