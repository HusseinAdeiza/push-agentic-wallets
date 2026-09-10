// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { IUniversalCore } from "../../lib/PushCore.sol";
import { GasSwap } from "../../lib/GasSwap.sol";

/**
 * @title  Quote
 * @notice Chain: Donut (read only) · never broadcasts.
 *         Run before Act 1, AND AGAIN immediately before Act 2.
 *
 * @dev    THE PC VALUE ARITHMETIC — the single most likely thing to fail on a first live attempt.
 *         Four constraints must hold at once, three from the gateway and one from the mandate:
 *
 *           1. `msg.value >= protocolFee`                       — gateway
 *           2. `maxPCForGas <= msg.value - protocolFee`         — gateway
 *           3. `msg.value - protocolFee > 0` after capping      — `_swapAndCollectFees`
 *           4. `msg.value <= cfg.maxPCPerCall`                  — URP gate 8
 *
 *         Constraint 4 is the one that bites late: `maxPCPerCall` is frozen into the mandate at
 *         grant time and cannot be raised without revoking and regranting. So this script does not
 *         merely quote — when a mandate already exists it COMPARES the fresh recommendation against
 *         the cap that was granted, and says so loudly while there is still time to act. That turns
 *         a mid-demo gate-8 rejection into a pre-demo warning.
 *
 *         `protocolFee` IS READ, NEVER ASSUMED. It is currently 0 on Donut. That makes constraint 3
 *         the only thing preventing a zero-value swap, and it is a live parameter Push core can
 *         switch on between a rehearsal and the demo.
 */
contract Quote is Script {
    error UnregisteredToken(address prc20);
    error ZeroFees();

    /// @dev Headroom baked into the mandate's PC cap, so fee movement between rehearsal and demo
    ///      day cannot force a regrant.
    uint256 internal constant CAP_MULTIPLE = 3;

    function run() external {
        address prc20 = AddressBook.donut("PRC20_USDC");
        address core = AddressBook.donut("UniversalCore");

        (address gasToken, uint256 gasFee, uint256 protocolFee, uint256 gasPrice,, uint256 gasLimitUsed) =
            IUniversalCore(core).getOutboundTxGasAndFees(prc20, 0);

        // The same conditions the gateway itself rejects, checked here where the message is legible.
        if (gasToken == address(0)) revert UnregisteredToken(prc20);
        if (gasFee + protocolFee == 0) revert ZeroFees();

        // THE PRICE, FROM THE POOL. `gasFee` is in GAS-TOKEN units, not PC — see GasSwap.
        uint256 spot = GasSwap.spotCost(gasToken, gasFee);
        uint256 maxPCForGas = GasSwap.budget(gasToken, gasFee);
        uint256 msgValue = protocolFee + maxPCForGas;
        uint256 maxPCPerCall = msgValue * CAP_MULTIPLE;

        DemoLog.header("SETUP", "Quote");
        DemoLog.kv("gasFee", string.concat(DemoLog.formatAmount(gasFee, 18, "gasToken"), "  <- NOT PC"));
        DemoLog.kv("protocolFee", DemoLog.formatAmount(protocolFee, 18, "PC"));
        DemoLog.kv("gasPrice", vm.toString(gasPrice));
        DemoLog.kv("gasLimit", vm.toString(gasLimitUsed));
        DemoLog.blank();

        // The arithmetic is shown, not just its result, so a mismatch is diagnosable on screen.
        // BOTH DENOMINATIONS ARE PRINTED, every run: the unit distinction between gasFee and
        // protocolFee is the trap that cost a full debugging session, and it is invisible unless
        // stated.
        DemoLog.note("gasFee is in GAS-TOKEN units; protocolFee is in PC. Different currencies.");
        DemoLog.note(string.concat("swap cost   = ", DemoLog.formatAmount(spot, 18, "PC"), " at pool spot"));
        DemoLog.note(string.concat("maxPCForGas = ", vm.toString(GasSwap.HEADROOM_MULTIPLE), " x spot"));
        DemoLog.note("msgValue    = protocolFee + maxPCForGas");
        DemoLog.note(string.concat("maxPCPerCall= ", vm.toString(CAP_MULTIPLE), " x msgValue"));
        DemoLog.blank();

        DemoLog.money("msgValue", msgValue, 18, "PC");
        DemoLog.money("maxPCForGas", maxPCForGas, 18, "PC");
        DemoLog.money("maxPCPerCall", maxPCPerCall, 18, "PC");

        if (protocolFee == 0) {
            DemoLog.blank();
            DemoLog.note("protocolFee is 0, so msgValue is the gas-swap budget alone.");
            DemoLog.note("Constraint 3 is then the only guard against a zero-value swap.");
        }

        _warnIfMandateCapTooLow(msgValue);

        Ledger.setNum("quote.msgValue", msgValue);
        Ledger.setNum("quote.maxPCForGas", maxPCForGas);
        Ledger.setNum("quote.maxPCPerCall", maxPCPerCall);

        DemoLog.footer();
    }

    /**
     * @dev The check that earns this script its second run. If a mandate has already been granted,
     *      its `maxPCPerCall` is fixed; a fresh quote above it means every agent request will be
     *      refused by gate 8 until the mandate is regranted.
     *
     *      Silent when no mandate exists yet — on the first run there is nothing to compare against,
     *      and a warning there would be noise that trains the reader to ignore this line.
     */
    function _warnIfMandateCapTooLow(uint256 msgValue) private view {
        if (!Ledger.has("mandate.maxPCPerCall")) return;

        uint256 granted = Ledger.num("mandate.maxPCPerCall", "13_GrantMandate");
        DemoLog.blank();

        if (msgValue > granted) {
            DemoLog.fail("PC CAP", "the granted mandate cannot pay for an outbound at today's fees");
            DemoLog.kv("  granted", DemoLog.formatAmount(granted, 18, "PC"));
            DemoLog.kv("  needed", DemoLog.formatAmount(msgValue, 18, "PC"));
            DemoLog.note("Every agent request will be refused by URP gate 8 (PCValueExceedsCap).");
            DemoLog.note("Revoke and regrant the mandate before presenting.");
        } else {
            DemoLog.ok("PC cap", string.concat("granted ", DemoLog.formatAmount(granted, 18, "PC"), " covers today"));
        }
    }
}
