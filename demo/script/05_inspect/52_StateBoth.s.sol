// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Inspect } from "../../lib/Inspect.sol";

/**
 * @title  StateBoth
 * @notice Chain: both (read only) · never broadcasts. THE ONE TO RUN BETWEEN ACTS.
 *
 * @dev    Both sides in one screen, so the audience can see capital move from Push Chain to Sepolia
 *         and back without holding two terminals in their head.
 *
 *         Run it before Act 2 and after every act. The story is told by three numbers changing:
 *         what the wallet holds, what is staked on Sepolia, and how much budget remains.
 */
contract StateBoth is Script {
    function run() external {
        DemoLog.header("STATE", "Both chains");
        Inspect.pushState();
        DemoLog.blank();
        Inspect.mandate();
        DemoLog.blank();
        Inspect.sepoliaState();
        DemoLog.footer();
    }
}
