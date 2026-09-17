// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DemoUSDC } from "../../contracts/DemoUSDC.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";

/**
 * @title  FundAll
 * @notice SETUP · Chain: Donut · broadcasts with the deployer key. The last setup step.
 *
 * @dev    Mints Bob's dUSDC and fills the reward pool. Both numbers come from `Amounts`, and both
 *         are chosen rather than arbitrary:
 *
 *           · Bob gets 150 — 100 for the wallet (Act 1b), 20 for the throwaway wallet (Act 4f),
 *             and 30 slack so a rehearsal can repeat Act 1 without re-minting.
 *           · The pool gets 50 — `unstake` pays a flat 10 per successful call and the plan has one
 *             per run, so this funds FIVE rehearsals before this script must be run again.
 *
 *         THE POOL MUST BE FUNDED BEFORE ACT 4a. Without it `unstake` reverts inside a token
 *         transfer, which looks exactly like a permission failure and is not — the single most
 *         confusing way this demo can break. `Preflight` asserts the balance for that reason.
 */
contract FundAll is Script {
    function run() external {
        uint256 deployerPk = Keys.load("PRIVATE_KEY", "mints and funds the reward pool");
        address bob = Keys.addressOf("BOB_KEY", "the user, who needs dUSDC to fund his wallet");
        address deployer = vm.addr(deployerPk);

        DemoUSDC token = DemoUSDC(AddressBook.native("DemoUSDC"));
        StakeDummy stake = StakeDummy(AddressBook.native("StakeDummy"));

        uint256 bobBefore = token.balanceOf(bob);
        uint256 poolBefore = token.balanceOf(address(stake));

        vm.startBroadcast(deployerPk);
        token.mint(bob, Amounts.MINT_TO_BOB);
        // Mint to ourselves first: `fundRewards` pulls with `transferFrom`, so the deployer needs
        // both the balance AND an allowance. Minting straight to the pool would skip the contract's
        // own accounting path and its `RewardsFunded` event.
        token.mint(deployer, Amounts.REWARD_POOL);
        IERC20(address(token)).approve(address(stake), Amounts.REWARD_POOL);
        stake.fundRewards(Amounts.REWARD_POOL);
        vm.stopBroadcast();

        // READ BACK FROM THE CHAIN. Nothing here reports success because a call did not revert.
        uint256 bobAfter = token.balanceOf(bob);
        uint256 poolAfter = token.balanceOf(address(stake));

        DemoLog.header("SETUP", "Funding");
        DemoLog.addrPlain("Bob", bob);
        DemoLog.money("  before", bobBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", bobAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.addrPlain("Reward pool", address(stake));
        DemoLog.money("  before", poolBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", poolAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.note(string.concat("      enough for ", vm.toString(poolAfter / Amounts.REWARD), " more unstake(s)"));
        DemoLog.footer();

        require(bobAfter == bobBefore + Amounts.MINT_TO_BOB, "Bob's mint did not land");
        require(poolAfter == poolBefore + Amounts.REWARD_POOL, "the reward pool did not fill");
    }
}
