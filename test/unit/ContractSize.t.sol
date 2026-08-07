// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy } from "../../src/policies/ACPActionPolicy.sol";
import { SmartSession } from "smartsessions/SmartSession.sol";

/// @notice EIP-170 guard for every contract we deploy.
contract ContractSizeTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;

    function _size(address a) internal view returns (uint256 s) {
        assembly {
            s := extcodesize(a)
        }
    }

    function test_ourContractsFitUnderEIP170() public {
        assertLt(
            _size(
                address(
                    new PushAgentWallet(
                        address(0x5511), address(0x6A7E), address(0xAC90), address(0x71FE), address(0x0A11)
                    )
                )
            ),
            EIP170_LIMIT,
            "PushAgentWallet"
        );
        assertLt(_size(address(new AgentWalletFactory(address(0x1)))), EIP170_LIMIT, "AgentWalletFactory");
        assertLt(_size(address(new PushSessionValidator())), EIP170_LIMIT, "PushSessionValidator");
        assertLt(_size(address(new ACPActionPolicy(address(0x1)))), EIP170_LIMIT, "ACPActionPolicy");
    }

    /**
     * D-5 RESOLVED — SmartSession now fits.
     *
     * At the PRD's original `optimizer_runs = 99999` it compiled to 28,737 B, i.e.
     * 4,161 B over EIP-170 and undeployable, which conflicted with §4.1's
     * requirement to deploy it unmodified. `optimizer_runs` is now 833 — the setting
     * smartsessions is built and audited at upstream — giving 22,581 B.
     *
     * This assertion is the guard: if `optimizer_runs` is ever raised again,
     * SmartSession silently becomes undeployable and this test catches it.
     */
    function test_allDeployedContractsFitUnderEIP170() public {
        uint256 size = _size(address(new SmartSession()));
        emit log_named_uint("SmartSession runtime size", size);
        assertLt(size, EIP170_LIMIT, "SmartSession must fit; check optimizer_runs (see DEVIATIONS D-5)");
    }
}
