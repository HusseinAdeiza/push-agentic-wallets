// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  AccompliceDrains
 * @notice ACT 4f (3 of 5) · ⚠️ THE AGENT SUCCEEDS. The money leaves, and nothing refuses it.
 *
 * @dev    THE ONLY SCRIPT IN EITHER DEMO WHERE AN AGENT REQUEST DOES SOMETHING BAD AND WORKS.
 *
 *         THE SPENDER IS THE RELAYER, NOT THE AGENT — AND THAT IS LOAD-BEARING, NOT COSMETIC.
 *
 *         To drain an allowance, someone must call `transferFrom` AS the approved spender, from an
 *         EOA, paying gas. `ERC20.transferFrom` takes its spender from `_msgSender()` and checks
 *         THAT address's allowance, so a signature cannot stand in and the relayer cannot submit on
 *         the agent's behalf. If the spender were the agent, THE AGENT KEY WOULD NEED PC — breaking
 *         this demo's own rule that the agent never holds funds, on stage, in the act about where
 *         the guarantee ends.
 *
 *         So the agent approves the RELAYER, which already holds PC and is already established as
 *         "not an authority". The relayer then takes the money.
 *
 *         AND IT IS THE BETTER STORY. The agent did not steal for itself — it HANDED THE USER'S
 *         MONEY TO A THIRD PARTY. That is exactly what an unpinned spender argument permits, and it
 *         is a far more realistic failure than an agent naming its own address.
 *
 *         TWO TRANSACTIONS, TWO SENDERS, and the split is the lesson:
 *           1. the RELAYER submits the agent's signed `approve` request (the agent is the authority)
 *           2. the RELAYER calls `transferFrom` as itself (the accomplice is the beneficiary)
 */
contract AccompliceDrains is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the over-broad approval");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the accomplice: approved spender, and the one who takes it");

        address accomplice = vm.addr(relayerPk);
        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        bytes32 permissionId = Ledger.word("unpinnedApprovePermissionId", "48_GrantUnpinnedApprove");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 walletBefore = token.balanceOf(wallet);
        uint256 accompliceBefore = token.balanceOf(accomplice);

        DemoLog.header("ACT 4f", "The agent hands the money to an accomplice");
        DemoLog.addrPlain("Throwaway wallet", wallet);
        DemoLog.money("  holds", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.addrPlain("Accomplice", accomplice);
        DemoLog.note("    Not the agent. The agent holds no PC and never will - so it cannot");
        DemoLog.note("    call transferFrom itself. It approves someone who can.");
        DemoLog.blank();

        // 1 · The agent's signed request: approve the accomplice for everything.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            wallet,
            permissionId,
            0, // lane 0 OF THE THROWAWAY WALLET - lanes are per-wallet state
            address(token),
            abi.encodeCall(IERC20.approve, (accomplice, walletBefore)),
            walletBefore
        );

        vm.startBroadcast(relayerPk);
        NativeRequest.submit(req);
        vm.stopBroadcast();

        uint256 allowance = token.allowance(wallet, accomplice);
        DemoLog.ok("approved", "the policy accepted it - no pin, no objection");
        DemoLog.money("  allowance", allowance, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();

        // 2 · The accomplice takes it. NOT an agent request at all — an ordinary ERC-20 call.
        vm.startBroadcast(relayerPk);
        token.transferFrom(wallet, accomplice, allowance);
        vm.stopBroadcast();

        uint256 walletAfter = token.balanceOf(wallet);
        uint256 accompliceAfter = token.balanceOf(accomplice);

        DemoLog.fail("drained", "the money is gone, and no gate fired");
        DemoLog.money("Wallet, before", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Wallet, after", walletAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Accomplice gained", accompliceAfter - accompliceBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The system did exactly what it was told."));
        DemoLog.line(DemoLog.dim("The mandate said the agent may call approve(). It did not say"));
        DemoLog.line(DemoLog.dim("whom it may approve. URP enforced the mandate as written."));
        DemoLog.blank();
        DemoLog.note("Next: the same mandate, with the spender pinned - and the same request refused.");
        DemoLog.footer();

        require(walletAfter == 0, "the drain did not complete - the act proves nothing");
        require(accompliceAfter == accompliceBefore + walletBefore, "the accomplice did not receive the funds");
    }
}
