// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { OwnerDoor } from "../../lib/OwnerDoor.sol";

/**
 * @title  ApproveStakeDummy
 * @notice ACT 1c · Chain: Donut · broadcasts with BOB's key, through the OWNER DOOR.
 *
 * @dev    THE CLEANEST SINGLE ILLUSTRATION OF THE DESIGN IN THE WHOLE DEMO, and it should be said
 *         out loud while this runs:
 *
 *             The agent can move money INTO the staking contract, but it was never given the power
 *             to grant anyone the right to take money OUT.
 *
 *         `approve` is DELIBERATELY ABSENT from the agent's mandate. If it were present, the agent
 *         could approve an arbitrary spender for an arbitrary amount and drain the wallet without
 *         ever calling `stakeFor` — the allow-list would be decorative. So Bob does it himself,
 *         once, through the door that consults only his ownership.
 *
 *         THE AMOUNT IS EXACTLY THE LIFETIME BUDGET, NEVER `type(uint256).max`. The approval is a
 *         SECOND, INDEPENDENT CEILING: even a wrong URP, or a mandate granted with a mistaken cap,
 *         could not move more than Bob approved. It costs nothing — `unstake` returns funds TO the
 *         wallet and needs no allowance — and it is the one place the demo shows defence in depth
 *         that is the OWNER's rather than the contract's.
 */
contract ApproveStakeDummy is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob approves, through the owner door");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 before = token.allowance(agw, stake);

        vm.startBroadcast(bobPk);
        OwnerDoor.call(agw, address(token), abi.encodeCall(IERC20.approve, (stake, Amounts.APPROVAL)));
        vm.stopBroadcast();

        uint256 afterAllowance = token.allowance(agw, stake);

        DemoLog.header("ACT 1c", "The approval - and what is NOT in the mandate");
        DemoLog.addrPlain("Wallet", agw);
        DemoLog.addrPlain("Spender", stake);
        DemoLog.money("  before", before, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  after", afterAllowance, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.note("      exactly the lifetime budget - never unlimited");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Bob did this himself, through the owner door."));
        DemoLog.line(DemoLog.dim("`approve` is deliberately NOT in the agent's mandate:"));
        DemoLog.line(DemoLog.dim("with it, the agent could approve anyone for anything and"));
        DemoLog.line(DemoLog.dim("drain the wallet without ever calling stakeFor()."));
        DemoLog.blank();
        DemoLog.note("A second, independent ceiling: even a wrong policy could not");
        DemoLog.note("move more than Bob approved.");
        DemoLog.footer();

        require(afterAllowance == Amounts.APPROVAL, "the approval did not land");
    }
}
