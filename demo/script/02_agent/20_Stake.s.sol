// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { AgentRequest } from "../../lib/AgentRequest.sol";
import { AgentSigning } from "../../lib/AgentSigning.sol";
import { IPushAgentWallet } from "../../../src/interfaces/IPushAgentWallet.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/**
 * @title  Stake
 * @notice ACT 2 · Chain: Donut · broadcasts with the RELAYER key, on a request the AGENT signed.
 *         THE DEMO'S CENTRAL BEAT.
 *
 * @dev    "A key that holds nothing just moved real money across a chain boundary and put it to
 *         work." This is the first time the whole stack runs: the agent's signature, the wallet's
 *         expiry/nonce/validator checks, URP's sixteen gates, the gateway's burn, and the relay.
 *
 *         THE AGENT KEY HOLDS NOTHING AND OWNS NOTHING. It cannot be topped up, cannot receive
 *         funds, and has no authority beyond this mandate. The PC that pays for the swap comes from
 *         the WALLET's balance — the request itself is not payable.
 *
 *         THE RELAYER IS NOT THE AUTHORITY. `executeWithSession` is permissionless: the signature,
 *         the nonce and the bound op-hash are the authority, never the caller. Relaying from an
 *         address with no role in the system is the point, not an implementation detail.
 *
 *         WHAT THE ASSERTION HAS TO BE. Not "the transaction succeeded" — that only proves Push
 *         accepted it. The claim is "the money is staked", which lives on the far chain, so the
 *         proof is `StakeDummy.totalBalance(cea)` and `just watch-staked` is what confirms it.
 *
 *         THE OP-HASH EQUIVALENCE IS ASSERTED HERE. The wallet emits the hash it computed; this
 *         script recomputes it with `AgentSigning` and compares. That is the live proof the lifted
 *         helper matches the deployed bytecode — the unit tests can only compare it against another
 *         copy of the same arithmetic.
 */
contract Stake is Script {
    error WalletOutOfPC(uint256 have, uint256 need);
    error NotEnoughToStake(uint256 have, uint256 need);
    error OpHashMismatch(bytes32 expected, bytes32 emitted);
    error NoAuthorizationEvent();

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs its own requests");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "anyone may relay; the relayer holds no authority");

        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        address prc20 = AddressBook.donut("PRC20_USDC");

        uint256 amount = Amounts.perCall();

        // The far-chain entry. `beneficiary` is the CEA — gate 15 asserts it, so the agent can only
        // ever stake for Bob's own account and never for itself.
        AgentRequest.Built memory req =
            AgentRequest.single(agentPk, amount, stakeDummy, abi.encodeCall(StakeDummy.stakeFor, (cea, amount)));

        _preconditions(agw, prc20, req, amount);
        _printRequest(agentPk, relayerPk, cea, amount, req);

        // Recomputed independently, then compared against what the wallet emits.
        bytes32 expectedOpHash = AgentSigning.opHash(
            block.chainid,
            agw,
            req.engine,
            Ledger.word("permissionId", "14_GrantMandate"),
            req.mode,
            req.executionCalldata,
            AgentRequest.NONCE_KEY,
            req.nonceSeq,
            req.requestExpiry
        );

        vm.recordLogs();
        vm.startBroadcast(relayerPk);
        AgentRequest.submit(req);
        vm.stopBroadcast();

        _assertOpHash(expectedOpHash);

        Ledger.setNum("nonceSeq", req.nonceSeq + 1);

        _report(agw, prc20, amount);
    }

    /// @dev Fail before broadcasting, with a message naming the fix, rather than reverting deep
    ///      inside the gateway where the reason is a Uniswap error string.
    function _preconditions(address agw, address prc20, AgentRequest.Built memory req, uint256 amount) internal view {
        if (agw.balance < req.pcValue) revert WalletOutOfPC(agw.balance, req.pcValue);

        uint256 held = IERC20(prc20).balanceOf(agw);
        if (held < amount) revert NotEnoughToStake(held, amount);
    }

    function _printRequest(
        uint256 agentPk,
        uint256 relayerPk,
        address cea,
        uint256 amount,
        AgentRequest.Built memory req
    ) internal view {
        DemoLog.header("ACT 2", "The agent works");
        DemoLog.addrPlain("Agent key", vm.addr(agentPk));
        DemoLog.note("    Holds no funds. Owns nothing. Cannot be topped up.");
        DemoLog.addrPlain("Relayer", vm.addr(relayerPk));
        DemoLog.note("    No role in the system. Anyone could submit this.");
        DemoLog.blank();

        DemoLog.kv(
            "Request", string.concat("stake ", DemoLog.formatAmount(amount, 6, "USDC"), " for the CEA on Sepolia")
        );
        DemoLog.addrPlain("Beneficiary", cea);
        DemoLog.note("    Pinned at grant time. Gate 15 refuses any other.");
        DemoLog.kv("Nonce lane", string.concat("0, sequence ", vm.toString(req.nonceSeq)));
        DemoLog.kv("Expiry", "in 30 minutes");
        DemoLog.money("PC value", req.pcValue, 18, "PC");
        DemoLog.note("    From the WALLET's balance. The agent request is not payable.");
        DemoLog.blank();
    }

    /**
     * @dev The live equivalence proof for `AgentSigning`. The wallet emits the op hash it computed;
     *      if our transcription of the ten fields had drifted, the signature would already have
     *      failed — but comparing the hashes says so explicitly rather than leaving it implied.
     */
    function _assertOpHash(bytes32 expected) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IPushAgentWallet.MandateActionAuthorized.selector;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == topic) {
                // TWO non-indexed fields, in declaration order: `nonceSeq` then `opHash`.
                // `permissionId` and `nonceKey` are indexed and live in topics, not data.
                // Decoding a single bytes32 here would read `nonceSeq` and never match.
                (, bytes32 emitted) = abi.decode(logs[i].data, (uint64, bytes32));
                if (emitted != expected) revert OpHashMismatch(expected, emitted);

                DemoLog.ok("wallet", "expiry, nonce, validator, signature");
                DemoLog.ok("URP", "all 16 gates");
                DemoLog.ok("op hash", "matches the hash we signed, byte for byte");
                return;
            }
        }
        revert NoAuthorizationEvent();
    }

    function _report(address agw, address prc20, uint256 amount) internal view {
        DemoLog.ok("gateway", string.concat("burned ", DemoLog.formatAmount(amount, 6, "pUSDC"), ", outbound emitted"));
        DemoLog.blank();
        DemoLog.money("Wallet now holds", IERC20(prc20).balanceOf(agw), 6, "pUSDC");
        DemoLog.money("Wallet PC", agw.balance, 18, "PC");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Bob signed nothing. The agent holds nothing."));
        DemoLog.note("Now run `just watch-staked` - the claim is not that the transaction");
        DemoLog.note("succeeded, but that the money is STAKED on the far chain.");
        DemoLog.footer();
    }
}
