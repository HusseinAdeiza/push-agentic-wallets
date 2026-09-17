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
    function grantMandate(Session calldata session) external returns (bytes32 permissionId);
}

/**
 * @title  GrantUnpinnedApprove
 * @notice ACT 4f (2 of 5) · A mandate with a hole in it. GRANTED SUCCESSFULLY.
 *
 * @dev    NOTHING REFUSES THIS, AND THAT IS THE POINT. It is a well-formed mandate: canonical
 *         shape, the real validator, the deployed URP, a legitimate target, a legitimate selector.
 *         `grantMandate` accepts it. URP initialises it. It looks exactly like the stake mandate
 *         from Act 1d.
 *
 *         THE DIFFERENCE IS ONE ABSENT FIELD: `pins` is empty. The stake mandate pinned the
 *         beneficiary word; this one pins nothing, so `approve(anyone, anything)` is authorised.
 *
 *         THE CONTRACT CANNOT TELL. There is no heuristic in URP that could distinguish "this
 *         mandate omitted a pin because the argument is safe" from "this mandate omitted a pin by
 *         mistake" — a mandate without pins is a perfectly valid mandate that simply permits more.
 *         PINNING IS THE SDK'S OBLIGATION, NOT THE CONTRACT'S. That sentence is the whole act.
 *
 *         ⚠️ THE TARGET IS `DemoUSDC`, NOT `StakeDummy`. This is the only place in the demo where
 *         the action target is not the staking contract, so the config id is derived against the
 *         token. Deriving it against `StakeDummy` out of habit yields an id addressing an empty
 *         slot, and every read fails at gate N1 with `NotInitialized`.
 */
contract GrantUnpinnedApprove is Script {
    error MandateNotGranted();
    error ConfigNotInitialised();
    error PinsShouldBeEmpty(uint256 count);

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob grants a mandate with a hole in it");
        address agent = Keys.addressOf("AGENT_KEY", "the agent this over-broad mandate authorises");
        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        address token = AddressBook.native("DemoUSDC");
        bytes4 selector = IERC20.approve.selector;

        // THE HOLE: `address(0)` means "do not pin the spender".
        Session memory session = NativeMandate.approveSession(agent, token, selector, address(0));

        vm.recordLogs();
        vm.startBroadcast(bobPk);
        IWalletGrant(wallet).grantMandate(session);
        vm.stopBroadcast();

        bytes32 permissionId = _readPermissionId();
        Ledger.setWord("unpinnedApprovePermissionId", permissionId);
        Ledger.setWord("unpinnedApproveConfigId", NativeIds.configWord(permissionId, wallet, token, selector));

        IURP.NativeConfig memory cfg = IURP(AddressBook.ours("urp"))
            .getNativeConfig(NativeIds.configId(permissionId, wallet, token, selector), wallet);
        if (!cfg.initialized) revert ConfigNotInitialised();
        if (cfg.pins.length != 0) revert PinsShouldBeEmpty(cfg.pins.length);

        DemoLog.header("ACT 4f", "A mandate with a hole in it");
        DemoLog.line(DemoLog.bold("This agent key may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("approve()"), " on dUSDC"));
        DemoLog.blank();
        DemoLog.kv("Pinned arguments", "NONE");
        DemoLog.note("    So: approve WHOM, for HOW MUCH? The mandate does not say.");
        DemoLog.blank();
        DemoLog.ok("granted", "nothing refused it - it is a well-formed mandate");
        DemoLog.note("    Canonical shape, the real validator, the deployed policy, a");
        DemoLog.note("    legitimate target. It looks exactly like Act 1d's mandate.");
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("A mandate without pins is not a malformed mandate."));
        DemoLog.line(DemoLog.dim("It is a valid one that simply permits more."));
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
