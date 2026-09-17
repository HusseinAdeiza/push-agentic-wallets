// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  BankedRequestDies
 * @notice ACT 4e · THE CLOSING BEAT. A perfectly valid request, signed after revocation.
 *
 * @dev    THE ONLY REFUSAL IN EITHER DEMO THAT NAMES REVOCATION RATHER THAN A LIMIT.
 *
 *         Every other refusal in this demo says "you asked for too much" or "you asked for the
 *         wrong thing". This one says: the permission does not exist any more. The request is
 *         flawless — correct contract, correct function, correct beneficiary, within every cap,
 *         freshly signed, correct nonce. It dies because Act 4d happened.
 *
 *         IT ANSWERS THE QUESTION AN AUDIENCE ACTUALLY HAS: "what about a request the agent already
 *         signed and is holding?" A banked signature is worthless the moment the mandate is
 *         revoked, because the permission id is FIELD 5 of the ten-field op hash — the signature is
 *         bound to a permission that the engine no longer knows.
 *
 *         Refused by the ENGINE, unwrapped: `InvalidPermissionId`.
 */
contract BankedRequestDies is Script {
    bytes4 internal constant INVALID_PERMISSION_ID = bytes4(keccak256("InvalidPermissionId(bytes32)"));

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs a request against a dead mandate");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");

        // A FLAWLESS REQUEST. Nothing is mutated: right contract, right function, right
        // beneficiary, a small amount well within every cap, and a fresh valid signature.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            agw,
            permissionId,
            0,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.G7_OVER_TOTAL)),
            Amounts.G7_OVER_TOTAL
        );

        DemoLog.header("ACT 4e", "The banked request");
        DemoLog.line(DemoLog.bold("Nothing is wrong with this request."));
        DemoLog.addrPlain("  target", stake);
        DemoLog.addrPlain("  beneficiary", agw);
        DemoLog.money("  amount", Amounts.G7_OVER_TOTAL, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("  signature", "fresh, valid, correctly signed");
        DemoLog.note("    Right contract, right function, right beneficiary, within every cap.");
        DemoLog.blank();

        NativeGauntlet.refuseRaw(
            "a flawless request, against a mandate revoked one act ago",
            INVALID_PERMISSION_ID,
            "the engine",
            "The permission id is field 5 of the op hash. Revoke the mandate and every signature ever made against it dies with it - including ones already written.",
            req
        );
        DemoLog.footer();
    }
}
