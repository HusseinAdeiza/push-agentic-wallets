// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";

/**
 * @title  FundWallet
 * @notice ACT 1b · Chain: Donut · broadcasts with BOB's key.
 *
 * @dev    Bob moves dUSDC into the wallet. A PLAIN ERC-20 TRANSFER — the wallet is an account, and
 *         funding it needs no special path.
 *
 *         THE WALLET'S BALANCE IS THE HARD CEILING ON EVERYTHING THE AGENT CAN LOSE, and that is
 *         the line to say out loud here. It is funded with 100 while the mandate's lifetime budget
 *         is 60, deliberately: the balance is visibly NOT the binding constraint, so when the agent
 *         is refused later it is unmistakably the mandate doing the work, not an empty wallet.
 */
contract FundWallet is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob funds his own wallet");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 before = token.balanceOf(agw);

        vm.startBroadcast(bobPk);
        token.transfer(agw, Amounts.WALLET_FUND);
        vm.stopBroadcast();

        uint256 afterBal = token.balanceOf(agw);

        DemoLog.header("ACT 1b", "Bob funds the wallet");
        DemoLog.addrPlain("Wallet", agw);
        DemoLog.money("  before", before, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", afterBal, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("This balance is the ceiling on everything the agent can lose."));
        DemoLog.note("The mandate will cap it far lower still - at 60, lifetime.");
        DemoLog.footer();

        require(afterBal == before + Amounts.WALLET_FUND, "the transfer did not land");
    }
}
