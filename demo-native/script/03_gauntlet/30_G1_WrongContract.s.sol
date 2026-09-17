// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G1_WrongContract
 * @notice ACT 3 · G1 · A correctly-signed request naming a DIFFERENT contract.
 *
 * @dev    REFUSED BY THE ENGINE, NOT BY URP — and the script says so rather than implying a policy
 *         gate fired.
 *
 *         A native mandate binds `(target, selector)` into the engine's ACTION ID. Changing the
 *         target changes the id, the engine finds no action matching it, and the request dies with
 *         `NoPoliciesSet` before URP is ever called. That is a STRONGER guarantee than a policy
 *         check, not a weaker one: the policy never even has to have an opinion.
 *
 *         The request is RE-SIGNED over the mutated calldata, so it fails at the gate it claims to
 *         demonstrate rather than on a bad signature.
 */
contract G1_WrongContract is Script {
    /// @dev `ISmartSession.NoPoliciesSet(PermissionId)`; `PermissionId` is a `bytes32` user-defined
    ///      type, so the ABI signature is `NoPoliciesSet(bytes32)`. DERIVED, never pasted.
    bytes4 internal constant NO_POLICIES_SET = bytes4(keccak256("NoPoliciesSet(bytes32)"));

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the mutated request");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");

        // THE ONE MUTATION: the token, not the staking contract. Everything else is Act 2's shape.
        address wrongTarget = AddressBook.native("DemoUSDC");

        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            agw,
            permissionId,
            0,
            wrongTarget,
            abi.encodeCall(StakeDummy.stakeFor, (agw, Amounts.ACT2)),
            Amounts.ACT2
        );

        DemoLog.header("G1", "A different contract");
        NativeGauntlet.refuseRaw(
            "stakeFor() on DemoUSDC instead of StakeDummy",
            NO_POLICIES_SET,
            "the engine",
            "The mandate names one contract. A different one is not a different permission - it is no permission at all.",
            req
        );
        DemoLog.footer();
    }
}
