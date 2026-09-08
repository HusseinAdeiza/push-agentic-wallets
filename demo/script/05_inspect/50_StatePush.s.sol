// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Inspect } from "../../lib/Inspect.sol";

/// @title  StatePush
/// @notice Chain: Donut (read only) · never broadcasts. Run between acts.
/// @dev    The wallet and the mandate. The remaining-budget line is the one to watch move.
contract StatePush is Script {
    function run() external view {
        DemoLog.header("STATE", "Push Chain");
        Inspect.pushState();
        DemoLog.blank();
        Inspect.mandate();
        DemoLog.footer();
    }
}
