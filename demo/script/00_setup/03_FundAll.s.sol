// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";

/**
 * @title  FundAll
 * @notice Chain: Sepolia · broadcasts with Bob's key. T-1-hour setup, before `02_DeployStakeDummy`.
 *
 * @dev    BOB IS THE ONLY USDC SOURCE. He holds the demo's entire working capital, so the
 *         deployer's reward-pool share is transferred from him. There is no faucet step: the
 *         Sepolia USDC in play is Circle's FiatToken, whose `mint` is minter-gated, so tokens can
 *         only be moved, never created.
 *
 *         SEPOLIA ONLY. The relayer's PC and the AGW's PC are deliberately not handled here — the
 *         AGW does not exist until Act 1a, and `11_FundAGWWithPC` sends its 20 PC afterwards as a
 *         narrated demo beat rather than a silent setup step.
 *
 *         IDEMPOTENT. Re-running after the deployer already holds its share transfers nothing. A
 *         setup script that double-spends on a second run is a trap during rehearsals.
 */
contract FundAll is Script {
    error InsufficientUSDC(uint256 have, uint256 need);

    /// @dev The reward pool `02_DeployStakeDummy` will fund.
    uint256 internal constant DEPLOYER_SHARE = 100e6;

    /// @dev What Bob bridges in Act 1a. Checked, never transferred — it is already his.
    uint256 internal constant BOB_NEEDS = 100e6;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs the arrival and every owner action");
        address bob = vm.addr(bobPk);
        address deployer = Keys.addressOf("SEPOLIA_STAKE_DEPLOYER_KEY", "deploys and funds StakeDummy");
        IERC20 usdc = IERC20(AddressBook.sepolia("USDC"));

        DemoLog.header("SETUP", "Funding");

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 deplBefore = usdc.balanceOf(deployer);

        DemoLog.kv("", "before");
        DemoLog.money("Bob", bobBefore, 6, "USDC");
        DemoLog.money("Deployer", deplBefore, 6, "USDC");
        DemoLog.kv("Bob ETH", DemoLog.formatAmount(bob.balance, 18, "ETH"));
        DemoLog.kv("Deployer ETH", DemoLog.formatAmount(deployer.balance, 18, "ETH"));

        uint256 shortfall = deplBefore >= DEPLOYER_SHARE ? 0 : DEPLOYER_SHARE - deplBefore;

        if (shortfall == 0) {
            DemoLog.blank();
            DemoLog.ok("deployer", "already holds its share; nothing transferred");
        } else {
            if (bobBefore < shortfall + BOB_NEEDS) revert InsufficientUSDC(bobBefore, shortfall + BOB_NEEDS);

            vm.startBroadcast(bobPk);
            usdc.transfer(deployer, shortfall);
            vm.stopBroadcast();

            DemoLog.blank();
            DemoLog.kv("", "after");
            DemoLog.money("Bob", usdc.balanceOf(bob), 6, "USDC");
            DemoLog.money("Deployer", usdc.balanceOf(deployer), 6, "USDC");
            DemoLog.ok("transferred", string.concat(DemoLog.formatAmount(shortfall, 6, "USDC"), " Bob -> deployer"));
        }

        DemoLog.blank();
        DemoLog.note("Bob keeps 100 USDC for the arrival; the deployer's 100 becomes the reward pool.");
        DemoLog.footer();
    }
}
