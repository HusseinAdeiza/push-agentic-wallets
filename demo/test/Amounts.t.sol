// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Amounts } from "../lib/Amounts.sol";

/**
 * @title  AmountsTest
 * @notice The demo's money is three figures telling one story; these are the invariants that make
 *         the story hold at any scale.
 *
 * @dev    THE TWO RELATIONSHIPS THAT MATTER, and why the gauntlet dies without them:
 *
 *           · `perCall < bridge`               — otherwise one action drains the wallet and G4 has
 *                                                nothing to demonstrate.
 *           · `perCall <= total < 2 * perCall` — the whole mechanism of G5: one stake fits inside
 *                                                the lifetime budget, a second cannot.
 *
 *         Absolute figures are cosmetic. These ratios are the demo.
 *
 *         ASSERTED THROUGH THE PURE `at()`, NOT THROUGH THE ENVIRONMENT. `vm.setEnv` mutates the
 *         real process environment, which forge shares across tests in the same process — an
 *         earlier version of this file set the scale per test and failed depending on ordering,
 *         with each test passing in isolation. Only one test below touches the environment, and it
 *         asserts nothing that another test's value could disturb.
 */
contract AmountsTest is Test {
    function test_fullScaleIsTheSpecFigures() public pure {
        (uint256 bridge, uint256 perCall, uint256 total) = Amounts.at(100);
        assertEq(bridge, 100e6, "bridge 100 USDC");
        assertEq(perCall, 50e6, "50 per action");
        assertEq(total, 60e6, "60 lifetime");
    }

    function test_tenPercentScalesEverythingTogether() public pure {
        (uint256 bridge, uint256 perCall, uint256 total) = Amounts.at(10);
        assertEq(bridge, 10e6, "10 USDC bridged");
        assertEq(perCall, 5e6, "5 per action");
        assertEq(total, 6e6, "6 lifetime");
    }

    /// @dev Unset and out-of-range must both mean full size — never a silently shrunken demo.
    function test_zeroAndOutOfRangeMeanFullSize() public pure {
        assertEq(Amounts.normalise(0), 100, "unset is full size");
        assertEq(Amounts.normalise(101), 100, "above 100 is full size");
        assertEq(Amounts.normalise(type(uint256).max), 100, "nonsense is full size");
        assertEq(Amounts.normalise(10), 10, "a valid scale passes through");
    }

    /// @dev G4's precondition: a single action can never spend the whole balance.
    function testFuzz_perCallIsAlwaysBelowBridge(uint256 pct) public pure {
        (uint256 bridge, uint256 perCall,) = Amounts.at(bound(pct, 1, 100));
        assertLt(perCall, bridge, "one action cannot drain the wallet");
    }

    /// @dev G5's precondition, and the sharper of the two.
    function testFuzz_oneStakeFitsAndASecondDoesNot(uint256 pct) public pure {
        (, uint256 perCall, uint256 total) = Amounts.at(bound(pct, 1, 100));
        assertLe(perCall, total, "one stake fits inside the lifetime budget");
        assertLt(total, 2 * perCall, "a second stake must exceed it");
    }

    /// @dev Nothing may round to zero, or a "successful" run would move no money at all.
    function testFuzz_nothingRoundsToZero(uint256 pct) public pure {
        (uint256 bridge, uint256 perCall, uint256 total) = Amounts.at(bound(pct, 1, 100));
        assertGt(bridge, 0, "bridge non-zero");
        assertGt(perCall, 0, "per-call non-zero");
        assertGt(total, 0, "total non-zero");
    }

    /**
     * @dev The reward is a constant in DEPLOYED bytecode and does not scale. At small scales the
     *      returned amount therefore exceeds the lifetime budget — harmless, because the return leg
     *      is a zero-amount request that meters nothing, but a real trap for anyone computing an
     *      expected closing balance as a fraction of the bridged figure.
     */
    function test_rewardDoesNotScale() public pure {
        assertEq(Amounts.REWARD, 10e6, "the deployed contract pays a flat 10 USDC at any scale");
    }

    /// @dev The only environment-reading test. Asserts the plumbing, not a specific figure, so it
    ///      cannot be disturbed by whatever another test has set.
    function test_environmentIsReadAndClamped() public view {
        uint256 s = Amounts.scale();
        assertGe(s, 1, "scale is at least 1");
        assertLe(s, 100, "scale never exceeds 100");
        assertEq(Amounts.isScaled(), s != 100, "isScaled agrees with scale");
    }
}
