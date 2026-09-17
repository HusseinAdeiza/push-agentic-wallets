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
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeMandate } from "../../lib/NativeMandate.sol";

interface IWalletGrant {
    function grantMandate(Session calldata session, MandateType mandateType) external returns (bytes32 permissionId);
}

/**
 * @title  GrantUnstake
 * @notice ACT 4a′ · Chain: Donut · broadcasts with BOB's key. A SECOND mandate, for one job.
 *
 * @dev    `unstake()` was never in the stake mandate — G2 proved it, by being refused. Bob grants a
 *         separate mandate for it now, which is a stronger story than bundling both at the start:
 *         a mandate is granted for a job, used, and then dies with `stopAll`.
 *
 *         THREE THINGS ARE DELIBERATELY DIFFERENT FROM THE STAKE MANDATE:
 *
 *           · NO PINS. `unstake()` takes no arguments and credits `msg.sender`, which is the wallet.
 *             There is nothing to redirect, so there is nothing to pin. Do not "fix" this by adding
 *             one — a pin on a zero-argument call can never match, and the mandate would authorise
 *             nothing at all.
 *           · NO AMOUNT RULE. There is no amount word in the calldata to meter.
 *           · `maxCalls = 1`. The honest shape for "unstake once" — and it is what makes G8 fire at
 *             gate N9, cleanly, BEFORE dispatch, so `StakeDummy.NothingStaked()` never gets the
 *             chance to muddy the error.
 *
 *         IT TAKES NONCE LANE 1. Lanes are per-wallet, and the SDK convention is one lane per
 *         mandate. Lane 0 is spent by the stake mandate; lane 1 starts fresh at zero.
 */
contract GrantUnstake is Script {
    error MandateNotGranted();
    error ConfigNotInitialised();

    function run() external {
        address agw = Ledger.addr("agw", "10_DeployWallet");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.unstake.selector;

        bytes32 permissionId = _grant(agw, stake, selector);

        Ledger.setWord("unstakePermissionId", permissionId);
        Ledger.setWord("unstakeConfigId", NativeIds.configWord(permissionId, agw, stake, selector));

        IURP.NativeConfig memory cfg =
            IURP(AddressBook.ours("urp")).getNativeConfig(NativeIds.configId(permissionId, agw, stake, selector), agw);
        if (!cfg.initialized) revert ConfigNotInitialised();

        _print(permissionId, cfg.maxCalls);
    }

    /// @dev Builds the session and broadcasts the grant. Split out for STACK DEPTH: with the
    ///      `Session` struct live alongside the ids and the config, `run` does not compile under
    ///      via_ir — measured, not guessed.
    function _grant(address agw, address stake, bytes4 selector) private returns (bytes32) {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants the unstake mandate");
        address agent = Keys.addressOf("AGENT_KEY", "the same agent key - a new job, not a new agent");

        Session memory session = NativeMandate.unstakeSession(agent, stake, selector);

        vm.recordLogs();
        vm.startBroadcast(bobPk);
        IWalletGrant(agw).grantMandate(session, MandateType.NATIVE);
        vm.stopBroadcast();

        return _readPermissionId();
    }

    /// @dev Split out for STACK DEPTH only. With the session, config and both ids still live, the
    ///      print block does not compile under via_ir — measured, not guessed.
    function _print(bytes32 permissionId, uint32 maxCalls) private view {
        DemoLog.header("ACT 4a'", "A second mandate, for one job");
        DemoLog.line(DemoLog.bold("This agent key may now also:"));
        DemoLog.line(string.concat(unicode"  \u00b7 call ", DemoLog.bold("unstake()"), " on StakeDummy"));
        DemoLog.blank();
        DemoLog.kv("At most", string.concat(vm.toString(uint256(maxCalls)), " call"));
        DemoLog.kv("Pins", "none - and that is correct");
        DemoLog.note("    unstake() takes no arguments and credits msg.sender, which IS the");
        DemoLog.note("    wallet. There is no argument to redirect, so nothing to pin.");
        DemoLog.blank();
        DemoLog.kv("Permission id", vm.toString(permissionId));
        DemoLog.kv("Nonce lane", "1 - one lane per mandate; lane 0 belongs to the stake mandate");
        DemoLog.footer();
    }

    function _readPermissionId() private returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == IPushAgentWallet.MandateGranted.selector) {
                return logs[i].topics[1];
            }
        }
        revert MandateNotGranted();
    }
}
