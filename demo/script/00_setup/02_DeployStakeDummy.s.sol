// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Keys } from "../../lib/Keys.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  DeployStakeDummy
 * @notice Chain: Sepolia · broadcasts with the deployer key. T-1-HOUR SETUP, before Act 1.
 *
 * @dev    ORDERING. This runs before `act1`, never folded into it: `12_ApproveStakeDummyOnCEA`
 *         approves this contract and `13_GrantMandate` allow-lists it, so both need its address.
 *         `10_Arrive` does not, but keeping setup as one block beats a partial ordering nobody
 *         remembers on the day.
 *
 *         THE REWARD POOL IS THE POINT OF THE SECOND HALF. `unstake` pays principal plus a flat
 *         10 USDC that must already be in the contract. Funding it with 100 buys ten unstakes —
 *         rehearsals plus the live run. A demo that dies at Act 4 because rehearsals drained the
 *         pool is the most avoidable failure in this build, which is why preflight asserts the
 *         balance separately rather than trusting that this ran once.
 */
contract DeployStakeDummy is Script {
    error InsufficientUSDC(uint256 have, uint256 need);

    uint256 internal constant POOL = 100e6;

    function run() external {
        uint256 pk = Keys.load("SEPOLIA_STAKE_DEPLOYER_KEY", "deploys and funds StakeDummy");
        address deployer = vm.addr(pk);
        address usdc = AddressBook.sepolia("USDC");

        DemoLog.header("SETUP", "Deploy StakeDummy");
        DemoLog.addr("Deployer", deployer, false);
        DemoLog.addr("USDC", usdc, false);

        uint256 balance = IERC20(usdc).balanceOf(deployer);
        DemoLog.money("Holds", balance, 6, "USDC");
        if (balance < POOL) revert InsufficientUSDC(balance, POOL);

        vm.startBroadcast(pk);

        StakeDummy stake = new StakeDummy(IERC20(usdc));
        IERC20(usdc).approve(address(stake), POOL);
        stake.fundRewards(POOL);

        vm.stopBroadcast();

        DemoLog.blank();
        DemoLog.addr("StakeDummy", address(stake), false);
        DemoLog.money("Reward pool", IERC20(usdc).balanceOf(address(stake)), 6, "USDC");
        DemoLog.money("Per unstake", stake.REWARD(), 6, "USDC");
        DemoLog.ok("funded", "ten unstakes: rehearsals plus the live run");

        Ledger.setAddr("stakeDummy", address(stake));

        // The one write this build makes to the address book, and the second of the documented
        // exceptions to "everything lives under demo/". Written here rather than left to a human
        // step, because every downstream script resolves StakeDummy through AddressBook and would
        // otherwise fail with MissingAddress on a book nobody remembered to edit.
        vm.writeJson(vm.toString(address(stake)), "deployments/address-book/sepolia.json", ".StakeDummy");
        DemoLog.ok("address book", "sepolia.json .StakeDummy updated");

        DemoLog.footer();
    }
}
