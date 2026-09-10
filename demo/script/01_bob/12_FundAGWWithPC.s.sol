// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";

/**
 * @title  FundAGWWithPC
 * @notice ACT 1c · Chain: Donut · broadcasts with the relayer key.
 *
 * @dev    THE ONE STEP BOB CANNOT PERFORM FROM ETHEREUM, and the single place the "Bob never
 *         touches Push Chain" story has a seam. Say so out loud during the demo: naming a
 *         limitation costs ten seconds and buys credibility that a question later would cost far
 *         more.
 *
 *         WHY IT EXISTS. The bridge mints pUSDC, not native PC. Every outbound the wallet sends
 *         burns PC for the protocol fee and the gas swap, and the wallet pays that from its OWN
 *         balance — `execute` is payable but the agent door is not, so there is no caller to
 *         supply it. Without PC here, every agent request fails inside the gateway.
 *
 *         WHY NOT FOLD IT INTO THE ARRIVAL. `UEA_EVM._handleMulticall` does forward value, so a
 *         fourth arrival entry `{ to: agw, value: X, data: "" }` would move PC from the UEA into
 *         the wallet's `receive()` and close the seam entirely. It is not done here because the
 *         UEA's PC balance comes from an ETH→PC swap whose rate is not controlled: sizing that
 *         entry means guessing, and a short balance reverts the WHOLE arrival. A deterministic
 *         transfer that cannot fail is worth more than a closed seam. In production the SDK sizes
 *         it; say that too.
 *
 *         IDEMPOTENT. Tops up to the target rather than adding a fixed amount, so a re-run after a
 *         partial rehearsal does not over-fund.
 */
contract FundAGWWithPC is Script {
    error RelayerOutOfPC(uint256 have, uint256 need);

    /// @dev Generous: an outbound costs ~0.001 PC at today's quote, so this covers the demo many
    ///      times over and removes gas from the list of things that can go wrong on stage.
    uint256 internal constant TARGET_PC = 20 ether;

    function run() external {
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer funds the wallet's gas");
        address relayer = vm.addr(relayerPk);
        address agw = Ledger.addr("agw", "10_Arrive");

        DemoLog.header("ACT 1", "The PC seam");
        DemoLog.addr("AGW", agw, true);
        DemoLog.money("Has", agw.balance, 18, "PC");
        DemoLog.money("Target", TARGET_PC, 18, "PC");

        if (agw.balance >= TARGET_PC) {
            DemoLog.blank();
            DemoLog.ok("already funded", "nothing to send");
            DemoLog.footer();
            return;
        }

        uint256 topUp = TARGET_PC - agw.balance;
        if (relayer.balance < topUp) revert RelayerOutOfPC(relayer.balance, topUp);

        vm.startBroadcast(relayerPk);
        (bool sent,) = payable(agw).call{ value: topUp }("");
        vm.stopBroadcast();
        require(sent, "PC transfer failed");

        DemoLog.blank();
        DemoLog.ok("sent", DemoLog.formatAmount(topUp, 18, "PC"));
        DemoLog.money("Balance", agw.balance, 18, "PC");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("This is the one thing Bob cannot do from Ethereum."));
        DemoLog.note("The bridge mints pUSDC, not native PC, and every outbound burns PC for gas.");
        DemoLog.note("In production an SDK, relayer or paymaster sponsors this.");
        DemoLog.footer();
    }
}
