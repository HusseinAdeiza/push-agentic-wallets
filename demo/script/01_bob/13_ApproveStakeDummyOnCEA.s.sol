// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Requests } from "../../lib/Requests.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  ApproveStakeDummyOnCEA
 * @notice ACT 1d · Chain: Donut · broadcasts with the relayer key, on a payload BOB signed.
 *
 * @dev    WHAT THIS DOES, AND WHY IT IS AN OWNER ACTION. The CEA must approve `StakeDummy` to pull
 *         USDC on Sepolia. That approval is set once, by Bob, through the owner door — never by the
 *         agent.
 *
 *         WHY `approve` IS DELIBERATELY ABSENT FROM THE AGENT'S ALLOW-LIST. Put this in the runbook
 *         and say it out loud. UCEP's `AllowedCall` pins a target, a selector, and optionally ONE
 *         argument that must equal `expectedCEA`. `USDC.approve(spender, amount)` has a spender
 *         that must equal StakeDummy — not the CEA — so the struct cannot express it. Allow-listing
 *         `approve` would therefore let the agent approve ANY address for ANY amount. That is a
 *         real hole, and demoing it would teach the wrong lesson.
 *
 *         The rule that falls out is architectural, not a workaround: DESTINATION-CHAIN APPROVALS
 *         ARE OWNER ACTIONS. Bob sets the allowance once, unpoliced; the agent's multicall is then
 *         a single entry.
 *
 *         THIS IS ALSO THE FIRST INBOUND SEPOLIA SEES FOR THIS WALLET, so it DEPLOYS THE CEA. The
 *         address was predicted back in `10_Arrive`, before the wallet itself existed; `14_WatchCEA`
 *         asserts the deployed address matches.
 *
 *         ZERO-AMOUNT OUTBOUND. Nothing is bridged — the approval is pure calldata. But `token`
 *         must still be set (gate 5 compares it regardless), `maxPCForGas` must still be non-zero
 *         (gate 9 does not look at amount), and `msg.value` must still be sent
 *         (`_swapAndCollectFees` reverts on a zero swap). Three things that surprise people about
 *         zero-amount requests, all load-bearing here.
 */
contract ApproveStakeDummyOnCEA is Script {
    error QuoteMissing();
    error WalletOutOfPC(uint256 have, uint256 need);

    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");

        uint256 msgValue = Ledger.num("quote.msgValue", "01_Quote");
        if (msgValue == 0) revert QuoteMissing();
        if (agw.balance < msgValue) revert WalletOutOfPC(agw.balance, msgValue);

        DemoLog.header("ACT 1", "The destination-chain approval");
        DemoLog.addrPlain("Bob signs", vm.addr(bobPk));
        DemoLog.addrPlain("Relayer submits", vm.addr(relayerPk));
        DemoLog.addr("CEA (predicted)", Ledger.addr("predictedCEA", "10_Arrive"), false);
        DemoLog.note("    Does not exist yet. This outbound deploys it.");
        DemoLog.blank();

        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, _ownerCall(agw, msgValue), bobPk, VALID_FOR);

        DemoLog.kv("Action", "CEA approves StakeDummy for USDC");
        DemoLog.kv("Bridged", "0.00 USDC  (nothing to move; this is calldata)");
        DemoLog.money("PC value", msgValue, 18, "PC");
        DemoLog.kv("Door", "owner - no policy applies");
        DemoLog.blank();

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        DemoLog.ok("outbound sent", "burned nothing, carried the approval");
        DemoLog.blank();
        DemoLog.note("Sepolia will now deploy the CEA and run the approval.");
        DemoLog.note("Run act1e (watch) to confirm the deployed CEA matches the prediction.");
        DemoLog.footer();
    }

    /**
     * @dev The owner-door call: the wallet sends a zero-amount outbound whose far-chain payload is
     *      one entry — the CEA approving StakeDummy.
     *
     *      Split out of `run` for stack depth. With every address as a local, `run` exceeds the
     *      EVM's 16-slot reach and via_ir refuses to compile it.
     */
    function _ownerCall(address agw, uint256 msgValue) internal view returns (Multicall[] memory) {
        bytes memory outbound = Requests.outbound(
            AddressBook.donut("PRC20_USDC"),
            0, // nothing bridged; token, maxPCForGas and msg.value are still all required
            Ledger.num("quote.maxPCForGas", "01_Quote"),
            agw,
            Requests.singleCall(
                AddressBook.sepolia("USDC"),
                abi.encodeCall(IERC20.approve, (AddressBook.sepolia("StakeDummy"), type(uint256).max))
            )
        );

        return Requests.singleCall(
            agw,
            abi.encodeWithSignature(
                "execute(bytes32,bytes)",
                Requests.singleMode(),
                Requests.execution(AddressBook.donut("UniversalGatewayPC"), msgValue, outbound)
            )
        );
    }
}
