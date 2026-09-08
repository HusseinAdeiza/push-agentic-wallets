// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { AddressBook } from "./AddressBook.sol";
import { Ledger } from "./Ledger.sol";
import { Requests } from "./Requests.sol";
import { AgentSigning } from "./AgentSigning.sol";
import { GasSwap } from "./GasSwap.sol";
import { IUniversalCore } from "./PushCore.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";

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
}

/**
 * @title  AgentRequest
 * @notice Builds a complete agent request: the far-chain multicall, the outbound, the execution
 *         calldata, and the signature over the ten-field op hash.
 *
 * @dev    DECLARED ONCE BECAUSE ELEVEN SCRIPTS BUILD THE SAME SHAPE. Act 2 stakes, Act 4a unstakes,
 *         and the six gauntlet scripts each vary exactly one field of this structure in order to be
 *         refused. If each assembled its own request, a gauntlet script could fail for a reason
 *         other than the one it claims to demonstrate — which is the one bug that would make the
 *         whole act dishonest rather than merely broken.
 *
 *         So the gauntlet mutates a request built HERE, and every negative differs from the
 *         positive in one named way.
 *
 *         WHAT THE AGENT SIGNS, AND WHY NOTHING CAN BE SWAPPED. `executionCalldata` carries the
 *         gateway target, the PC value and the entire nested payload down to the beneficiary, and
 *         field 7 of the op hash is its keccak. Field 5 is the permission id, which is what kills a
 *         banked request the moment a mandate is revoked and regranted.
 *
 *         THE REQUEST IS NOT PAYABLE. The PC comes from the wallet's own balance — which is why the
 *         seam in Act 1c exists at all.
 */
library AgentRequest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev One lane for the whole demo. The lane is a signed field, so it cannot be substituted.
    uint192 internal constant NONCE_KEY = 0;

    /// @dev Long enough to relay by hand, short enough that the expiry field is genuinely exercised.
    uint48 internal constant EXPIRY_WINDOW = 30 minutes;

    /// @dev Everything a script needs to submit, and everything a gauntlet script needs to mutate.
    struct Built {
        address wallet;
        address engine;
        bytes32 mode;
        bytes executionCalldata;
        bytes signature;
        uint64 nonceSeq;
        uint48 requestExpiry;
        uint256 pcValue;
        uint256 amount;
    }

    /**
     * @notice Build and sign a request whose far-chain payload is a single call.
     *
     * @dev    The PC value is priced from the live pool every time rather than read from the
     *         ledger, because `gasFee` is recomputed from the gas price when the transaction lands.
     *         A cached figure is how the first live Act 1 run reverted `STF`.
     *
     * @param agentPk  The agent's key. Never logged.
     * @param amount   PRC20 to bridge. Zero for a request that only carries calldata.
     * @param target   Far-chain contract the entry calls.
     * @param data     Far-chain calldata.
     * @return b       The built request.
     */
    function single(uint256 agentPk, uint256 amount, address target, bytes memory data)
        internal
        view
        returns (Built memory b)
    {
        return build(agentPk, amount, Requests.singleCall(target, data));
    }

    /// @notice Build and sign a request from arbitrary multicall entries.
    function build(uint256 agentPk, uint256 amount, Multicall[] memory calls) internal view returns (Built memory b) {
        b.wallet = Ledger.addr("agw", "10_Arrive");
        b.engine = AddressBook.ours("sessionEngine");
        b.mode = Requests.singleMode();
        b.amount = amount;
        b.nonceSeq = uint64(Ledger.num("nonceSeq", "14_GrantMandate"));
        b.requestExpiry = uint48(block.timestamp) + EXPIRY_WINDOW;
        b.pcValue = pcValue();

        b.executionCalldata = Requests.execution(
            AddressBook.donut("UniversalGatewayPC"),
            b.pcValue,
            Requests.outbound(AddressBook.donut("PRC20_USDC"), amount, maxPCForGas(), b.wallet, calls)
        );

        b.signature = sign(agentPk, b);
    }

    /**
     * @notice Sign (or re-sign) a request. Exposed so a gauntlet script can mutate a field and
     *         produce a VALID signature over the mutated request — otherwise it would be refused
     *         for a bad signature rather than by the gate it means to demonstrate.
     */
    function sign(uint256 agentPk, Built memory b) internal view returns (bytes memory) {
        return AgentSigning.signRequest(
            agentPk,
            block.chainid,
            b.wallet,
            b.engine,
            Ledger.word("permissionId", "14_GrantMandate"),
            b.mode,
            b.executionCalldata,
            NONCE_KEY,
            b.nonceSeq,
            b.requestExpiry
        );
    }

    /// @notice Submit. The caller is NOT the authority — the signature is, so anyone may relay.
    function submit(Built memory b) internal {
        IAgentDoor(b.wallet)
            .executeWithSession(
                b.engine, b.mode, b.executionCalldata, b.signature, NONCE_KEY, b.nonceSeq, b.requestExpiry
            );
    }

    /// @notice The raw call, for scripts that must inspect the revert rather than let it bubble.
    function encodeSubmit(Built memory b) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IAgentDoor.executeWithSession,
            (b.engine, b.mode, b.executionCalldata, b.signature, NONCE_KEY, b.nonceSeq, b.requestExpiry)
        );
    }

    // ────────────────────────────────── pricing ──────────────────────────────────

    /// @dev The gas-swap budget, priced from the pool. See `GasSwap` for the unit trap.
    function maxPCForGas() internal view returns (uint256) {
        (address gasToken, uint256 gasFee,,,,) = _quote();
        return GasSwap.budget(gasToken, gasFee);
    }

    /// @dev What the request carries as `value` inside `executionCalldata`. Gate 8 compares this
    ///      against `maxPCPerCall`; it is Push-native and unrelated to gate 16's per-entry cap,
    ///      which is in destination-chain units.
    function pcValue() internal view returns (uint256) {
        (,, uint256 protocolFee,,,) = _quote();
        return protocolFee + maxPCForGas();
    }

    function _quote() private view returns (address, uint256, uint256, uint256, string memory, uint256) {
        return
            IUniversalCore(AddressBook.donut("UniversalCore"))
                .getOutboundTxGasAndFees(AddressBook.donut("PRC20_USDC"), 0);
    }
}
