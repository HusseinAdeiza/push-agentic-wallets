// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  AgentTransferFails
 * @notice ACT 4b · The agent tries to move the money OUT of the wallet.
 *
 * @dev    THE MOST DIRECT ATTACK IN THE DEMO, and the shortest to explain: the wallet now holds the
 *         principal plus the reward, and the agent asks it to transfer that to the agent.
 *
 *         REFUSED BY THE ENGINE, LIKE G1 — and the script says so. `transfer` on `DemoUSDC` is a
 *         `(target, selector)` pair that appears in NO mandate, so there is no action id and no
 *         policy to consult. The agent was given two verbs, `stakeFor` and `unstake`, and
 *         `transfer` is simply not one of them.
 *
 *         THE ONE-LINE VERSION, worth saying aloud: the agent can move money IN, and it can bring
 *         money BACK — it was never given any way to move money OUT.
 */
contract AgentTransferFails is Script {
    bytes4 internal constant NO_POLICIES_SET = bytes4(keccak256("NoPoliciesSet(bytes32)"));

    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent attempts a transfer");
        address agent = vm.addr(agentPk);
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        uint256 walletHolds = token.balanceOf(agw);

        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            agw,
            permissionId,
            0,
            address(token),
            abi.encodeCall(IERC20.transfer, (agent, walletHolds)),
            walletHolds
        );

        DemoLog.header("ACT 4b", "The agent tries to take the money");
        DemoLog.money("Wallet holds", walletHolds, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.addrPlain("Agent wants it sent to", agent);
        DemoLog.blank();

        NativeGauntlet.refuseRaw(
            "transfer() of the wallet's entire balance, to the agent",
            NO_POLICIES_SET,
            "the engine",
            "The agent can move money IN, and bring it BACK. It was never given any way to move it OUT.",
            req
        );

        // The balance is unchanged — asserted, not assumed.
        uint256 stillHolds = token.balanceOf(agw);
        DemoLog.money("Wallet still holds", stillHolds, Amounts.DECIMALS, Amounts.SYMBOL);
        DemoLog.footer();

        require(stillHolds == walletHolds, "the wallet's balance moved");
    }
}
