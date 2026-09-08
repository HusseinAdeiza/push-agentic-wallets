// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Requests } from "../../lib/Requests.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  OwnerWithdraw
 * @notice ACT 4d · Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *         THE LAST THING THE AUDIENCE SEES.
 *
 * @dev    A plain owner-door transfer: everything the wallet holds, to Bob's own account. No
 *         outbound, no gas swap, no policy — the simplest action in the demo, and the point is that
 *         it was always available.
 *
 *         THE CLOSING NUMBER IS THE ARGUMENT. Bob started with the bridged amount and ends with
 *         MORE, because the agent earned a reward he keeps. The agent never held custody for a
 *         single block: the capital sat in a wallet Bob owns, worked through a CEA Bob's wallet
 *         controls, and came home on Bob's signature.
 *
 *         THE AMOUNT IS READ, NEVER HARDCODED — the wallet's live balance. A rehearsal that left
 *         dust, or a reward that differs from the flat figure, would otherwise leave funds behind
 *         and the closing table would quietly under-report.
 */
contract OwnerWithdraw is Script {
    error WalletHoldsNothing(address agw);

    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        IERC20 prc20 = IERC20(AddressBook.donut("PRC20_USDC"));

        uint256 balance = prc20.balanceOf(agw);
        if (balance == 0) revert WalletHoldsNothing(agw);

        uint256 ueaBefore = prc20.balanceOf(uea);

        DemoLog.header("ACT 4", "Bob withdraws");
        DemoLog.money("Wallet holds", balance, 6, "pUSDC");
        DemoLog.kv("Action", "transfer everything to Bob's own account");
        DemoLog.kv("Door", "owner - a plain transfer, no outbound, no policy");
        DemoLog.blank();

        Multicall[] memory call = Requests.singleCall(
            agw,
            abi.encodeWithSignature(
                "execute(bytes32,bytes)",
                Requests.singleMode(),
                Requests.execution(address(prc20), 0, abi.encodeCall(IERC20.transfer, (uea, balance)))
            )
        );

        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, call, bobPk, VALID_FOR);

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        _closingTable(prc20, agw, uea, ueaBefore);
    }

    /// @dev The last thing on screen. Every figure read from the chain, none of it narrated.
    function _closingTable(IERC20 prc20, address agw, address uea, uint256 ueaBefore) internal view {
        uint256 held = prc20.balanceOf(uea);

        DemoLog.ok("withdrawn", DemoLog.formatAmount(held - ueaBefore, 6, "pUSDC"));
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Closing position"));
        DemoLog.money("Bob holds", held, 6, "pUSDC");
        DemoLog.money("Wallet holds", prc20.balanceOf(agw), 6, "pUSDC");
        DemoLog.money("Agent holds", 0, 6, "pUSDC");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Bob ends with more than he started with."));
        DemoLog.note("The agent earned it. It never held custody for a single block.");
        DemoLog.footer();
    }
}
