// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Requests } from "../../lib/Requests.sol";
import { GasSwap } from "../../lib/GasSwap.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { ICEA, IUniversalCore } from "../../lib/PushCore.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  OwnerRepatriate
 * @notice ACT 4c · Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *         THE SAME CALL THE AGENT WAS JUST REFUSED.
 *
 * @dev    Act 4b showed the agent refused for naming the CEA as an inner target. This makes the
 *         identical call and succeeds — because **the owner door consults no policy at all**.
 *         `execute` reads exactly two things: the immutable-args owner, and calldata. Gate 14 never
 *         runs because UCEP never runs.
 *
 *         ── THE SELF-CALL, VERIFIED AGAINST DEPLOYED SOURCE ──
 *
 *         The multicall entry targets the CEA ITSELF. That is not a trick: `CEA._handleMulticall`
 *         carries a dedicated guard —
 *
 *             if (calls[i].to == address(this) && calls[i].value != 0) revert InvalidInput();
 *
 *         — which rejects a self-call only when it carries value. A `value: 0` self-call is an
 *         anticipated, supported pattern, and `calls[i].to.call(...)` is a real external call, so
 *         `msg.sender == address(this)` inside it and `sendUniversalTxToUEA`'s guard is satisfied.
 *
 *         ── THREE THINGS THE CEA DOES FOR US ──
 *
 *           · `recipient` is forced to `pushAccount` — the wallet. Not ours to get wrong.
 *           · The CEA approves the gateway itself, and resets the allowance afterwards.
 *           · The return leg pays NO inbound fee: `UniversalGateway._routeUniversalTx` skips
 *             `_collectInboundFee` when `fromCEA`. **Do not fund the CEA with Sepolia ETH** — it is
 *             not needed and would be a misleading line item.
 *
 *         ── THE AMOUNT IS READ, NEVER HARDCODED ──
 *
 *         `sendUniversalTxToUEA` reverts `InsufficientBalance` when the CEA holds less than
 *         `amount`. After Act 4a it holds principal plus reward exactly — but a rehearsal that left
 *         dust makes any fixed figure wrong in the safe-looking direction. The live balance is read
 *         from a Sepolia fork.
 */
contract OwnerRepatriate is Script {
    error CEANotDeployed(address cea);
    error CEAHoldsNothing(address cea);
    error WalletOutOfPC(uint256 have, uint256 need);

    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");

        uint256 amount = _ceaBalance(cea);
        uint256 msgValue = _pcValue();
        if (agw.balance < msgValue) revert WalletOutOfPC(agw.balance, msgValue);

        DemoLog.header("ACT 4", "Bob brings it home");
        DemoLog.addrPlain("Bob signs", vm.addr(bobPk));
        DemoLog.addrPlain("Relayer submits", vm.addr(relayerPk));
        DemoLog.blank();
        DemoLog.kv("Call", "sendUniversalTxToUEA on the CEA");
        DemoLog.note("    The same call the agent was refused, one command ago.");
        DemoLog.money("Amount", amount, 6, "USDC");
        DemoLog.note("    Read from the CEA's live balance, never hardcoded.");
        DemoLog.kv("Door", "owner - no policy runs, so gate 14 never fires");
        DemoLog.blank();

        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, _ownerCall(agw, cea, amount, msgValue), bobPk, VALID_FOR);

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        DemoLog.ok("outbound sent", "the CEA will self-call and return the funds");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The agent earned it. Only Bob can take it home."));
        DemoLog.note("Run `just watch-returned` - the wallet's pUSDC should rise.");
        DemoLog.footer();
    }

    /// @dev The owner-door outbound whose far-chain payload is one CEA self-call.
    ///      Split out of `run` for stack depth: with every address a local, `run` exceeds the EVM's
    ///      16-slot reach and via_ir refuses to compile it.
    function _ownerCall(address agw, address cea, uint256 amount, uint256 msgValue)
        internal
        view
        returns (Multicall[] memory)
    {
        // value MUST be 0 — the CEA rejects a self-call carrying value.
        Multicall[] memory farCalls = Requests.singleCall(
            cea, abi.encodeCall(ICEA.sendUniversalTxToUEA, (AddressBook.sepolia("USDC"), amount, "", agw))
        );

        bytes memory outbound = Requests.outbound(
            AddressBook.donut("PRC20_USDC"),
            0, // nothing bridged outward; this call brings funds BACK
            _maxPCForGas(),
            agw,
            farCalls
        );

        return Requests.singleCall(
            agw,
            abi.encodeWithSignature(
                "execute(bytes32,bytes)",
                Requests.singleMode(),
                Requests.execution(AddressBook.donut("UniversalGatewayPC"), msgValue, outbound)
            )
        );
    }

    /// @dev Read across the boundary: the CEA lives on Sepolia, this script broadcasts on Donut.
    function _ceaBalance(address cea) internal returns (uint256) {
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        if (cea.code.length == 0) revert CEANotDeployed(cea);
        uint256 balance = IERC20(AddressBook.sepolia("USDC")).balanceOf(cea);
        if (balance == 0) revert CEAHoldsNothing(cea);

        vm.selectFork(donut);
        return balance;
    }

    function _maxPCForGas() internal view returns (uint256) {
        (address gasToken, uint256 gasFee,,,,) = IUniversalCore(AddressBook.donut("UniversalCore"))
            .getOutboundTxGasAndFees(AddressBook.donut("PRC20_USDC"), 0);
        return GasSwap.budget(gasToken, gasFee);
    }

    function _pcValue() internal view returns (uint256) {
        (,, uint256 protocolFee,,,) = IUniversalCore(AddressBook.donut("UniversalCore"))
            .getOutboundTxGasAndFees(AddressBook.donut("PRC20_USDC"), 0);
        return protocolFee + _maxPCForGas();
    }
}
