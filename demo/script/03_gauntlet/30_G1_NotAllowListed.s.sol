// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Gauntlet } from "../../lib/Gauntlet.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";

/**
 * @title  G1 — a function nobody allow-listed
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Never broadcasts, consumes no nonce.
 *
 * @dev    THE ATTEMPT: the agent calls a selector on `StakeDummy` that the mandate never named.
 *         Same contract, same chain, same asset — only the function differs.
 *
 *         THE POINT: the allow-list is PER-SELECTOR, not per-contract. Naming a contract does not
 *         hand the agent everything on it. Without gate 13 the agent could call any function on any
 *         allow-listed target, including ones added to that contract after the mandate was granted.
 *
 *         RUNS AS A SIMULATION, so it is freely re-runnable during rehearsal and cannot advance the
 *         nonce lane out from under Act 2.
 */
contract G1_NotAllowListed is Script {
    /// @dev A selector that exists on nothing. Deliberately not a real StakeDummy function: the
    ///      claim is about the allow-list, not about what the far chain would have done.
    bytes4 internal constant UNKNOWN_SELECTOR = 0xdeadbeef;

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        DemoLog.header("G1", "A function nobody allow-listed");

        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, 0, stakeDummy, abi.encodeWithSelector(UNKNOWN_SELECTOR));

        Gauntlet.refuse(
            "call an unnamed selector on StakeDummy",
            IURP.CallNotAllowed.selector,
            "Without this, naming a contract would hand the agent every function on it.",
            req
        );

        DemoLog.footer();
    }
}
