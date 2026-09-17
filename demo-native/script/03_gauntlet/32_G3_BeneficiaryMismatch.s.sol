// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { StakeDummy } from "../../contracts/StakeDummy.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  G3_BeneficiaryMismatch
 * @notice ACT 3 · G3 · ⚠️ THE DEMO'S THESIS. The agent asks to stake Bob's money to ITSELF.
 *
 * @dev    THIS IS THE ONE TO SLOW DOWN FOR. Everything else in the gauntlet is supporting evidence.
 *
 *         WHAT THE AGENT IS ACTUALLY ATTEMPTING, and it is worth saying in full rather than
 *         calling it "a word mismatch":
 *
 *           `StakeDummy.unstake()` pays `totalBalance[msg.sender]` to `msg.sender`. Had this
 *           request succeeded, the stake would be credited to the AGENT's address — and the agent
 *           could then call `unstake()` DIRECTLY FROM ITS OWN EOA, under no mandate at all, not
 *           through the wallet, and walk away with the principal plus the 10 dUSDC reward.
 *
 *         So G3 is not a formality. It is the agent trying to make the wallet fund a position that
 *         only the agent can withdraw. One word of calldata is different; the pin catches it.
 *
 *         IT ALSO EXPLAINS WHY THE PIN IS NOT OPTIONAL FOR AN HONEST AGENT. Without it, a stake
 *         credited to the wrong address means THE WALLET ITSELF could never unstake — the funds
 *         would sit under an address the wallet cannot act as.
 *
 *         Refused by URP gate N7, wrapped by the engine, arguments truncated to 32 bytes.
 */
contract G3_BeneficiaryMismatch is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent signs the mutated request");
        address agent = vm.addr(agentPk);
        address agw = Ledger.addr("agw", "10_DeployWallet");
        bytes32 permissionId = Ledger.word("permissionId", "13_GrantMandate");
        address stake = AddressBook.native("StakeDummy");

        // THE ONE MUTATION: the beneficiary word. Same contract, same function, same amount, same
        // lane — and a valid signature over all of it.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            agw,
            permissionId,
            0,
            stake,
            abi.encodeCall(StakeDummy.stakeFor, (agent, Amounts.ACT2)),
            Amounts.ACT2
        );

        DemoLog.header("G3", unicode"The agent stakes to ITSELF ← the one that matters");
        DemoLog.addrPlain("Mandate pins", agw);
        DemoLog.addrPlain("Request says", agent);
        DemoLog.note("    Identical in every other respect. One word of calldata differs.");
        DemoLog.blank();

        string memory title = string.concat(
            "stakeFor(agent, ",
            DemoLog.formatAmount(Amounts.ACT2, Amounts.DECIMALS, Amounts.SYMBOL),
            ") - the beneficiary is the agent, not the wallet"
        );

        NativeGauntlet.refuseGate(
            title,
            IURP.ArgPinMismatch.selector,
            "Without this pin the agent could then call unstake() from its OWN EOA - under no mandate - and keep principal and reward.",
            req
        );

        DemoLog.footer();
    }
}
