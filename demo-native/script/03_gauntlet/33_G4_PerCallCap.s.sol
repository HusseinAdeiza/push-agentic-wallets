// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G4_PerCallCap
 * @notice ACT 3 · G4 · One unit over the per-call ceiling.
 *
 * @dev    26 against a cap of 25 — THE SMALLEST POSSIBLE VIOLATION, deliberately. A request for
 *         1,000 would be refused too, but it invites the thought that the gate only catches the
 *         obvious. One unit over shows the boundary is exact.
 *
 *         Gate N8, the per-call arm. Note the ORDER: N8 checks per-call BEFORE lifetime, which is
 *         why this still fires cleanly even late in the run when the budget is nearly gone.
 */
contract G4_PerCallCap is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the mutated request");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");

        // THE ONE MUTATION: 26 instead of 25.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            agw,
            permissionId,
            0,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.G4_OVER_PER_CALL)),
            Amounts.G4_OVER_PER_CALL
        );

        DemoLog.header("G4", "One unit over the per-action cap");
        DemoLog.money("Cap", Amounts.PER_CALL, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Requested", Amounts.G4_OVER_PER_CALL, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();

        NativeGauntlet.refuseGate(_title(), IURP.NativeAmountExceedsCap.selector, _lesson(), req);

        DemoLog.footer();
    }

    /// @dev Split out for STACK DEPTH only. Inlined alongside the `Built` struct this does not
    ///      compile under via_ir — measured, not guessed.
    function _title() private view returns (string memory) {
        return string.concat(
            "stakeFor(wallet, ",
            DemoLog.formatAmount(Amounts.G4_OVER_PER_CALL, Amounts.DECIMALS, Amounts.SYMBOL),
            ") - one unit over the per-action cap"
        );
    }

    function _lesson() private view returns (string memory) {
        return string.concat(
            "The boundary is exact - not 'about', but exactly ",
            DemoLog.formatAmount(Amounts.PER_CALL, Amounts.DECIMALS, Amounts.SYMBOL),
            "."
        );
    }
}
