// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { BobPayload, UniversalPayload } from "../../lib/BobPayload.sol";
import { ISepoliaGateway } from "../../lib/PushCore.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  ForwardingProbe
 * @notice Chain: Sepolia · broadcasts with a THROWAWAY key. Run once, before Act 1 is trusted.
 *
 * @dev    THE ONE MECHANISM NEITHER SOURCE NOR SPEC COULD SETTLE: does Push's inbound pipeline
 *         forward an attached payload when `recipient == address(0)`? The entire single-transaction
 *         arrival rests on it. If it does not hold, Act 1 has to split into three separately signed
 *         payloads and everything downstream shifts.
 *
 *         Learning that here costs 1 USDC and five minutes. Learning it during `10_Arrive` costs a
 *         rebuild; learning it on stage costs the demo.
 *
 *         WHY A THROWAWAY KEY, NOT BOB'S. The probe consumes its sender's UEA nonce 0 — the exact
 *         nonce the real arrival payload signs. Probing as Bob would silently invalidate the thing
 *         the probe exists to de-risk.
 *
 *         WHAT THE PAYLOAD DOES: a single-entry multicall calling `transfer(self, 0)` on the pUSDC
 *         PRC20. Harmless, moves nothing, and observable — if the entry ran, the probe's UEA emitted
 *         a Transfer of 0. Deliberately NOT a call that could fail for its own reasons, so a
 *         negative result means "not forwarded" rather than "forwarded but reverted".
 *
 *         READING THE RESULT: after the relay, check whether the probe's UEA exists on Donut and
 *         whether it emitted the Transfer. `05_ProbeResult` does the checking; this only sends.
 */
contract ForwardingProbe is Script {
    error InsufficientUSDC(uint256 have, uint256 need);
    error MissingProbeKey();

    /// @dev One dollar. Enough to carry a payload; small enough not to matter if it is stranded.
    uint256 internal constant PROBE_AMOUNT = 1e6;

    /**
     * @dev NATIVE VALUE, AND WHAT IT DID AND DID NOT SETTLE.
     *
     *      The gateway's FUNDS_AND_PAYLOAD branch splits on `nativeValue`:
     *        · `nativeValue == 0`  — Case 2.1, which ASSUMES the UEA already holds PC for gas. A
     *          brand-new UEA holds none.
     *        · `nativeValue > 0`   — Case 2.3, which sends a gas leg to the UEA via the instant
     *          route first, then runs the funds-and-payload leg.
     *
     *      Both were run. With value, the gas leg demonstrably worked — the fresh UEA received
     *      ~4.996 PC — and the payload STILL did not execute (`nonce()` stayed 0, relay tx carried
     *      only a mint and a Deposit). So missing gas was not the explanation.
     *
     *      If this probe is run again, read the bounds from `getMinMaxValueForNative()` rather than
     *      hardcoding: the window is narrow (~0.000398 to ~0.00398 ETH on Sepolia today) and a
     *      figure outside it is rejected.
     */

    /// @dev Where the owner lives, as Push core keys identities. Not where a script runs.
    string internal constant SOURCE_CHAIN_ID = "11155111";

    function run() external {
        uint256 probePk = Keys.load("PROBE_KEY", "the throwaway sender for the forwarding probe");
        address probe = vm.addr(probePk);

        address gateway = AddressBook.sepolia("UniversalGateway");
        address usdc = AddressBook.sepolia("USDC");
        address prc20 = AddressBook.donut("PRC20_USDC");
        address ueaFactory = AddressBook.donut("UEAFactory");

        DemoLog.header("PROBE", "Does the inbound pipeline forward a payload?");
        DemoLog.addr("Probe sender", probe, false);
        DemoLog.note("A throwaway key. Never Bob - a probe consumes UEA nonce 0.");
        DemoLog.blank();

        // The probe's own UEA, predicted the same way Bob's is.
        //
        // CROSS-CHAIN READ. `UEAFactory` lives on DONUT and this script broadcasts on SEPOLIA, so
        // the prediction has to happen against a Donut fork — calling it on the active chain hits
        // an address with no code. Every script that predicts a UEA while acting on Sepolia has
        // the same shape, and `10_Arrive` will need it too.
        //
        // The chain id passed is Sepolia's because it identifies where the OWNER lives, not where
        // the factory runs.
        uint256 sepoliaFork = vm.activeFork();
        vm.createSelectFork(vm.envString("PUSH_DONUT_RPC_URL"));
        address probeUEA = BobPayload.predictUEA(ueaFactory, SOURCE_CHAIN_ID, probe);
        vm.selectFork(sepoliaFork);
        DemoLog.addr("Probe UEA", probeUEA, true);
        DemoLog.note("Does not exist yet. The pipeline deploys it, mints, then runs the payload.");
        DemoLog.blank();

        uint256 balance = IERC20(usdc).balanceOf(probe);
        DemoLog.money("Probe USDC", balance, 6, "USDC");
        if (balance < PROBE_AMOUNT) revert InsufficientUSDC(balance, PROBE_AMOUNT);

        // One harmless, observable entry: a zero-value self-transfer of the minted pUSDC.
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({
            to: prc20, value: 0, data: abi.encodeWithSignature("transfer(address,uint256)", probeUEA, uint256(0))
        });

        // Nonce 0: a fresh UEA. Signed even though the executor-module path may skip verification —
        // if the pipeline forwards the signature it works, and if it ignores it nothing is lost.
        UniversalPayload memory payload = BobPayload.multicallPayload(calls, 0, block.timestamp + 2 hours);

        DemoLog.kv("Payload", "1 entry: pUSDC.transfer(probeUEA, 0)");
        DemoLog.kv("Amount", DemoLog.formatAmount(PROBE_AMOUNT, 6, "USDC"));

        vm.startBroadcast(probePk);
        IERC20(usdc).approve(gateway, PROBE_AMOUNT);
        ISepoliaGateway(gateway)
            .sendUniversalTx(
                ISepoliaGateway.UniversalTxRequest({
                    recipient: address(0), // credit the sender's UEA — the case under test
                    token: usdc,
                    amount: PROBE_AMOUNT,
                    payload: abi.encode(payload),
                    revertRecipient: probe,
                    // DELIBERATELY EMPTY, AND THIS IS PART OF WHAT THE PROBE MEASURES.
                    //
                    // Part 3.4 says to sign the payload so the demo is immune to which path the
                    // pipeline takes. That is right for the real arrival. But the digest can only be
                    // asked for from a DEPLOYED UEA, and a fresh sender has none — so signing here
                    // would mean reimplementing Push core's EIP-712 typehashes locally against a
                    // predicted address, which is exactly the kind of hand-derived encoding Part 0.5
                    // forbids and which could itself be the reason a probe failed.
                    //
                    // Empty keeps the probe honest: it isolates ONE question. If the payload executes
                    // with no signature, the pipeline used the executor-module path that skips
                    // verification, and the real arrival can sign as a belt-and-braces measure. If it
                    // does not execute, `05_ProbeResult` distinguishes "not forwarded" from "forwarded
                    // but rejected for want of a signature" by whether the UEA was deployed and
                    // credited at all.
                    signatureData: ""
                })
            );
        vm.stopBroadcast();

        DemoLog.blank();
        DemoLog.ok("sent", "watch Donut for the probe UEA to appear");
        DemoLog.note("Then check whether the multicall entry ran:");
        DemoLog.note("  UEA exists + pUSDC balance 1.00  -> minted, payload NOT forwarded");
        DemoLog.note("  UEA exists + Transfer(0) emitted -> payload FORWARDED, Act 1 is safe");
        DemoLog.footer();
    }
}
