// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { ICEA } from "../../lib/PushCore.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";

/**
 * @title  G2 — the agent reaches for the account that holds everything
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, consumes no nonce.
 *
 * @dev    THE ATTEMPT: the agent targets the CEA itself and calls `sendUniversalTxToUEA` — the
 *         function that moves the CEA's entire balance back to Push Chain. On the far side that
 *         call is legitimate; it is exactly what Bob uses in Act 4c.
 *
 *         THE POINT, AND IT IS THE SHARPEST ONE IN THE ACT: gate 14 forbids the agent from ever
 *         naming the CEA as an inner target. The CEA is the account that holds the working capital,
 *         so an agent able to call it could move everything, in one legitimate-looking call, to an
 *         address of its choosing.
 *
 *         The same call, made by the OWNER, succeeds — see Act 4c. That contrast is the demo's
 *         thesis in two commands: the agent can earn Bob money; only Bob can take it home.
 */
contract G2_ForbiddenCEA is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");

        DemoLog.header("G2", "Send the funds somewhere the agent chooses");

        AgentRequest.Built memory req = AgentRequest.single(
            agentPk,
            0,
            cea, // the forbidden target
            abi.encodeCall(ICEA.sendUniversalTxToUEA, (address(0), 0, "", agw))
        );

        Gauntlet.refuse(
            "call sendUniversalTxToUEA on its own CEA",
            IURP.ForbiddenInnerTarget.selector,
            "The CEA holds the working capital. This call is legitimate for the OWNER (Act 4c) and never for the agent.",
            req
        );

        DemoLog.footer();
    }
}
