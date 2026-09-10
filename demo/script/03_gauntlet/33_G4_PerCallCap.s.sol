// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { IUCEP } from "../../../src/interfaces/IUCEP.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G4 — over the per-action ceiling
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, consumes no nonce.
 *
 * @dev    THE ATTEMPT: a correctly formed stake, for the right beneficiary, on the right contract —
 *         but for MORE than the mandate allows in one action.
 *
 *         THE POINT: the per-action ceiling is what makes a compromised agent key a bounded loss
 *         rather than a total one. The mandate does not merely say what the agent may do; it says
 *         how much of it, at a time.
 *
 *         The amount is derived from the mandate's own cap rather than hardcoded, so this stays a
 *         genuine over-cap request at any demo scale.
 */
contract G4_PerCallCap is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        // Just over the ceiling: the point is the boundary, not a wild request.
        uint256 tooMuch = Amounts.perCall() + Amounts.perCall() / 5;

        DemoLog.header("G4", "Over the per-action cap");
        DemoLog.money("Mandate allows", Amounts.perCall(), 6, "USDC");
        DemoLog.money("Agent requests", tooMuch, 6, "USDC");
        DemoLog.blank();

        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, tooMuch, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, tooMuch)));

        Gauntlet.refuse(
            "stake more than one action permits",
            IUCEP.AmountExceedsCap.selector,
            "A per-action ceiling turns a compromised agent key into a bounded loss.",
            req
        );

        DemoLog.footer();
    }
}
