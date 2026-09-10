// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { BobPayload } from "../../lib/BobPayload.sol";

/**
 * @title  ProbeResult
 * @notice Chain: Donut (read only) · never broadcasts. Run after `04_ForwardingProbe` relays.
 *
 * @dev    READS THE PROBE AND SAYS WHAT IT MEANS. The probe answers one question — does the inbound
 *         pipeline forward an attached payload when `recipient == address(0)`? — and the answer
 *         decides whether Act 1 is one transaction or three.
 *
 *         THE THREE OUTCOMES, and why they are distinguishable:
 *
 *           · UEA has no code            -> the relay has not landed yet. Wait; not a result.
 *           · UEA exists, holds 1 pUSDC  -> deployed and CREDITED, but the payload did not run.
 *                                           Either it was not forwarded, or it was rejected for
 *                                           want of a signature. Act 1 must split.
 *           · UEA exists, holds 1 pUSDC,
 *             and emitted Transfer(0)    -> FORWARDED. The single-transaction arrival is safe.
 *
 *         The middle and last cases share a balance, which is why the probe's entry was chosen to
 *         be observable: a zero-value self-transfer emits a Transfer log and changes nothing else,
 *         so the log is the only thing separating "ran" from "did not run".
 *
 *         This script reports the balance and the mint; the Transfer log is read from the explorer
 *         or `cast logs`, because a script cannot query historical logs on a chain it is not
 *         forking. The printed guidance says exactly what to look for.
 */
contract ProbeResult is Script {
    function run() external view {
        address probe = Keys.addressOf("PROBE_KEY", "the throwaway probe sender");
        address ueaFactory = AddressBook.donut("UEAFactory");
        address prc20 = AddressBook.donut("PRC20_USDC");

        // The probe's UEA is derived from its Sepolia identity, so the source chain id is Sepolia's
        // regardless of which chain this script is reading.
        address probeUEA = BobPayload.predictUEA(ueaFactory, "11155111", probe);

        DemoLog.header("PROBE", "Result");
        DemoLog.addr("Probe sender", probe, false);
        DemoLog.addr("Probe UEA", probeUEA, true);

        uint256 code;
        assembly {
            code := extcodesize(probeUEA)
        }

        if (code == 0) {
            DemoLog.blank();
            DemoLog.note("The UEA has no code yet. The relay has not landed - this is not a result.");
            DemoLog.note("Wait and re-run.");
            DemoLog.footer();
            return;
        }

        DemoLog.ok("UEA deployed", "the pipeline created it");

        uint256 balance = IERC20(prc20).balanceOf(probeUEA);
        DemoLog.money("pUSDC", balance, 6, "USDC");

        if (balance > 0) {
            DemoLog.ok("minted", "pTokens credited before the payload would run");
        }

        DemoLog.blank();
        DemoLog.note("Now check whether the multicall entry actually executed.");
        DemoLog.note("Look for a Transfer(probeUEA -> probeUEA, 0) on the PRC20:");
        DemoLog.blank();
        DemoLog.line("  cast logs --from-block <probe block> \\");
        DemoLog.line(string.concat("    --address ", vm.toString(prc20), " \\"));
        DemoLog.line("    'Transfer(address,address,uint256)' \\");
        DemoLog.line(string.concat("    ", vm.toString(bytes32(uint256(uint160(probeUEA))))));
        DemoLog.blank();
        DemoLog.note("Found     -> payload FORWARDED. The single-transaction arrival is safe.");
        DemoLog.note("Not found -> NOT forwarded. Act 1 splits into three signed payloads,");
        DemoLog.note("             and 10_Arrive must be rebuilt before anything downstream.");
        DemoLog.footer();
    }
}
