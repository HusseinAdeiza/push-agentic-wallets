// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { Session } from "smartsessions/DataTypes.sol";

import { IPushAgentWallet } from "../../../src/interfaces/IPushAgentWallet.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";
import { MandateType } from "../../../src/libraries/PushWalletTypes.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeMandate } from "../../lib/NativeMandate.sol";

/// @dev `IPushAgentWallet` carries the wallet's EVENTS only — it deliberately declares no
///      functions — so the one call this script makes is declared here. The signature mirrors
///      `PushAgentWallet.grantMandate` exactly; `Session` is the same `smartsessions` type the
///      wallet takes, so `abi.encodeCall` type-checks against the real ABI.
interface IWalletGrant {
    function grantMandate(Session calldata session, MandateType mandateType) external returns (bytes32 permissionId);
}

/**
 * @title  GrantMandate
 * @notice ACT 1d · Chain: Donut · broadcasts with BOB's key.
 *         THE MOST IMPORTANT OUTPUT ANY SCRIPT IN THIS DEMO PRODUCES.
 *
 * @dev    The mandate summary this prints is the demo's thesis on one screen, and it is where the
 *         live demo opens. Everything else exists to make it credible.
 *
 *         WHAT THE MANDATE SAYS, in one sentence: this agent key may call ONE function on ONE
 *         contract on this chain, only ever crediting Bob's own wallet, up to 25 dUSDC per action
 *         and 60 dUSDC in total, at most four times, for seven days. Nothing else.
 *
 *         THE PIN IS THE PRODUCT. `pins[0]` fixes the beneficiary word to the wallet. Without it
 *         the agent could stake Bob's money naming ITSELF as beneficiary and then call `unstake()`
 *         straight from its own EOA — under no mandate at all — and walk away with principal plus
 *         reward. Act 3's G3 demonstrates exactly that attempt being refused.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantMandate` refuses anything
 *         but the canonical shape, and it refuses a NATIVE mandate that names the gateway — the
 *         consistency lock whose runtime mirror is URP's gate N3.
 */
contract GrantMandate is Script {
    error MandateNotGranted();
    error ConfigNotInitialised();

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants every mandate");
        address agent = Keys.addressOf("AGENT_KEY", "the agent key the mandate authorises");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.stakeFor.selector;

        Session memory session = NativeMandate.stakeSession(agent, agw, stake, selector);

        vm.recordLogs();
        vm.startBroadcast(bobPk);
        IWalletGrant(agw).grantMandate(session, MandateType.NATIVE);
        vm.stopBroadcast();

        bytes32 permissionId = _readPermissionId();
        bytes32 configId = NativeIds.configWord(permissionId, agw, stake, selector);

        Ledger.setWord("permissionId", permissionId);
        Ledger.setWord("configId", configId);

        // READ THE RULEBOOK BACK FROM URP. A grant that "succeeded" but wrote nothing readable is
        // the failure this demo cannot afford, and it is exactly what a wrong config-id derivation
        // looks like — so the id is proven here, against live state, before any act depends on it.
        IURP.NativeConfig memory cfg =
            IURP(AddressBook.ours("urp")).getNativeConfig(NativeIds.configId(permissionId, agw, stake, selector), agw);
        if (!cfg.initialized) revert ConfigNotInitialised();

        _printMandate(agent, agw, stake, permissionId, cfg);
    }

    /// @dev The permission id comes from the wallet's own event, never recomputed here — the
    ///      derivation mixes encodings across levels and an SDK that assumes one derives it wrong.
    function _readPermissionId() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IPushAgentWallet.MandateGranted.selector;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic) return logs[i].topics[1];
        }
        revert MandateNotGranted();
    }

    /**
     * @dev THE DEMO'S THESIS ON ONE SCREEN. Get this right before anything else — it is where the
     *      live demo opens, and it is the block the audience reads while everything else scrolls.
     *
     *      EVERY NUMBER HERE IS READ BACK FROM URP, not from `Amounts`. A summary printed from the
     *      constants would say what we INTENDED to grant; this says what the chain actually stored.
     */
    function _printMandate(
        address agent,
        address agw,
        address stake,
        bytes32 permissionId,
        IURP.NativeConfig memory cfg
    ) internal view {
        DemoLog.header("ACT 1d", "The mandate");
        DemoLog.line(DemoLog.bold("This agent key may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("stakeFor()"), " on StakeDummy"));
        DemoLog.note(string.concat("      but only ever crediting ", vm.toString(agw)));
        DemoLog.blank();
        DemoLog.money("Per action", cfg.amount.maxPerCall, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Lifetime", cfg.amount.maxTotal, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("At most", string.concat(vm.toString(uint256(cfg.maxCalls)), " calls"));
        DemoLog.kv("Native value", "0 - this mandate can carry none");
        DemoLog.kv("Expires", "in 7 days");
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Nothing else. No other contract, no other function,"));
        DemoLog.line(DemoLog.dim("no other beneficiary."));
        DemoLog.footer();

        DemoLog.header("", "For the record");
        DemoLog.addrPlain("Agent key", agent);
        DemoLog.note("    Holds no funds. Owns nothing. Cannot be topped up.");
        DemoLog.addrPlain("StakeDummy", stake);
        DemoLog.kv("Permission id", vm.toString(permissionId));
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("The pinned beneficiary:"));
        DemoLog.kv("  offset", string.concat(vm.toString(uint256(cfg.pins[0].offset)), " (first argument word)"));
        DemoLog.kv("  must equal", vm.toString(cfg.pins[0].expected));
        DemoLog.note("    One word of calldata. It is what stops the agent staking to itself");
        DemoLog.note("    and then unstaking to itself from its own EOA.");
        DemoLog.footer();
    }
}
