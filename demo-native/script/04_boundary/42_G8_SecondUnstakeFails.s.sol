// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G8_SecondUnstakeFails
 * @notice ACT 4 · G8 · The call ceiling. A second `unstake()` under a one-call mandate.
 *
 * @dev    WHY THIS LIVES ON THE UNSTAKE MANDATE RATHER THAN WITH G1-G7. Gate N8 (amount) runs
 *         before gate N9 (calls), so ONE mandate cannot demonstrate both its lifetime budget and
 *         its call ceiling: reaching four calls means the budget never ran out, and exhausting the
 *         budget takes only three. The stake mandate shows the budget (G7); the unstake mandate,
 *         with `maxCalls = 1`, shows the ceiling.
 *
 *         IT ALSO FIRES BEFORE DISPATCH, WHICH IS THE POINT. The wallet's stake is already zero
 *         after Act 4a, so a second `unstake()` would revert inside `StakeDummy` with
 *         `NothingStaked()` — an error about the counterparty's state, not about permissions.
 *         `maxCalls = 1` means URP refuses it at N9 first, so the refusal is about the MANDATE.
 *         That distinction is the whole reason the cap is one.
 */
contract G8_SecondUnstakeFails is Script {
    error CallCeilingNotReached(uint32 used, uint32 max);

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs one call too many");
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("unstakePermissionId", "40_GrantUnstake");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.unstake.selector;

        ConfigId configId = NativeIds.configId(permissionId, agw, stake, selector);
        IURP.NativeConfig memory cfg = IURP(AddressBook.ours("urp")).getNativeConfig(configId, agw);

        // ASSERT THE PRECONDITION, so an out-of-order rehearsal fails with a sentence rather than
        // with the wrong error. If Act 4a has not run, this request would reach `StakeDummy` and
        // revert with `NothingStaked()` — proving nothing about permissions.
        if (cfg.callsUsed < cfg.maxCalls) revert CallCeilingNotReached(cfg.callsUsed, cfg.maxCalls);

        NativeRequest.Built memory req =
            NativeRequest.build(agentPk, agw, permissionId, 1, stake, abi.encodeCall(StakeDummy.unstake, ()), 0);

        DemoLog.header("G8", "One call too many");
        DemoLog.kv("Calls allowed", vm.toString(uint256(cfg.maxCalls)));
        DemoLog.kv("Calls used", vm.toString(uint256(cfg.callsUsed)));
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            "a second unstake(), under a one-call mandate",
            IURP.CallLimitReached.selector,
            "Refused at validation - so StakeDummy's own NothingStaked() never gets the chance. The refusal is about the mandate, not the counterparty.",
            req
        );
        DemoLog.footer();
    }
}
