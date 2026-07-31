// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy } from "../../src/policies/ACPActionPolicy.sol";
import { SmartSession } from "smartsessions/SmartSession.sol";

/// @notice Guards the EIP-170 limit for everything we deploy.
contract ContractSizeTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;

    function _size(address a) internal view returns (uint256 s) {
        assembly {
            s := extcodesize(a)
        }
    }

    function test_ourContractsFitUnderEIP170() public {
        assertLt(_size(address(new PushAgentWallet())), EIP170_LIMIT, "PushAgentWallet");
        assertLt(_size(address(new AgentWalletFactory(address(0x1)))), EIP170_LIMIT, "AgentWalletFactory");
        assertLt(_size(address(new PushSessionValidator())), EIP170_LIMIT, "PushSessionValidator");
        assertLt(_size(address(new ACPActionPolicy(address(0x1)))), EIP170_LIMIT, "ACPActionPolicy");
    }

    /**
     * ⚠ DEVIATIONS.md D-5 — SmartSession exceeds EIP-170 at the PRD-mandated
     * `optimizer_runs = 99999` (§3.2), which conflicts with §4.1's requirement to
     * deploy it unmodified.
     *
     * This test asserts the CURRENT measured reality so the conflict cannot be
     * lost. When D-5 is resolved (e.g. by lowering optimizer_runs), SmartSession
     * will fit and this test must be flipped to assertLt.
     */
    function test_D5_smartSessionExceedsEIP170AtMandatedOptimizerRuns() public {
        uint256 size = _size(address(new SmartSession()));
        assertGt(size, EIP170_LIMIT, "if this now fits, resolve D-5 and flip this assertion");
        emit log_named_uint("SmartSession runtime size", size);
        emit log_named_uint("bytes over EIP-170", size - EIP170_LIMIT);
    }
}
