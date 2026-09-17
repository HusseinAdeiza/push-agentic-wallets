// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IURP } from "../../../src/interfaces/IURP.sol";

import { AddressBook } from "../../lib/AddressBook.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { NativeGauntlet } from "../../lib/NativeGauntlet.sol";
import { NativeRequest } from "../../lib/NativeRequest.sol";

/**
 * @title  PinnedApproveRefuses
 * @notice ACT 4f (5 of 5) · The identical request that succeeded, now refused.
 *
 * @dev    THE CLOSING COMPARISON, AND THE POINT OF THE WHOLE ACT.
 *
 *         `49_AccompliceDrains` sent exactly this request — approve the accomplice — and it went
 *         through. Same wallet, same agent, same token, same function, same amount, same signing
 *         procedure. The ONLY thing that changed is that the mandate now names which spender is
 *         permitted.
 *
 *         WHAT THE AUDIENCE SHOULD LEAVE KNOWING:
 *
 *             The system enforces the mandate exactly as written. Writing a bad mandate is
 *             possible, and the tooling that composes mandates is what prevents it. A demo that
 *             implies the contract will save you from a badly written mandate is selling something
 *             the contract does not do.
 *
 *         This is not a weakness being confessed — it is the correct division of responsibility.
 *         URP cannot know which arguments matter to a user's intent; only the thing that composed
 *         the mandate can. What URP guarantees is that whatever WAS written will be enforced
 *         exactly, every time, without trusting the agent.
 */
contract PinnedApproveRefuses is Script {
    function run() external {
        uint256 agentPk = Keys.load("AGENT_KEY", "the agent attempts the same approval again");
        address accomplice = Keys.addressOf("PC_RELAYER_KEY", "the same accomplice as before");
        address wallet = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
        bytes32 permissionId = Ledger.word("pinnedApprovePermissionId", "4A_GrantPinnedApprove");
        address stake = AddressBook.native("StakeDummy");
        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        // THE IDENTICAL REQUEST from Act 4f (3 of 5). Lane 1 — the pinned mandate's own lane.
        NativeRequest.Built memory req = NativeRequest.build(
            agentPk,
            wallet,
            permissionId,
            1,
            address(token),
            abi.encodeCall(IERC20.approve, (accomplice, Amounts.THROWAWAY_FUND)),
            Amounts.THROWAWAY_FUND
        );

        DemoLog.header("ACT 4f", "The same request, refused");
        DemoLog.addrPlain("Mandate permits", stake);
        DemoLog.addrPlain("Request names", accomplice);
        DemoLog.note("    Byte-for-byte the request that drained the wallet two steps ago.");
        DemoLog.blank();

        NativeGauntlet.refuseGate(
            _title(),
            IURP.ArgPinMismatch.selector,
            "The contract enforces the mandate as written. Pinning is the SDK's obligation - and this is what it buys.",
            req
        );

        DemoLog.header("", "What Act 4f proves");
        DemoLog.line(DemoLog.bold("The system enforces the mandate exactly as written."));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Writing a bad mandate is possible. The tooling that composes"));
        DemoLog.line(DemoLog.dim("mandates is what prevents it - not the contract, which cannot"));
        DemoLog.line(DemoLog.dim("know which arguments matter to a user's intent."));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("What URP guarantees: whatever WAS written is enforced exactly,"));
        DemoLog.line(DemoLog.dim("every time, without ever trusting the agent."));
        DemoLog.footer();
    }

    /// @dev Split out for STACK DEPTH, matching G4. The amount comes from `Amounts`, never a
    ///      hardcoded literal — the first live run printed "20" while sending 8.
    function _title() private view returns (string memory) {
        return string.concat(
            "approve(accomplice, ",
            DemoLog.formatAmount(Amounts.THROWAWAY_FUND, Amounts.DECIMALS, Amounts.SYMBOL),
            ") - under the mandate that pins the spender"
        );
    }
}
