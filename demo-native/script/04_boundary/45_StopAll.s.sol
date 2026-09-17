// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { PermissionId } from "smartsessions/DataTypes.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { IOwnerDoor } from "../../lib/OwnerDoor.sol";

interface ISmartSessionView {
    function isPermissionEnabled(PermissionId permissionId, address account) external view returns (bool);
}

/**
 * @title  StopAll
 * @notice ACT 4d · The emergency lever. Every mandate dies, immediately.
 *
 * @dev    ONE CALL, NO ARGUMENTS, NO CONDITIONS. `stopAll` carries no guard, no health probe and no
 *         extra external call, and that is a deliberate architectural rule rather than an
 *         oversight: BLOCKABLE REVOCATION IS THE ONE REGRESSION THIS FUNCTION CAN DEVELOP. Anything
 *         that can fail on the stop path is a way for an attacker to keep a mandate alive.
 *
 *         REVOCATION IS IMMEDIATE, NOT SCHEDULED. There is no timelock, no cooldown, no pending
 *         state. The next block cannot carry an agent request under these permissions — and Act 4e
 *         proves it with a signature that was valid moments before.
 *
 *         Both mandates are read back from the ENGINE afterwards, not assumed dead because the call
 *         returned.
 */
contract StopAll is Script {
    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 stakePid = Ledger.word("permissionId", "13_GrantMandate");

        ISmartSessionView engine = ISmartSessionView(AddressBook.ours("sessionEngine"));

        bool stakeBefore = engine.isPermissionEnabled(PermissionId.wrap(stakePid), agw);
        bool unstakeBefore;
        bytes32 unstakePid;
        if (Ledger.has("unstakePermissionId")) {
            unstakePid = Ledger.word("unstakePermissionId", "40_GrantUnstake");
            unstakeBefore = engine.isPermissionEnabled(PermissionId.wrap(unstakePid), agw);
        }

        vm.startBroadcast(bobPk);
        IOwnerDoor(agw).stopAll();
        vm.stopBroadcast();

        bool stakeAfter = engine.isPermissionEnabled(PermissionId.wrap(stakePid), agw);
        bool unstakeAfter =
            unstakePid == bytes32(0) ? false : engine.isPermissionEnabled(PermissionId.wrap(unstakePid), agw);

        DemoLog.header("ACT 4d", "Stop everything");
        DemoLog.kv("Stake mandate", string.concat(_state(stakeBefore), " -> ", _state(stakeAfter)));
        if (unstakePid != bytes32(0)) {
            DemoLog.kv("Unstake mandate", string.concat(_state(unstakeBefore), " -> ", _state(unstakeAfter)));
        }
        DemoLog.blank();
        DemoLog.ok("revoked", "immediately - no timelock, no cooldown, no pending state");
        DemoLog.note("    stopAll carries no guard and no probe, deliberately: anything that");
        DemoLog.note("    can fail on the stop path is a way to keep a mandate alive.");
        DemoLog.footer();

        require(!stakeAfter, "the stake mandate survived stopAll");
        require(!unstakeAfter, "the unstake mandate survived stopAll");
    }

    function _state(bool enabled) private pure returns (string memory) {
        return enabled ? "live" : "dead";
    }
}
