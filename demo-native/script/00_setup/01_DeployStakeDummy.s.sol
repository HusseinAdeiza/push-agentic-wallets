// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";

/**
 * @title  DeployStakeDummy
 * @notice SETUP · Chain: Donut · broadcasts with the deployer key. Run after `00_DeployDemoUSDC`.
 *
 * @dev    The counterparty. Its source is COPIED BYTE-FOR-BYTE from `demo/contracts/StakeDummy.sol`
 *         — the cross-chain demo's target — and its shape is already exactly right for this demo:
 *         `stakeFor(address beneficiary, uint256 amount)` puts the beneficiary in the FIRST
 *         argument word, at calldata offset 4, which is precisely what an `ArgPin` pins.
 *
 *         `token` IS IMMUTABLE AND HAS NO SETTER. Deploying this before the address book names the
 *         right `DemoUSDC` produces a StakeDummy wired to the wrong token, permanently. That is why
 *         it reads the address book rather than taking an argument: the never-zero rule fails loudly
 *         here instead of silently later.
 */
contract DeployStakeDummy is Script {
    function run() external {
        uint256 deployerPk = Keys.load("PRIVATE_KEY", "deploys the staking contract");
        address token = AddressBook.native("DemoUSDC");

        vm.startBroadcast(deployerPk);
        StakeDummy stake = new StakeDummy(IERC20(token));
        vm.stopBroadcast();

        DemoLog.header("SETUP", "The counterparty");
        DemoLog.addrPlain("StakeDummy", address(stake));
        DemoLog.addrPlain("  staking", address(stake.token()));
        DemoLog.blank();
        DemoLog.note("A DEMO contract: no owner, no pause, no supply accounting.");
        DemoLog.note("It would be drained within a block on a live network.");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("NEXT: paste this address into"));
        DemoLog.line("  deployments/address-book-v2/native_demo.json  ->  .StakeDummy");
        DemoLog.footer();

        // The wiring is the one thing that cannot be fixed afterwards. Read it back.
        require(address(stake.token()) == token, "StakeDummy wired to the wrong token");
    }
}
