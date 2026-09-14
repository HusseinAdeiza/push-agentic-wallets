// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { PushWalletErrors } from "../../../src/libraries/PushWalletErrors.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/// @dev The wallet's nonce view.
interface IWalletNonce {
    function getNonce(uint192 nonceKey) external view returns (uint64);
}

/**
 * @title  G6 — the replay
 * @notice ACT 3 · Chain: Donut · SIMULATION ONLY. Optional sixth beat; Zaryab decides on the day.
 *
 * @dev    THE ATTEMPT: re-submit Act 2's request. Same bytes, same signature — a signature that was
 *         valid, from a key that is still authorised, against a mandate that is still live.
 *
 *         THE POINT: the most intuitively obvious protection to a non-specialist audience, and
 *         thirty seconds to show. If a signed request could be replayed, capturing one from a log
 *         would be as good as holding the key.
 *
 *         IT IS REFUSED DIFFERENTLY FROM G1-G5, AND THAT IS WORTH SAYING. The other five die inside
 *         URP, so the engine wraps them as `PolicyCheckReverted`. This one never reaches a policy
 *         at all: the WALLET rejects it at the nonce check, before the signature is even recovered.
 *         Cheapest possible refusal, earliest possible point.
 *
 *         The nonce is one of the ten signed fields, so a replayer cannot simply increment it — the
 *         signature would no longer verify. Replay protection and signature binding are the same
 *         mechanism seen from two sides.
 */
contract G6_Replay is Script {
    error ExpectedRefusalButSucceeded();
    error WrongRefusal(bytes4 expected, bytes4 actual);
    error NothingToReplay();

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");

        uint256 amount = Amounts.perCall();
        uint64 consumed = IWalletNonce(agw).getNonce(0);

        DemoLog.header("G6", "Replay a request that already succeeded");

        if (consumed == 0) revert NothingToReplay();

        // Rebuild Act 2's request at the sequence it USED — the ledger has already moved on.
        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, amount)));
        req.nonceSeq = consumed - 1;
        req.signature = AgentRequest.sign(agentPk, req);

        DemoLog.kv("Attempt", "re-submit the exact request Act 2 already used");
        DemoLog.kv("Sequence", string.concat(vm.toString(req.nonceSeq), " - already consumed"));
        DemoLog.kv("Wallet expects", vm.toString(consumed));
        DemoLog.blank();

        (bool ok, bytes memory ret) = agw.call(AgentRequest.encodeSubmit(req));
        if (ok) revert ExpectedRefusalButSucceeded();

        bytes4 sel = bytes4(ret);
        if (sel != PushWalletErrors.InvalidNonce.selector) {
            revert WrongRefusal(PushWalletErrors.InvalidNonce.selector, sel);
        }

        (uint192 key, uint64 expected, uint64 provided) = abi.decode(_body(ret), (uint192, uint64, uint64));

        DemoLog.ok("refused", "by the WALLET, before any policy ran");
        DemoLog.refused("InvalidNonce", "the sequence was already spent");
        DemoLog.kv("  lane", vm.toString(key));
        DemoLog.kv("  expected", vm.toString(expected));
        DemoLog.kv("  provided", vm.toString(provided));
        DemoLog.blank();
        DemoLog.note("A valid signature, a live mandate, an authorised key - and still refused.");
        DemoLog.note("The nonce is one of the ten SIGNED fields, so it cannot simply be incremented:");
        DemoLog.note("changing it invalidates the signature that made the request authentic.");
        DemoLog.footer();
    }

    function _body(bytes memory ret) private pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ret[4 + i];
        }
    }
}
