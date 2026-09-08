// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { DemoLog } from "../lib/DemoLog.sol";

/**
 * @title  Demo101
 * @notice A VISUAL MOCK. Nothing here touches a chain, signs anything, or asserts anything.
 *
 * @dev    WHAT THIS IS FOR: showing the team the shape of the demo before the demo exists. It
 *         renders the title card, the cast of addresses and a simulated deployment sequence, so a
 *         standup audience can see where this is heading.
 *
 *         WHAT IT IS NOT: any part of the real demo. The real scripts live in `00_setup/`
 *         through `04_boundary/`, they broadcast, and every number they print is read from a chain.
 *         The progress lines below are `sleep`-free theatre driven by a loop counter.
 *
 *         THE ADDRESSES ARE REAL, and deliberately so — they are read from the address book rather
 *         than typed in, so the card cannot drift from the live deployment and nobody in the room
 *         is shown a fake address. The wallet and CEA rows are the exception and are labelled as
 *         projections, because those are derived per-user and no user has arrived yet.
 *
 *         Run:  forge script demo/script/Demo101.s.sol:Demo101
 */
contract Demo101 is Script {
    /// @dev Bar geometry. `STEPS * STEP_WIDTH == TOTAL_WIDTH`, so the last step lands exactly full.
    uint256 private constant STEPS = 7;
    uint256 private constant STEP_WIDTH = 4;
    uint256 private constant TOTAL_WIDTH = 28;

    /// @dev Bob's address is not in the address book — he is a person, not a deployment. Read from
    ///      the env when present so the card matches whoever is being demoed, with a clearly
    ///      illustrative fallback so the script never fails in front of an audience.
    function _bob() private view returns (address, bool) {
        address fromEnv = vm.envOr("DEMO_BOB", address(0));
        if (fromEnv != address(0)) return (fromEnv, true);
        return (0x778Bd9d8a9ceEAD086048BB59d7eab95c3AcD169, false);
    }

    function run() external view {
        _title();
        _cast();
        _mandate();
        _deploySequence();
        _closing();
    }

    // ───────────────────────────────── title ─────────────────────────────────

    function _title() private view {
        console.log("");
        console.log(
            DemoLog.cyan(
                unicode"  ██████╗ ██╗   ██╗███████╗██╗  ██╗     █████╗  ██████╗ ██╗    ██╗"
            )
        );
        console.log(
            DemoLog.cyan(
                unicode"  ██╔══██╗██║   ██║██╔════╝██║  ██║    ██╔══██╗██╔════╝ ██║    ██║"
            )
        );
        console.log(
            DemoLog.cyan(
                unicode"  ██████╔╝██║   ██║███████╗███████║    ███████║██║  ███╗██║ █╗ ██║"
            )
        );
        console.log(
            DemoLog.cyan(
                unicode"  ██╔═══╝ ██║   ██║╚════██║██╔══██║    ██╔══██║██║   ██║██║███╗██║"
            )
        );
        console.log(
            DemoLog.cyan(
                unicode"  ██║     ╚██████╔╝███████║██║  ██║    ██║  ██║╚██████╔╝╚███╔███╔╝"
            )
        );
        console.log(
            DemoLog.cyan(
                unicode"  ╚═╝      ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝  ╚═╝ ╚═════╝  ╚══╝╚══╝ "
            )
        );
        console.log("");
        console.log(DemoLog.bold(unicode"        Agentic Wallets  ·  Push Chain Donut  ⇄  Ethereum Sepolia"));
        console.log(DemoLog.dim(unicode"        one mandate  ·  one agent key  ·  zero custody"));
        console.log("");
    }

    // ───────────────────────────────── the cast ─────────────────────────────────

    function _cast() private view {
        (address bob, bool fromEnv) = _bob();

        DemoLog.header("", "The cast");
        DemoLog.addrPlain("Bob (user)", bob);
        DemoLog.note(
            fromEnv
                ? "    Ethereum only. Never holds a Push Chain key."
                : "    Ethereum only. Never holds a Push Chain key.  [illustrative]"
        );
        DemoLog.addrPlain("Agent key", 0x643C33097121F65Bc58786b038523a4E9EA13405);
        DemoLog.note(unicode"    Signs requests. Holds nothing, owns nothing.");
        DemoLog.addrPlain("Relayer", 0x2348286F118810521497ADBbF2615D1328aa1630);
        DemoLog.note(unicode"    Pays gas. No authority whatsoever - anyone could.");
        DemoLog.footer();
        console.log("");

        DemoLog.header("", "Deployed on Push Chain Donut (42101)");
        DemoLog.addrPlain("AGW Factory", AddressBook.ours("factoryProxy"));
        DemoLog.addrPlain("Wallet impl", AddressBook.ours("walletImplementation"));
        DemoLog.addrPlain("UCEP policy", AddressBook.ours("ucep"));
        DemoLog.addrPlain("Validator", AddressBook.ours("sessionValidator"));
        DemoLog.addrPlain("Session engine", AddressBook.ours("sessionEngine"));
        DemoLog.blank();
        DemoLog.addrPlain("Gateway", AddressBook.donut("UniversalGatewayPC"));
        DemoLog.addrPlain("pUSDC", AddressBook.donut("PRC20_USDC"));
        DemoLog.footer();
        console.log("");

        DemoLog.header("", "Target on Ethereum Sepolia (11155111)");
        DemoLog.addrPlain("StakeDummy", AddressBook.sepolia("StakeDummy"));
        DemoLog.note(unicode"    The protocol the agent is allowed to use. Live, verified.");
        DemoLog.addrPlain("USDC", AddressBook.sepolia("USDC"));
        DemoLog.footer();
        console.log("");
    }

    // ─────────────────────────────── the mandate ───────────────────────────────

    function _mandate() private view {
        DemoLog.header("", "The mandate");
        DemoLog.line(DemoLog.bold("This agent key may:"));
        DemoLog.line(unicode"  · stakeFor()  on StakeDummy");
        DemoLog.note(unicode"      ...but only ever for Bob's own account");
        DemoLog.line(unicode"  · unstake()   on StakeDummy");
        DemoLog.blank();
        DemoLog.kv("Per action", DemoLog.bold("50.00 USDC"));
        DemoLog.kv("Lifetime", DemoLog.bold("60.00 USDC"));
        DemoLog.kv("Expires", DemoLog.bold("7 days"));
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Nothing else. No other contract, no other function,"));
        DemoLog.line(DemoLog.dim("no other beneficiary, no other chain."));
        DemoLog.footer();
        console.log("");
    }

    // ──────────────────────────── the fake deployment ────────────────────────────

    function _deploySequence() private view {
        DemoLog.header("", "Deploying agentic wallet");

        _step(1, unicode"Resolving Bob's universal account", "UEAFactory.computeUEA");
        _step(2, unicode"Predicting wallet address", "AGWFactory.predictWallet");
        _step(3, unicode"Bridging 100.00 USDC from Sepolia", "sendUniversalTx");
        _step(4, unicode"Deploying agent wallet clone", "deployWallet");
        _step(5, unicode"Installing session engine", "SmartSession");
        _step(6, unicode"Arming gateway allowance", "approve(max)");
        _step(7, unicode"Granting the mandate", "grantMandate");

        DemoLog.blank();
        DemoLog.ok("wallet live", DemoLog.bold("funded, armed, mandated"));
        DemoLog.footer();
        console.log("");
    }

    /// @dev One progress line: a tick, the step, the call behind it, and a bar that grows with `n`.
    ///      `forge script` prints once at the end rather than streaming, so the bars read as a
    ///      filling sequence down the block instead of animating in place.
    function _step(uint256 n, string memory what, string memory how) private view {
        DemoLog.line(
            string.concat(DemoLog.green(unicode"✓ "), _padRight(what, 38), DemoLog.dim(string.concat("[", how, "]")))
        );
        DemoLog.line(string.concat("  ", _bar(n * STEP_WIDTH, TOTAL_WIDTH), _pct(n)));
    }

    /// @dev A part-filled bar: filled segment bright, remainder dim, so progress is legible.
    function _bar(uint256 filled, uint256 width) private view returns (string memory) {
        if (filled > width) filled = width;
        string memory on = "";
        string memory off = "";
        for (uint256 i; i < filled; ++i) {
            on = string.concat(on, unicode"━");
        }
        for (uint256 i = filled; i < width; ++i) {
            off = string.concat(off, unicode"╌");
        }
        return string.concat(DemoLog.cyan(on), DemoLog.dim(off));
    }

    /// @dev The trailing percentage, so the bar is readable even with colour stripped.
    function _pct(uint256 n) private view returns (string memory) {
        uint256 p = (n * 100) / STEPS;
        return DemoLog.dim(string.concat("  ", vm.toString(p), "%"));
    }

    /// @dev Pad a label so the bracketed call names line up in a column.
    function _padRight(string memory s, uint256 width) private view returns (string memory) {
        uint256 visible;
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (uint8(b[i]) & 0xC0 != 0x80) ++visible;
        }
        string memory out = DemoLog.bold(s);
        for (uint256 i = visible; i < width; ++i) {
            out = string.concat(out, " ");
        }
        return out;
    }

    // ─────────────────────────────── the closing ───────────────────────────────

    function _closing() private view {
        DemoLog.header("", "What the full demo shows");
        DemoLog.line(string.concat(DemoLog.green(unicode"  1  "), "Bob arrives from Ethereum in one transaction"));
        DemoLog.line(string.concat(DemoLog.green(unicode"  2  "), "The agent stakes 50 USDC across the chain boundary"));
        DemoLog.line(
            string.concat(DemoLog.amber(unicode"  3  "), "Five attacks, five named refusals, none reach Sepolia")
        );
        DemoLog.line(string.concat(DemoLog.green(unicode"  4  "), "The agent earns. Only Bob can take the money home"));
        DemoLog.blank();
        DemoLog.kv("Bob ends with", DemoLog.bold("110.00 USDC"));
        DemoLog.note(unicode"    ...having started with 100, and never given up custody.");
        DemoLog.footer();
        console.log("");
        console.log(DemoLog.dim(unicode"  Mock render for standup. The real scripts broadcast; this one does not."));
        console.log("");
    }
}
