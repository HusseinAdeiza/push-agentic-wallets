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
 * @title  G5_ValueRejected
 * @notice ACT 3 · G5 · A request carrying native PC, against a cap of ZERO.
 *
 * @dev    ONE WEI. The mandate's `maxValuePerCall` is 0, so any non-zero value is refused, and one
 *         wei makes that unmistakable.
 *
 *         WHY THE CAP IS ZERO AND NOT "SOMETHING SAFE". `stakeFor` is not payable and this mandate
 *         never needs to move native PC, so zero is the HONEST ceiling. Setting it to some small
 *         non-zero value "just in case" would make this gauntlet entry contrived — it would prove
 *         only that a made-up limit works. A cap of zero proves the mandate carries no value at
 *         all, which is a property of the grant rather than a number someone picked.
 *
 *         Gate N6. Note that value is checked BEFORE the argument pins (N7) and the amount (N8),
 *         so this request never gets as far as having its beneficiary inspected.
 */
contract G5_ValueRejected is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the mutated request");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");

        // THE ONE MUTATION: one wei of native value on an otherwise perfect request.
        NativeRequest.Built memory req = NativeRequest.buildWithValue(
            agentPk,
            agw,
            permissionId,
            0,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)),
            Amounts.ACT2,
            Amounts.G5_VALUE
        );

        DemoLog.header("G5", "Native value, where none is allowed");
        DemoLog.kv("Cap", "0 wei");
        DemoLog.kv("Requested", "1 wei");
        DemoLog.note("    The mandate authorises no native value at all - not 'a little'.");
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            "a request carrying 1 wei of PC",
            IURP.ValueExceedsCap.selector,
            "A mandate that never needs to move native value should permit none. Zero is a real ceiling, not a placeholder.",
            req
        );
        DemoLog.footer();
    }
}
