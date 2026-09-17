// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeIds } from "../../lib/NativeIds.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  Stake
 * @notice ACT 2 · Chain: Donut · THE CENTRAL BEAT. The agent signs; the RELAYER submits.
 *
 * @dev    ONE SCRIPT, THREE ACTS. Parameterised by `STAKE_AMOUNT` (default 25e6) so that Act 2,
 *         Act 3b and Act 3c are the same code with a different number — which is also the honest
 *         way to show a budget being consumed, since nothing about the request changes except the
 *         amount.
 *
 *             just stake        # 25 - Act 2
 *             just stake 25     # 25 - Act 3b
 *             just stake 10     # 10 - Act 3c, lands exactly on the lifetime cap
 *
 *         WHAT THE AGENT SIGNS. The ten-field op hash covers the entire `executionCalldata` — the
 *         target, the value and every byte of the arguments down to the beneficiary word — plus the
 *         permission id, the lane and the expiry. Nothing in it can be substituted by a relayer.
 *
 *         THE RELAYER IS NOT AN AUTHORITY. It pays gas and nothing else; anyone could submit this.
 *         The signature is the authority. That separation is the point, so the script broadcasts
 *         with `PC_RELAYER_KEY` and says so on screen.
 *
 *         THE CALLDATA IS ONE LAYER DEEP. In the cross-chain demo the same intent needed four
 *         nested layers — an execution wrapping an outbound wrapping a multicall wrapping the
 *         actual call. Here it is `encodeSingle(stakeDummy, 0, stakeFor(wallet, amount))`, and the
 *         contract the agent names is the contract that runs.
 */
contract Stake is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the request");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer pays gas to submit it");

        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");
        bytes4 selector = StakeDummy.stakeFor.selector;

        uint256 amount = vm.envOr("STAKE_AMOUNT", Amounts.ACT2);

        ConfigId configId = NativeIds.configId(permissionId, agw, stake, selector);
        IURP urp = IURP(AddressBook.ours("urp"));
        IURP.NativeConfig memory before = urp.getNativeConfig(configId, agw);

        StakeDummy staking = StakeDummy(stake);
        uint256 stakedBefore = staking.totalBalance(agw);

        // Lane 0 — one lane per mandate. The sequence is read from the chain inside `build`.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk, agw, permissionId, 0, stake, abi.encodeCall(StakeDummy.stakeFor, (agw, amount)), amount
        );

        DemoLog.header("ACT 2", "The agent acts");
        DemoLog.line(DemoLog.bold("The agent asks to stake, crediting Bob's wallet."));
        DemoLog.money("  amount", amount, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.addrPlain("  target", stake);
        DemoLog.addrPlain("  beneficiary", agw);
        DemoLog.kv("  value", "0");
        DemoLog.kv("  lane / seq", string.concat("0 / ", vm.toString(uint256(req.nonceSeq))));
        DemoLog.note("      the sequence was read from the wallet, never cached");
        DemoLog.blank();

        vm.startBroadcast(relayerPk);
        NativeRequest.submit(req);
        vm.stopBroadcast();

        // ── READ EVERYTHING BACK FROM THE CHAIN ──
        //
        // Nothing here reports success because `forge script` exited zero. The native demo has no
        // enforced pause to make an operator check — so the check is built in.
        uint256 stakedAfter = staking.totalBalance(agw);
        IURP.NativeConfig memory afterCfg = urp.getNativeConfig(configId, agw);

        DemoLog.ok("landed", "in this transaction - no bridge, no relay, no waiting");
        DemoLog.blank();
        DemoLog.header("", "What the chain says");
        DemoLog.money("Staked, before", stakedBefore, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money("Staked, after", stakedAfter, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.blank();
        DemoLog.money("Budget spent", afterCfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.money(
            "Budget remaining", afterCfg.amount.maxTotal - afterCfg.amountSpent, Amounts.DECIMALS, Amounts.SYMBOL
        );
        DemoLog.kv(
            "Calls used",
            string.concat(vm.toString(uint256(afterCfg.callsUsed)), " of ", vm.toString(uint256(afterCfg.maxCalls)))
        );
        DemoLog.footer();

        require(stakedAfter == stakedBefore + amount, "the stake did not land on the wallet");
        require(afterCfg.amountSpent == before.amountSpent + amount, "URP did not meter the amount");
        require(afterCfg.callsUsed == before.callsUsed + 1, "URP did not count the call");
    }
}
