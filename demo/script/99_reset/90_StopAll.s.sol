// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Requests } from "../../lib/Requests.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

interface IEngineCheck {
    function isPermissionEnabled(bytes32 permissionId, address account) external view returns (bool);
}

/// @dev `IPushAgentWallet` carries the wallet's EVENTS only — it deliberately declares no
///      functions — so the one call this script makes is declared here.
interface IWalletRevoke {
    function stopAll() external;
}

/**
 * @title  StopAll
 * @notice Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *         REHEARSAL RECOVERY ONLY. Never run this during the live demo.
 *
 * @dev    Revokes every mandate on the wallet in one call, so a rehearsal can be reset without
 *         redeploying anything. The wallet keeps its funds, its owner and its address; only the
 *         agent's authority goes.
 *
 *         WHY IT IS SAFE TO CALL AT ANY MOMENT, and this is a load-bearing property rather than a
 *         convenience: `stopAll` has NOTHING ON IT THAT CAN FAIL. No guard, no probe, no extra
 *         external call. Blockable revocation would be the one regression this function must never
 *         develop — an owner who cannot revoke has no real control, whatever the caps say.
 *
 *         AFTER RUNNING IT, THE LEDGER'S MANDATE KEYS ARE STALE. The permission id names a mandate
 *         that no longer exists, so every agent script would fail at the engine rather than at a
 *         gate. This clears them, which also resets `Preflight` to phase B and makes the next
 *         `just act1e` a clean grant.
 *
 *         The nonce lane is NOT reset — it is wallet state, not mandate state, and it keeps
 *         advancing across regrants. That is correct: a banked request signed against the old
 *         mandate must stay dead, and both the permission id (op-hash field 5) and the nonce
 *         guarantee it independently.
 */
contract StopAll is Script {
    error NoMandateToStop();

    uint256 internal constant VALID_FOR = 1 hours;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "only the owner may revoke");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address engine = AddressBook.ours("sessionEngine");

        DemoLog.header("RESET", "Revoke every mandate");
        DemoLog.line(DemoLog.red("  REHEARSAL RECOVERY ONLY. Never during the live demo."));
        DemoLog.blank();
        DemoLog.addrPlain("Wallet", agw);

        bool hadMandate = Ledger.has("permissionId");
        bytes32 pid = hadMandate ? Ledger.word("permissionId", "14_GrantMandate") : bytes32(0);

        if (hadMandate) {
            DemoLog.kv("Before", IEngineCheck(engine).isPermissionEnabled(pid, agw) ? "1 mandate, live" : "0 live");
        } else {
            DemoLog.kv("Before", DemoLog.dim("no mandate recorded"));
        }

        Multicall[] memory call = Requests.singleCall(agw, abi.encodeCall(IWalletRevoke.stopAll, ()));

        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, call, bobPk, VALID_FOR);

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        if (hadMandate) {
            DemoLog.kv("After", IEngineCheck(engine).isPermissionEnabled(pid, agw) ? "still live" : "0 live");
        }

        // The ledger's mandate keys now name something that does not exist. CLEARED, not zeroed:
        // a zeroed key leaves `has` true and every read reverting.
        Ledger.clear("permissionId");
        Ledger.clear("mandate.maxPCPerCall");

        DemoLog.blank();
        DemoLog.ok("revoked", "the agent key has no authority left");
        DemoLog.note("The wallet keeps its funds, its owner and its address.");
        DemoLog.note("The nonce lane is NOT reset - a banked request stays dead across a regrant.");
        DemoLog.blank();
        DemoLog.note("Run `just act1e` to grant a fresh mandate.");
        DemoLog.footer();
    }
}
