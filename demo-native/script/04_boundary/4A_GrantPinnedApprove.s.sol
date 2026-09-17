// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { Session } from "smartsessions/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPushAgentWallet } from "../../../src/interfaces/IPushAgentWallet.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";
import { MandateType } from "../../../src/libraries/PushWalletTypes.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeMandate } from "../../lib/NativeMandate.sol";

interface IWalletGrant {
    function grantMandate(Session calldata session, MandateType mandateType) external returns (bytes32 permissionId);
}

/**
 * @title  GrantPinnedApprove
 * @notice ACT 4f (4 of 5) · The SAME mandate, with one field filled in.
 *
 * @dev    IDENTICAL TO `48_GrantUnpinnedApprove` IN EVERY RESPECT BUT ONE: `pins` names the
 *         spender. Same wallet, same agent, same target, same selector, same caps — so when the
 *         next script's request is refused, the pin is unambiguously the reason.
 *
 *         THE SPENDER IS PINNED TO `StakeDummy`, which is the only address this mandate should ever
 *         approve: a staking mandate needs the staking contract to be able to pull tokens, and
 *         nothing else. Any other spender — including the accomplice who succeeded one act ago —
 *         is now a gate N7 failure.
 *
 *         THE MANDATE IS GRANTED ON THE SAME (NOW EMPTY) THROWAWAY WALLET, on nonce lane 1. Lanes
 *         are per-wallet and per-mandate; lane 0 of this wallet was spent by the unpinned mandate.
 */
contract GrantPinnedApprove is Script {
    error MandateNotGranted();
    error ConfigNotInitialised();
    error PinMissing();

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants the corrected mandate");
        address agent = Keys.addressOf("AGENT_KEY", "the same agent key");
        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        address token = AddressBook.native("DemoUSDC");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = IERC20.approve.selector;

        // THE ONE DIFFERENCE: the spender is pinned to the staking contract.
        Session memory session = NativeMandate.approveSession(agent, token, selector, stake);

        vm.recordLogs();
        vm.startBroadcast(bobPk);
        IWalletGrant(wallet).grantMandate(session, MandateType.NATIVE);
        vm.stopBroadcast();

        bytes32 permissionId = _readPermissionId();
        Ledger.setWord("pinnedApprovePermissionId", permissionId);
        Ledger.setWord("pinnedApproveConfigId", NativeIds.configWord(permissionId, wallet, token, selector));

        IURP.NativeConfig memory cfg = IURP(AddressBook.ours("urp"))
            .getNativeConfig(NativeIds.configId(permissionId, wallet, token, selector), wallet);
        if (!cfg.initialized) revert ConfigNotInitialised();
        if (cfg.pins.length != 1) revert PinMissing();

        DemoLog.header("ACT 4f", "The same mandate, with the hole closed");
        DemoLog.line(DemoLog.bold("This agent key may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("approve()"), " on dUSDC"));
        DemoLog.note(string.concat("      but ONLY naming ", vm.toString(stake)));
        DemoLog.blank();
        DemoLog.kv("Pinned argument", "spender, at offset 4");
        DemoLog.kv("Must equal", vm.toString(cfg.pins[0].expected));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Same wallet, same agent, same contract, same function, same caps."));
        DemoLog.line(DemoLog.dim("One field is different."));
        DemoLog.kv("Permission id", vm.toString(permissionId));
        DemoLog.footer();
    }

    function _readPermissionId() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IPushAgentWallet.MandateGranted.selector;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic) return logs[i].topics[1];
        }
        revert MandateNotGranted();
    }
}
