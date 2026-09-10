// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Identity } from "../../lib/Identity.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { BobPayload, UniversalPayload } from "../../lib/BobPayload.sol";
import { UeaDigest } from "../../lib/UeaDigest.sol";
import { ISepoliaGateway } from "../../lib/PushCore.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  Arrive
 * @notice ACT 1a · Chain: Sepolia · broadcasts with Bob's key.
 *         THE ONLY ETHEREUM TRANSACTION IN THE ENTIRE DEMO.
 *
 * @dev    WHAT THIS DOES: bridges 100 USDC into Bob's UEA on Push Chain, and prints the three
 *         addresses that do not exist yet but are already determined. `11_ArriveComplete` then
 *         submits the signed multicall that turns that balance into a funded, armed agent wallet.
 *
 *         WHY TWO SCRIPTS AND NOT ONE. The spec's original design attached the wallet-setup payload
 *         to this very transaction, so one Ethereum transaction did everything. Four probes
 *         established that the deployed build does not execute an attached inbound payload — it
 *         deploys the UEA and mints, then stops (see §3.4). The work therefore moves to a signed
 *         payload the relayer submits, which is proven on-chain and is what `11` does.
 *
 *         THE PAYLOAD IS STILL ATTACHED. It costs nothing, it is inert on today's build, and if
 *         Push core wires inbound execution up later this transaction silently becomes the
 *         single-transaction arrival the spec wanted. `11` detects that case and skips rather than
 *         double-executing.
 *
 *         THE NARRATIVE IS UNCHANGED: Bob signs with his Ethereum key and never holds a Push Chain
 *         key. What the audience sees is one Ethereum transaction, then a signature a stranger
 *         relays.
 */
contract Arrive is Script {
    error InsufficientUSDC(uint256 have, uint256 need);
    error InsufficientETH(uint256 have, uint256 need);
    error AlreadyArrived(address uea);

    /// @dev Native value for the gas leg. Must sit inside `getMinMaxValueForNative()`'s window —
    ///      measured at ~0.000398 to ~0.00398 ETH on Sepolia. This buys the UEA its PC, which is
    ///      what lets the relayer's later payload execute.
    uint256 internal constant NATIVE_VALUE = 0.002 ether;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant PUSH_CHAIN_ID = 42101;

    /// @dev Recorded by the factory. Cosmetic, but it must match between the two arrival routes.
    string internal constant WALLET_LABEL = "demo-agw-1";

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs the arrival and every owner action");
        address bob = vm.addr(bobPk);

        address gateway = AddressBook.sepolia("UniversalGateway");
        address usdc = AddressBook.sepolia("USDC");
        address prc20 = AddressBook.donut("PRC20_USDC");
        address factory = AddressBook.ours("factoryProxy");
        uint256 bridgeAmount = Amounts.bridge();

        (address uea, address agw, address cea,) =
            Identity.resolveAll(bob, vm.envString("PUSH_DONUT_RPC_URL"), vm.envString("SEPOLIA_RPC_URL"));

        _printPrediction(bob, uea, agw, cea, bridgeAmount);

        uint256 usdcBal = IERC20(usdc).balanceOf(bob);
        if (usdcBal < bridgeAmount) revert InsufficientUSDC(usdcBal, bridgeAmount);
        if (bob.balance < NATIVE_VALUE) revert InsufficientETH(bob.balance, NATIVE_VALUE);

        // The wallet-setup payload. Inert on today's build; harmless if it becomes live.
        Multicall[] memory calls = Identity.arrivalCalls(
            factory, prc20, agw, AddressBook.donut("UniversalGatewayPC"), bridgeAmount, WALLET_LABEL
        );
        UniversalPayload memory payload = BobPayload.multicallPayload(calls, 0, 0);
        bytes memory signature =
            BobPayload.signDigest(UeaDigest.hash(uea, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, 0, payload), bobPk);

        vm.startBroadcast(bobPk);
        IERC20(usdc).approve(gateway, bridgeAmount);
        ISepoliaGateway(gateway).sendUniversalTx{ value: NATIVE_VALUE }(
            ISepoliaGateway.UniversalTxRequest({
                recipient: address(0), // credit Bob's own UEA
                token: usdc,
                amount: bridgeAmount,
                payload: abi.encode(payload),
                revertRecipient: bob,
                signatureData: signature
            })
        );
        vm.stopBroadcast();

        Ledger.setAddr("bobEOA", bob);
        Ledger.setAddr("uea", uea);
        Ledger.setAddr("agw", agw);
        Ledger.setAddr("predictedCEA", cea);

        DemoLog.blank();
        DemoLog.ok("sent", string.concat(DemoLog.formatAmount(bridgeAmount, 6, "USDC"), " on its way to Push Chain"));
        DemoLog.note(
            string.concat(
                "The relay deploys Bob's UEA, mints ",
                DemoLog.formatAmount(bridgeAmount, 6, "pUSDC"),
                " to it, and delivers PC for gas."
            )
        );
        DemoLog.note("Then run act1b: the signed payload that builds the wallet.");
        DemoLog.footer();
    }

    /// @dev Part 8.7's prediction block — the demo's opening beat.
    function _printPrediction(address bob, address uea, address agw, address cea, uint256 bridgeAmount) internal view {
        DemoLog.header("ACT 1", "Bob arrives");
        DemoLog.addr("Bob", bob, false);
        DemoLog.note("    on Ethereum Sepolia. He has never touched Push Chain.");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("None of these exist yet. All three are computable today:"));
        DemoLog.addr("UEA", uea, true);
        DemoLog.addr("AGW", agw, true);
        DemoLog.addr("CEA", cea, false);
        DemoLog.blank();
        DemoLog.line(
            string.concat(
                DemoLog.bold("One transaction. "),
                DemoLog.bold(DemoLog.formatAmount(bridgeAmount, 6, "USDC")),
                DemoLog.bold(". Watch.")
            )
        );
    }
}
