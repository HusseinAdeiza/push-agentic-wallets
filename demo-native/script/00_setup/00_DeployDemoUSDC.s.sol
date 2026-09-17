// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { DemoUSDC } from "../../contracts/DemoUSDC.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";

/**
 * @title  DeployDemoUSDC
 * @notice SETUP · Chain: Donut · broadcasts with the deployer key. Run at T-1 hour, off camera.
 *
 * @dev    Deploys the demo's own ERC-20. THE ADDRESS MUST BE PASTED INTO
 *         `deployments/address-book-v2/native_demo.json` under `DemoUSDC` before anything else
 *         runs — `AddressBook.native` enforces a never-zero rule, so the next script fails with a
 *         named `MissingAddress` rather than proceeding against `address(0)`.
 *
 *         WHY THE SCRIPT DOES NOT WRITE THE ADDRESS BOOK ITSELF. The address book is a permanent
 *         record under `deployments/`, not per-run state; the Ledger is what scripts write. A
 *         script that rewrites the address book would make a rehearsal silently repoint the demo at
 *         a fresh token, and the reward pool funded against the previous one would vanish with no
 *         error. One manual paste is the cost of that safety.
 */
contract DeployDemoUSDC is Script {
    function run() external {
        uint256 deployerPk = Keys.load("PRIVATE_KEY", "deploys the demo token");

        vm.startBroadcast(deployerPk);
        DemoUSDC token = new DemoUSDC();
        vm.stopBroadcast();

        DemoLog.header("SETUP", "The demo token");
        DemoLog.addrPlain("DemoUSDC", address(token));
        DemoLog.kv("Name", token.name());
        DemoLog.kv("Symbol", token.symbol());
        DemoLog.kv("Decimals", vm.toString(token.decimals()));
        DemoLog.blank();
        DemoLog.note("A DEMO token. Freely mintable, no owner. Deliberately NOT called 'USDC' -");
        DemoLog.note("the audience reads the explorer, and must not think real USDC is in play.");
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("NEXT: paste this address into"));
        DemoLog.line("  deployments/address-book-v2/native_demo.json  ->  .DemoUSDC");
        DemoLog.footer();

        // Sanity, read back from the chain rather than assumed from the constructor.
        require(token.decimals() == Amounts.DECIMALS, "decimals must be 6");
    }
}
