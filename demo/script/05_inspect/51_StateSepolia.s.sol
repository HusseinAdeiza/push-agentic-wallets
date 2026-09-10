// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Inspect } from "../../lib/Inspect.sol";

/// @title  StateSepolia
/// @notice Chain: reads Sepolia · never broadcasts. Run after every cross-chain hop.
/// @dev    Where the capital actually is, and whether it is working.
contract StateSepolia is Script {
    function run() external {
        DemoLog.header("STATE", "Ethereum Sepolia");
        Inspect.sepoliaState();
        DemoLog.footer();
    }
}
