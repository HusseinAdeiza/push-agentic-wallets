// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  AgentUnstake
 * @notice ACT 4a · Chain: Donut · the agent withdraws — TO THE WALLET, never to itself.
 *
 * @dev    THE POSITIVE HALF OF THE BOUNDARY. The agent is allowed to do this, and it does it, and
 *         the money lands in Bob's wallet. An agent that can only be refused is not a useful agent;
 *         the point of the system is that it can act, within limits.
 *
 *         WHERE THE MONEY GOES IS NOT A POLICY DECISION HERE — IT IS ARITHMETIC. `unstake()` pays
 *         `totalBalance[msg.sender]` to `msg.sender`, and `msg.sender` is the wallet, because the
 *         wallet is what dispatches the call. The agent never holds it, even for an instant.
 *
 *         That is also precisely why G3 mattered: had the agent staked to ITSELF, this same
 *         function would have paid the agent instead — from its own EOA, under no mandate at all.
 *
 *         Lane 1, the unstake mandate's own lane.
 */
contract AgentUnstake is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the withdrawal");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits it");

        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("unstakePermissionId", "40_GrantUnstake");
        address stake = AddressBook.native("StakeDummy");

        StakeDummy staking = StakeDummy(stake);
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 stakedBefore = staking.totalBalance(agw);
        uint256 walletBefore = token.balanceOf(agw);
        uint256 agentBefore = token.balanceOf(vm.addr(agentPk));

        NativeRequest.Built memory req =
            NativeRequest.build(agentPk, agw, permissionId, 1, stake, abi.encodeCall(StakeDummy.unstake, ()), 0);

        DemoLog.header("ACT 4a", "The agent withdraws");
        DemoLog.money("Staked", stakedBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Reward due", Amounts.REWARD, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("Lane / seq", string.concat("1 / ", vm.toString(uint256(req.nonceSeq))));
        DemoLog.blank();

        vm.startBroadcast(relayerPk);
        NativeRequest.submit(req);
        vm.stopBroadcast();

        uint256 stakedAfter = staking.totalBalance(agw);
        uint256 walletAfter = token.balanceOf(agw);
        uint256 agentAfter = token.balanceOf(vm.addr(agentPk));

        DemoLog.ok("withdrawn", "principal and reward, both to the WALLET");
        DemoLog.blank();
        DemoLog.header("", "Where the money went");
        DemoLog.money("Wallet, before", walletBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Wallet, after", walletAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Staked, now", stakedAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.money("Agent's balance", agentAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.note("    Unchanged, and zero. The agent never holds the money - not even briefly.");
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("unstake() pays msg.sender, and msg.sender is the wallet."));
        DemoLog.line(DemoLog.dim("Had G3 succeeded, this same function would have paid the agent."));
        DemoLog.footer();

        require(stakedAfter == 0, "the stake was not fully withdrawn");
        require(walletAfter == walletBefore + stakedBefore + Amounts.REWARD, "principal + reward did not land");
        require(agentAfter == agentBefore, "the agent's balance moved - it must never hold funds");
    }
}
