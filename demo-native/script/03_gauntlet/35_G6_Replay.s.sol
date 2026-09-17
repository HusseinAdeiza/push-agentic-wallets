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
import { IAgentDoor, NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G6_Replay
 * @notice ACT 3 · G6 · Act 2's exact bytes, submitted a second time.
 *
 * @dev    THE ONE GAUNTLET ENTRY THAT IS NOT RE-SIGNED, and deliberately so: a replay is precisely
 *         a request that WAS valid. Every other entry mutates a field and re-signs, so that it
 *         fails at the gate it claims to demonstrate; here the whole point is that nothing is
 *         changed at all.
 *
 *         REFUSED BY THE WALLET, BEFORE ANY POLICY RUNS. The nonce is consumed and compared in
 *         `executeWithSession` before validation, so a replayed request cannot even burn budget.
 *         It arrives UNWRAPPED — no `PolicyCheckReverted` — which is why this uses `refuseRaw`.
 *
 *         THE EXPECTED SEQUENCE IS READ FROM THE CHAIN, NOT ASSUMED. Running this immediately
 *         after Act 2 gives `InvalidNonce(0, 1, 0)`; running it later gives a different middle
 *         number, and the script prints what it actually found rather than asserting a stale one.
 *         A hardcoded expectation here would turn a re-ordered rehearsal into a confusing failure.
 */
contract G6_Replay is Script {
    bytes4 internal constant INVALID_NONCE = bytes4(keccak256("InvalidNonce(uint192,uint64,uint64)"));

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent's original signature is replayed");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");

        uint64 laneNow = IAgentDoor(agw).getNonce(0);

        // Rebuild Act 2's request, then FORCE the sequence back to 0 and re-sign at that sequence —
        // which reproduces the exact bytes Act 2 submitted. This is a replay of a once-valid
        // request, not a forgery: the signature is genuine and covers sequence 0.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk, agw, permissionId, 0, stake, abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)), Amounts.ACT2
        );
        req.nonceSeq = 0;
        req.signature = NativeRequest.sign(agentPk, req);

        DemoLog.header("G6", "The same request, twice");
        DemoLog.kv("Lane 0 is now at", vm.toString(uint256(laneNow)));
        DemoLog.kv("This request carries", "0");
        DemoLog.note("    A genuine signature over a request that was already accepted.");
        DemoLog.blank();

        NativeGauntlet.refuseRaw(
            "Act 2's exact bytes, resubmitted unchanged",
            INVALID_NONCE,
            "the wallet",
            "The nonce is consumed before validation, so a replayed request cannot even spend budget trying.",
            req
        );
        DemoLog.footer();
    }
}
