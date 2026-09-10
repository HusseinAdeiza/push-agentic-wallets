// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  G3 — the agent stakes for itself
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, consumes no nonce.
 *
 * @dev    THE ATTEMPT: exactly the Act 2 request — same contract, same allow-listed selector, same
 *         amount, well inside every cap — with ONE WORD changed. The beneficiary is the agent's own
 *         address instead of the CEA.
 *
 *         THE POINT, and this is the most product-defining check in the system: the beneficiary is
 *         pinned at GRANT time, one argument deep, at calldata offset 4. Gate 15 reads that word and
 *         compares it to `expectedCEA`.
 *
 *         Without it, every other gate still passes — the target is allow-listed, the selector is
 *         allow-listed, the amount is under both caps — and the agent quietly stakes Bob's capital
 *         into a position only the agent can unwind. Nothing would look wrong until Bob tried to
 *         withdraw.
 *
 *         THIS IS THE ONE TO SHOW IF THERE IS TIME FOR ONLY ONE.
 */
contract G3_BeneficiaryMismatch is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address agent = vm.addr(agentPk);
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        uint256 amount = Amounts.perCall();

        DemoLog.header("G3", "Stake for itself instead of for Bob");
        DemoLog.addrPlain("Agent names", agent);
        DemoLog.note("    ...itself as the beneficiary. Everything else is Act 2, unchanged.");
        DemoLog.blank();

        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (agent, amount)));

        Gauntlet.refuse(
            "stakeFor(agent) instead of stakeFor(cea)",
            IURP.BeneficiaryMismatch.selector,
            "Every other gate passes. Only the pinned beneficiary stops the agent staking Bob's capital for itself.",
            req
        );

        DemoLog.footer();
    }
}
