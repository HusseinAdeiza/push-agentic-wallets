// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { DemoLog } from "../lib/DemoLog.sol";

/**
 * @title  DemoLogTest
 * @notice Formatting is the demo's only interface, so it is tested like everything else.
 *
 * @dev    THE RULE BEING ENFORCED: every amount printed is human-readable. `50.00 USDC`, never
 *         `50000000`. An audience cannot parse six decimal places at speed, and a demo whose
 *         terminal reads like a debug session makes a sophisticated system look unfinished.
 *
 *         The regression this file exists to prevent is real and was caught live: with a fixed two
 *         decimal places, every native-PC amount rendered as `0.00 PC` — a gas fee, a gas budget
 *         and a per-call cap all printing identically as zero, which is worse than raw integers
 *         because it looks authoritative while conveying nothing.
 */
contract DemoLogTest is Test {
    // ─────────────────── money at human scale: two decimals ───────────────────

    function test_money_usdcReadsAsMoney() public pure {
        assertEq(DemoLog.formatAmount(50e6, 6, "USDC"), "50.00 USDC");
        assertEq(DemoLog.formatAmount(60e6, 6, "USDC"), "60.00 USDC");
        assertEq(DemoLog.formatAmount(100e6, 6, "USDC"), "100.00 USDC");
    }

    /// @dev The demo's closing number, and the last thing the audience sees.
    function test_money_closingBalance() public pure {
        assertEq(DemoLog.formatAmount(110e6, 6, "USDC"), "110.00 USDC");
    }

    function test_money_thousandsSeparators() public pure {
        assertEq(DemoLog.formatAmount(1000e6, 6, "USDC"), "1,000.00 USDC");
        assertEq(DemoLog.formatAmount(1234567e6, 6, "USDC"), "1,234,567.00 USDC");
    }

    function test_money_wholeNativeUnits() public pure {
        assertEq(DemoLog.formatAmount(20 ether, 18, "PC"), "20.00 PC");
        assertEq(DemoLog.formatAmount(50 ether, 18, "PC"), "50.00 PC");
    }

    // ────────────────── sub-unit amounts: six decimals ──────────────────

    /**
     * @dev THE REGRESSION GUARD. A live quote returns a gas fee around 0.00058 PC and a per-call
     *      cap around 0.0035 PC. At two decimal places all three quote lines print `0.00 PC` and
     *      the arithmetic on screen cannot be checked at all.
     */
    function test_money_subUnitAmountsAreNotFlattenedToZero() public pure {
        string memory gasFee = DemoLog.formatAmount(581_932_481_000_000, 18, "PC");
        string memory msgValue = DemoLog.formatAmount(1_163_864_962_000_000, 18, "PC");
        string memory cap = DemoLog.formatAmount(3_491_594_886_000_000, 18, "PC");

        assertEq(gasFee, "0.000581 PC");
        assertEq(msgValue, "0.001163 PC");
        assertEq(cap, "0.003491 PC");

        // The property that actually matters: three different amounts must read differently.
        assertTrue(keccak256(bytes(gasFee)) != keccak256(bytes(msgValue)), "fee and value distinguishable");
        assertTrue(keccak256(bytes(msgValue)) != keccak256(bytes(cap)), "value and cap distinguishable");
    }

    /// @dev Fractions are zero-padded, so magnitudes line up in the column rather than misreading.
    function test_money_fractionsArePadded() public pure {
        assertEq(DemoLog.formatAmount(500_000, 6, "USDC"), "0.500000 USDC");
        assertEq(DemoLog.formatAmount(1, 18, "PC"), "0.000000 PC");
    }

    /// @dev A genuine zero has nothing to reveal, so it keeps the compact form.
    function test_money_zeroStaysCompact() public pure {
        assertEq(DemoLog.formatAmount(0, 18, "PC"), "0.00 PC");
        assertEq(DemoLog.formatAmount(0, 6, "USDC"), "0.00 USDC");
    }

    /// @dev Truncates rather than rounds: a displayed figure is never larger than the real one.
    function test_money_truncatesNeverRoundsUp() public pure {
        assertEq(DemoLog.formatAmount(50_999_999, 6, "USDC"), "50.99 USDC");
    }

    function test_money_symbolIsOptional() public pure {
        assertEq(DemoLog.formatAmount(50e6, 6, ""), "50.00");
    }

    /// @dev Six-decimal tokens cannot show more than six places; the request is clamped, not
    ///      allowed to underflow the exponent.
    function test_money_lowPrecisionTokensDoNotUnderflow() public pure {
        assertEq(DemoLog.formatAmount(5, 6, "USDC"), "0.000005 USDC");
        assertEq(DemoLog.formatAmount(3, 2, "X"), "0.03 X");
        assertEq(DemoLog.formatAmount(7, 0, "WEI"), "7 WEI");
    }
}
