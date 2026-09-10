// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "./AddressBook.sol";
import { DemoLog } from "./DemoLog.sol";
import { Ledger } from "./Ledger.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { SEND_OUTBOUND_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

interface IWalletState {
    function getNonce(uint192 nonceKey) external view returns (uint64);
    function owner() external view returns (address);
}

interface IEngineState {
    function isPermissionEnabled(bytes32 permissionId, address account) external view returns (bool);
}

interface IStakeState {
    function totalBalance(address) external view returns (uint256);
}

/**
 * @title  Inspect
 * @notice Shared state reads for the three `05_inspect` scripts.
 *
 * @dev    RUN BETWEEN EVERY ACT. These are what make a terminal demo legible: without them the
 *         audience sees transactions succeed and has to take the consequences on trust.
 *
 *         THE REMAINING-BUDGET LINE IS THE ONE THAT MATTERS. Watching `spent 50.00 / 60.00 · 10.00
 *         remaining` move is how the mandate stops being an abstraction — it is the moment the
 *         audience feels a limit being consumed rather than hearing one described.
 *
 *         Everything here is a pure read. Nothing broadcasts, nothing writes the ledger.
 */
library Inspect {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ────────────────────────────────── Push side ──────────────────────────────────

    /// @notice The wallet: what it holds, what it can spend, where its nonce lane sits.
    function pushState() internal view {
        address agw = Ledger.addr("agw", "10_Arrive");
        address uea = Ledger.addr("uea", "10_Arrive");
        IERC20 prc20 = IERC20(AddressBook.donut("PRC20_USDC"));

        DemoLog.line(DemoLog.bold("Push Chain"));
        DemoLog.addrPlain("Wallet", agw);
        DemoLog.money("  holds", prc20.balanceOf(agw), 6, "pUSDC");
        DemoLog.money("  gas", agw.balance, 18, "PC");
        DemoLog.kv("  owner", vm.toString(IWalletState(agw).owner()));
        DemoLog.kv("  nonce lane 0", vm.toString(IWalletState(agw).getNonce(0)));
        DemoLog.blank();
        DemoLog.addrPlain("Bob (UEA)", uea);
        DemoLog.money("  holds", prc20.balanceOf(uea), 6, "pUSDC");
    }

    /// @notice The mandate, rendered readably — caps, spend, remaining, expiry, allow-list.
    function mandate() internal view {
        if (!Ledger.has("permissionId")) {
            DemoLog.kv("Mandate", DemoLog.dim("not granted yet"));
            return;
        }

        address agw = Ledger.addr("agw", "10_Arrive");
        bytes32 pid = Ledger.word("permissionId", "14_GrantMandate");

        bool live = IEngineState(AddressBook.ours("sessionEngine")).isPermissionEnabled(pid, agw);
        IUCEP.Config memory cfg = IUCEP(AddressBook.ours("ucep")).getConfig(configId(agw), agw);

        DemoLog.line(DemoLog.bold("The mandate"));
        DemoLog.kv("Status", live ? DemoLog.green("live") : DemoLog.red("revoked"));
        DemoLog.money("Per action", cfg.maxAmountPerCall, 6, "USDC");

        // THE LINE THE AUDIENCE WATCHES MOVE.
        DemoLog.kv(
            "Spent",
            string.concat(
                DemoLog.bold(DemoLog.formatAmount(cfg.spent, 6, "")),
                " / ",
                DemoLog.formatAmount(cfg.maxAmountTotal, 6, "USDC"),
                "   ",
                DemoLog.bold(DemoLog.formatAmount(cfg.maxAmountTotal - cfg.spent, 6, "USDC")),
                " remaining"
            )
        );

        DemoLog.kv("Expires", string.concat("timestamp ", vm.toString(uint256(cfg.validUntil))));
        DemoLog.addrPlain("Beneficiary", cfg.expectedCEA);
        DemoLog.note("    Pinned at grant. The agent can stake for this account and no other.");
        DemoLog.kv("Allow-list", string.concat(vm.toString(cfg.allowedCalls.length), " calls"));

        for (uint256 i; i < cfg.allowedCalls.length; ++i) {
            IUCEP.AllowedCall memory a = cfg.allowedCalls[i];
            DemoLog.note(
                string.concat(
                    "    ",
                    vm.toString(abi.encodePacked(a.selector)),
                    " on ",
                    vm.toString(a.target),
                    a.hasBeneficiary ? "  (beneficiary pinned)" : ""
                )
            );
        }
    }

    // ───────────────────────────────── Sepolia side ─────────────────────────────────

    /// @notice The CEA and the far-chain position. Switches fork; restores it afterwards.
    function sepoliaState() internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");

        uint256 startingFork = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        IERC20 usdc = IERC20(AddressBook.sepolia("USDC"));
        address stake = AddressBook.sepolia("StakeDummy");

        DemoLog.line(DemoLog.bold("Ethereum Sepolia"));
        DemoLog.addrPlain("CEA", cea);

        if (cea.code.length == 0) {
            DemoLog.kv("  status", DemoLog.dim("not deployed yet - act1d deploys it"));
        } else {
            DemoLog.kv("  status", DemoLog.green("deployed at the predicted address"));
            DemoLog.money("  holds", usdc.balanceOf(cea), 6, "USDC");
            DemoLog.money("  staked", IStakeState(stake).totalBalance(cea), 6, "USDC");
        }

        DemoLog.blank();
        DemoLog.addrPlain("StakeDummy", stake);
        DemoLog.money("  reward pool", usdc.balanceOf(stake), 6, "USDC");

        vm.selectFork(startingFork);
    }

    // ────────────────────────────────── helpers ──────────────────────────────────

    /// @dev `configId = keccak(account ‖ keccak(permissionId ‖ actionId))`. The operand order
    ///      matters at every level; see `Gauntlet._configId` for the full account.
    function configId(address account) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(AddressBook.donut("UniversalGatewayPC"), SEND_OUTBOUND_SELECTOR));
        bytes32 pid = Ledger.word("permissionId", "14_GrantMandate");
        return ConfigId.wrap(keccak256(abi.encodePacked(account, keccak256(abi.encodePacked(pid, actionId)))));
    }
}
