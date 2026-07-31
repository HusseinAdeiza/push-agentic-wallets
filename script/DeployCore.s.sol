// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";
import { PushAgentWallet } from "../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../src/AgentWalletFactory.sol";

/**
 * @title DeployCore
 * @notice PRD §10.2 items 1–2: the wallet implementation and its factory.
 * @dev    The implementation is initialized to 0xdead immediately after deployment
 *         so nobody can initialize the logic contract directly (attack A-13).
 */
contract DeployCore is Script {
    address internal constant DEAD = address(0xdead);

    function run() external returns (address implementation, address factory) {
        string memory network = vm.envOr("NETWORK", string("anvil"));

        vm.startBroadcast();

        PushAgentWallet impl = new PushAgentWallet();
        implementation = address(impl);

        // A-13 — burn the implementation's initializer.
        impl.initialize(DEAD);

        AgentWalletFactory f = new AgentWalletFactory(implementation);
        factory = address(f);

        vm.stopBroadcast();

        // Assert the implementation can never be re-initialized.
        require(impl.owner() == DEAD, "implementation not sealed");
        (bool ok,) = implementation.call(abi.encodeCall(PushAgentWallet.initialize, (address(1))));
        require(!ok, "implementation must reject a second initialize");

        console.log("PushAgentWallet implementation:", implementation);
        console.log("AgentWalletFactory:           ", factory);

        _write(network, implementation, factory);
    }

    function _write(string memory network, address implementation, address factory) internal {
        string memory json = string.concat(
            '{\n  "pushAgentWalletImplementation": "',
            vm.toString(implementation),
            '",\n  "agentWalletFactory": "',
            vm.toString(factory),
            '"\n}\n'
        );
        vm.writeFile(string.concat("deployments/", network, ".json"), json);
    }
}
