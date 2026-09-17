// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { PermissionId } from "smartsessions/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { IAgentDoor } from "../../lib/NativeRequest.sol";

interface ISmartSessionView {
    function isPermissionEnabled(PermissionId permissionId, address account) external view returns (bool);
}

/**
 * @title  State
 * @notice INSPECT · Read-only. Run between every act.
 *
 * @dev    THE OPERATOR'S INSTRUMENT, and the audience's scoreboard. Everything here is read live
 *         from the chain — nothing is remembered from a previous script, and nothing is inferred.
 *
 *         IT DEGRADES GRACEFULLY. Every section is guarded by `Ledger.has`, so this runs at any
 *         point in the demo — before the wallet exists, between acts, or after `stopAll` — and
 *         reports what is true right now rather than failing on a key that has not been written
 *         yet.
 */
contract State is Script {
    function run() external view {
        DemoLog.header("STATE", "Live, from the chain");

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));
        StakeDummy staking = StakeDummy(AddressBook.native("StakeDummy"));

        _people(token);
        _wallet(token, staking);
        _mandates();
        _pool(token, staking);

        DemoLog.footer();
    }

    function _people(IERC20 token) private view {
        address bob = Keys.addressOf("BOB_KEY", "the user");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer");

        DemoLog.line(DemoLog.bold("People"));
        DemoLog.addrPlain("  Bob", bob);
        DemoLog.money("    dUSDC", token.balanceOf(bob), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("    PC", string.concat(vm.toString(bob.balance / 1e15), " milli-PC"));

        DemoLog.addrPlain("  Agent", agent);
        DemoLog.money("    dUSDC", token.balanceOf(agent), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("    PC", string.concat(vm.toString(agent.balance / 1e15), " milli-PC"));
        DemoLog.note("      both should be ZERO - the agent holds nothing, ever");

        DemoLog.addrPlain("  Relayer", relayer);
        DemoLog.kv("    PC", string.concat(vm.toString(relayer.balance / 1e15), " milli-PC"));
        DemoLog.blank();
    }

    function _wallet(IERC20 token, StakeDummy staking) private view {
        if (!Ledger.has("agw")) {
            DemoLog.note("No wallet yet - run act1a.");
            DemoLog.blank();
            return;
        }
        address agw = Ledger.addr("agw", "10_DeployWallet");

        DemoLog.line(DemoLog.bold("The wallet"));
        DemoLog.addrPlain("  Address", agw);
        DemoLog.money("  dUSDC held", token.balanceOf(agw), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("  staked", staking.totalBalance(agw), Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money(
            "  approved to StakeDummy", token.allowance(agw, address(staking)), Amounts.DECIMALS, Amounts.SYMBOL
        );
        DemoLog.kv("  nonce lane 0", vm.toString(uint256(IAgentDoor(agw).getNonce(0))));
        DemoLog.kv("  nonce lane 1", vm.toString(uint256(IAgentDoor(agw).getNonce(1))));
        DemoLog.blank();
    }

    function _mandates() private view {
        if (!Ledger.has("agw") || !Ledger.has("permissionId")) return;

        address agw = Ledger.addr("agw", "10_DeployWallet");
        ISmartSessionView engine = ISmartSessionView(AddressBook.ours("sessionEngine"));
        IURP urp = IURP(AddressBook.ours("urp"));
        address stake = AddressBook.native("StakeDummy");

        DemoLog.line(DemoLog.bold("Mandates"));

        bytes32 stakePid = Ledger.word("permissionId", "13_GrantMandate");
        bool live = engine.isPermissionEnabled(PermissionId.wrap(stakePid), agw);
        DemoLog.kv("  stake mandate", live ? "LIVE" : "revoked");

        if (live) {
            IURP.NativeConfig memory cfg =
                urp.getNativeConfig(NativeIds.configId(stakePid, agw, stake, StakeDummy.stakeFor.selector), agw);
            DemoLog.money("    spent", cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
            DemoLog.money("    remaining", cfg.amount.maxTotal - cfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
            DemoLog.kv(
                "    calls",
                string.concat(vm.toString(uint256(cfg.callsUsed)), " of ", vm.toString(uint256(cfg.maxCalls)))
            );
        }

        if (Ledger.has("unstakePermissionId")) {
            bytes32 pid = Ledger.word("unstakePermissionId", "40_GrantUnstake");
            bool unstakeLive = engine.isPermissionEnabled(PermissionId.wrap(pid), agw);
            DemoLog.kv("  unstake mandate", unstakeLive ? "LIVE" : "revoked");
            if (unstakeLive) {
                IURP.NativeConfig memory cfg =
                    urp.getNativeConfig(NativeIds.configId(pid, agw, stake, StakeDummy.unstake.selector), agw);
                DemoLog.kv(
                    "    calls",
                    string.concat(vm.toString(uint256(cfg.callsUsed)), " of ", vm.toString(uint256(cfg.maxCalls)))
                );
            }
        }
        DemoLog.blank();
    }

    function _pool(IERC20 token, StakeDummy staking) private view {
        uint256 pool = token.balanceOf(address(staking));
        DemoLog.line(DemoLog.bold("Reward pool"));
        DemoLog.money("  balance", pool, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.kv("  funds", string.concat(vm.toString(pool / Amounts.REWARD), " more unstake(s)"));

        if (Ledger.has("throwawayAgw")) {
            address t = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
            DemoLog.blank();
            DemoLog.line(DemoLog.bold("Throwaway wallet (Act 4f)"));
            DemoLog.addrPlain("  Address", t);
            DemoLog.money("  dUSDC held", token.balanceOf(t), Amounts.DECIMALS, Amounts.SYMBOL);
            DemoLog.note("      should be 0 after 4f - if not, sweep it with `just reset`");
        }
    }
}
