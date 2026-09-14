// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { ICEA } from "../../lib/PushCore.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";

/**
 * @title  AgentRepatriateFails
 * @notice ACT 4b · Chain: Donut · SIMULATION ONLY. Never broadcasts, consumes no nonce.
 *
 * @dev    THE SAME REFUSAL AS G2, RUN AS A NARRATIVE BEAT RATHER THAN A TEST — and this is where it
 *         lands hardest, because now there is real money on the other side of it.
 *
 *         The agent has just earned Bob a reward. It holds a live mandate, an authorised key, and a
 *         perfectly well-formed request. It attempts the single most reasonable-looking thing left:
 *         send the proceeds back to the wallet that owns it.
 *
 *         Gate 14 refuses, because the target is the CEA.
 *
 *         THE NEXT SCRIPT MAKES THE SAME CALL AND SUCCEEDS. Nothing about the call changes — only
 *         who authorises it. That pair is the demo's thesis in two commands:
 *
 *             the agent can earn Bob money; only Bob can take it home.
 *
 *         Run this immediately before Act 4c. Separated, it is a refusal; adjacent, it is the point.
 */
contract AgentRepatriateFails is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address sepoliaUSDC = AddressBook.sepolia("USDC");

        DemoLog.header("ACT 4", "The agent tries to bring it home");
        DemoLog.addrPlain("Holding the funds", cea);
        DemoLog.note("    Principal plus the reward the agent just earned.");
        DemoLog.blank();

        AgentRequest.Built memory req = AgentRequest.single(
            agentPk,
            0,
            cea, // the forbidden target
            abi.encodeCall(ICEA.sendUniversalTxToUEA, (sepoliaUSDC, 0, "", agw))
        );

        Gauntlet.refuse(
            "send the proceeds back to the wallet that owns it",
            IURP.ForbiddenInnerTarget.selector,
            "A live mandate, an authorised key, a well-formed request - and the one target it may never name.",
            req
        );

        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The next command makes this exact call and it succeeds."));
        DemoLog.line(DemoLog.bold("Nothing changes except who authorises it."));
        DemoLog.footer();
    }
}
