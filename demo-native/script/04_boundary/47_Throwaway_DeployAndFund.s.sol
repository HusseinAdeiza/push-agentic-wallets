// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGWFactory } from "../../../src/interfaces/IAGWFactory.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";

/**
 * @title  Throwaway_DeployAndFund
 * @notice ACT 4f (1 of 5) · A second wallet, funded with money we intend to lose.
 *
 * @dev    ACT 4f IS THE HONEST ACT. Everything up to here shows the system enforcing a mandate.
 *         This shows where that guarantee ENDS: the contract enforces the mandate AS WRITTEN, and a
 *         badly written mandate authorises bad things. Nothing in URP can tell the difference.
 *
 *         IT IS BOB'S WALLET INDEX 1 — not a new key. The factory assigns sequential indices per
 *         owner, so this is simply Bob's second wallet. That keeps the cast at four addresses and
 *         makes the money visibly Bob's, which is what gives the act its weight.
 *
 *         DELIBERATELY NO APPROVAL HERE. The cross-chain instinct is to approve a spender during
 *         setup; the entire point of 4f is that the AGENT grants the approval, under a mandate that
 *         forgot to pin who the spender may be.
 *
 *         20 dUSDC — enough to be real, small enough to lose without flinching.
 */
contract Throwaway_DeployAndFund is Script {
    error PredictionMismatch(address predicted, address deployed);

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob deploys and funds the throwaway wallet");
        address bob = vm.addr(bobPk);
        IAGWFactory factory = IAGWFactory(AddressBook.ours("factoryProxy"));
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        (address predicted, bool already) = factory.predictWallet(bob, 1);

        address wallet = predicted;
        vm.startBroadcast(bobPk);
        if (!already) wallet = factory.deployWallet("throwaway-4f");
        token.transfer(wallet, Amounts.THROWAWAY_FUND);
        vm.stopBroadcast();

        if (wallet != predicted) revert PredictionMismatch(predicted, wallet);

        Ledger.setAddr("throwawayAgw", wallet);

        DemoLog.header("ACT 4f", "A throwaway wallet - money we intend to lose");
        DemoLog.addrPlain("Wallet", wallet);
        DemoLog.note("    Bob's SECOND wallet, index 1. Same owner, same factory, no new key.");
        DemoLog.money("Funded with", token.balanceOf(wallet), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.kv("Approved spenders", "none - deliberately");
        DemoLog.note("    The agent is about to grant the approval itself, under a mandate");
        DemoLog.note("    that forgot to say WHO may be approved.");
        DemoLog.footer();

        require(token.balanceOf(wallet) >= Amounts.THROWAWAY_FUND, "the throwaway wallet was not funded");
    }
}
