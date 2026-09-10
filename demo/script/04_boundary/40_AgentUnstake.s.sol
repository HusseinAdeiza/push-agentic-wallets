// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  AgentUnstake
 * @notice ACT 4a · Chain: Donut · broadcasts with the RELAYER key, on a request the AGENT signed.
 *
 * @dev    THE AGENT UNWINDS ITS OWN POSITION, and the interesting part is what it costs: nothing.
 *
 *         A ZERO-AMOUNT REQUEST. The capital is already on Sepolia — there is nothing to bridge, so
 *         `amount` is 0 and this is pure calldata. Three things still hold, and all three surprise
 *         people:
 *
 *           · `token` must STILL be set — gate 5 compares it regardless of amount.
 *           · `maxPCForGas` must STILL be non-zero — gate 9 does not look at amount either.
 *           · `msg.value` must STILL be sent — the gas swap runs, and reverts on a zero swap.
 *
 *         `_burnPRC20` is skipped and URP writes nothing to `spent`. So the agent can unwind
 *         without consuming budget — **the lifetime cap meters what LEAVES Push Chain, not how many
 *         times the agent acts.** That is the design working, not a gap.
 *
 *         `unstake()` TAKES NO ARGUMENTS. The caller is the staker, so there is no beneficiary to
 *         pin and the allow-list entry is trivial. The far-chain calldata is a bare four bytes.
 *
 *         AFTER THE RELAY the CEA holds principal plus the flat reward, and `spent` is unchanged —
 *         both asserted by `just watch-unstaked` and `just state`.
 */
contract AgentUnstake is Script {
    error WalletOutOfPC(uint256 have, uint256 need);
    error NothingStakedYet(address cea);

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "anyone may relay; the relayer holds no authority");

        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        // amount 0 — nothing bridged. The other three fields are still all required.
        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, 0, stakeDummy, abi.encodeWithSelector(StakeDummy.unstake.selector));

        if (agw.balance < req.pcValue) revert WalletOutOfPC(agw.balance, req.pcValue);

        DemoLog.header("ACT 4", "The agent unwinds");
        DemoLog.addrPlain("Agent key", vm.addr(agentPk));
        DemoLog.addrPlain("Relayer", vm.addr(relayerPk));
        DemoLog.blank();
        DemoLog.kv("Request", "unstake() on StakeDummy");
        DemoLog.kv("Bridged", "0.00 USDC  (the capital is already there)");
        DemoLog.kv("Calldata", "4 bytes - unstake takes no arguments");
        DemoLog.money("PC value", req.pcValue, 18, "PC");
        DemoLog.kv("Nonce lane", string.concat("0, sequence ", vm.toString(req.nonceSeq)));
        DemoLog.blank();

        vm.startBroadcast(relayerPk);
        AgentRequest.submit(req);
        vm.stopBroadcast();

        Ledger.setNum("nonceSeq", req.nonceSeq + 1);

        DemoLog.ok("accepted", "all 16 gates, on a zero-amount request");
        DemoLog.ok("metered", "nothing - a zero-amount request writes no spend");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The lifetime cap meters what LEAVES Push Chain,"));
        DemoLog.line(DemoLog.bold("not how many times the agent acts."));
        DemoLog.blank();
        DemoLog.note("Run `just watch-unstaked` - the CEA should end with principal plus the reward.");
        DemoLog.footer();
    }
}
