// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";

import { PushSessionValidator } from "../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy } from "../src/policies/ACPActionPolicy.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { ERC20SpendingLimitPolicy } from "smartsessions/external/policies/ERC20SpendingLimitPolicy.sol";
import { TimeFramePolicy } from "smartsessions/external/policies/TimeFramePolicy.sol";
import { ValueLimitPolicy } from "smartsessions/external/policies/ValueLimitPolicy.sol";
import { UsageLimitPolicy } from "smartsessions/external/policies/UsageLimitPolicy.sol";
import { ContractWhitelistPolicy } from "smartsessions/external/policies/ContractWhitelistPolicy.sol";

/**
 * @title DeployModules
 * @notice PRD §10.2 items 3–10: the session engine, our validator, the adopted
 *         policies, and ACPActionPolicy.
 * @dev    UNIVERSAL_GATEWAY_PC is a deployment input — supply it via the
 *         UNIVERSAL_GATEWAY_PC env var. It becomes immutable in ACPActionPolicy.
 */
contract DeployModules is Script {
    struct Deployed {
        address smartSession;
        address pushSessionValidator;
        address erc20SpendingLimitPolicy;
        address timeFramePolicy;
        address valueLimitPolicy;
        address usageLimitPolicy;
        address contractWhitelistPolicy;
        address acpActionPolicy;
    }

    function run() external returns (Deployed memory d) {
        string memory network = vm.envOr("NETWORK", string("anvil"));
        address gatewayPC = vm.envAddress("UNIVERSAL_GATEWAY_PC");
        require(gatewayPC != address(0), "UNIVERSAL_GATEWAY_PC required");

        vm.startBroadcast();

        d.smartSession = address(new SmartSession());
        d.pushSessionValidator = address(new PushSessionValidator());
        d.erc20SpendingLimitPolicy = address(new ERC20SpendingLimitPolicy());
        d.timeFramePolicy = address(new TimeFramePolicy());
        d.valueLimitPolicy = address(new ValueLimitPolicy());
        d.usageLimitPolicy = address(new UsageLimitPolicy());
        d.contractWhitelistPolicy = address(new ContractWhitelistPolicy());
        d.acpActionPolicy = address(new ACPActionPolicy(gatewayPC));

        vm.stopBroadcast();

        console.log("SmartSession:             ", d.smartSession);
        console.log("PushSessionValidator:     ", d.pushSessionValidator);
        console.log("ERC20SpendingLimitPolicy: ", d.erc20SpendingLimitPolicy);
        console.log("TimeFramePolicy:          ", d.timeFramePolicy);
        console.log("ValueLimitPolicy:         ", d.valueLimitPolicy);
        console.log("UsageLimitPolicy:         ", d.usageLimitPolicy);
        console.log("ContractWhitelistPolicy:  ", d.contractWhitelistPolicy);
        console.log("ACPActionPolicy:          ", d.acpActionPolicy);

        _write(network, d);
    }

    function _write(string memory network, Deployed memory d) internal {
        string memory json = string.concat(
            '{\n  "smartSession": "',
            vm.toString(d.smartSession),
            '",\n  "pushSessionValidator": "',
            vm.toString(d.pushSessionValidator),
            '",\n  "erc20SpendingLimitPolicy": "',
            vm.toString(d.erc20SpendingLimitPolicy),
            '",\n  "timeFramePolicy": "',
            vm.toString(d.timeFramePolicy),
            '",\n  "valueLimitPolicy": "',
            vm.toString(d.valueLimitPolicy),
            '",\n  "usageLimitPolicy": "',
            vm.toString(d.usageLimitPolicy),
            '",\n  "contractWhitelistPolicy": "',
            vm.toString(d.contractWhitelistPolicy),
            '",\n  "acpActionPolicy": "',
            vm.toString(d.acpActionPolicy),
            '"\n}\n'
        );
        vm.writeFile(string.concat("deployments/", network, "-modules.json"), json);
    }
}
