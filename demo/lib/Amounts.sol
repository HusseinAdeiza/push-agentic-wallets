// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  Amounts
 * @notice The demo's money, in one place, with a scale knob for cheap rehearsals.
 *
 * @dev    WHY THIS EXISTS. The bridged amount, the per-action cap and the lifetime cap are not
 *         three independent numbers — they are one story told in three places:
 *
 *           bridge 100  ·  cap 50 per action  ·  cap 60 lifetime
 *
 *         The 50 is what lets ONE stake through. The 60 is what makes a SECOND stake fail while
 *         still leaving room for the 10 USDC reward to come home. Change one without the others and
 *         the gauntlet stops demonstrating what it claims: G4 and G5 both depend on the ratios, not
 *         on the absolute figures.
 *
 *         Spread across two scripts as separate constants, that invariant survives exactly until
 *         someone edits one file. Here it is arithmetic.
 *
 *         THE SCALE KNOB. `DEMO_SCALE_PERCENT` scales every figure together, so a rehearsal can run
 *         on a tenth of the capital and still exercise every gate and every cap. Unset means 100 —
 *         the real demo. The live run must always be 100; a scaled rehearsal proves the mechanism,
 *         not the numbers the audience will see.
 *
 *         Reads the environment on every call rather than caching, because a forge script is a
 *         fresh process and there is nothing to cache across.
 */
library Amounts {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Full-size figures, at 100%. USDC is 6 decimals on both chains.
    uint256 private constant FULL_BRIDGE = 100e6;
    uint256 private constant FULL_PER_CALL = 50e6;
    uint256 private constant FULL_TOTAL = 60e6;

    /// @dev What `StakeDummy.REWARD` pays on unstake. NOT scaled: it is a constant compiled into a
    ///      deployed contract, so a scaled rehearsal gets the same 10 USDC a full run does. That is
    ///      the one figure the knob cannot move, and callers computing an expected return must use
    ///      this rather than a fraction of it.
    uint256 internal constant REWARD = 10e6;

    /// @notice Percent scale, 1–100. Unset or 0 means 100 (full size).
    function scale() internal view returns (uint256) {
        return normalise(vm.envOr("DEMO_SCALE_PERCENT", uint256(0)));
    }

    /**
     * @notice Clamp a raw percent to a usable scale. PURE, and the reason the invariants are
     *         testable at all.
     *
     * @dev    `vm.setEnv` mutates the real process environment, which forge shares across tests
     *         running in the same process — so a test that sets it to 10 changes what a test
     *         asserting 100 observes, and the suite fails depending on ordering. Every invariant
     *         below is therefore asserted through this pure function, and only one thin test reads
     *         the environment at all.
     *
     * @param  pct Raw value; 0 or anything above 100 means "full size".
     */
    function normalise(uint256 pct) internal pure returns (uint256) {
        if (pct == 0 || pct > 100) return 100;
        return pct;
    }

    /// @notice The three figures at an explicit scale, bypassing the environment.
    function at(uint256 pct) internal pure returns (uint256 bridgeAmt, uint256 perCallAmt, uint256 totalAmt) {
        uint256 s = normalise(pct);
        return ((FULL_BRIDGE * s) / 100, (FULL_PER_CALL * s) / 100, (FULL_TOTAL * s) / 100);
    }

    /// @notice Whether this run is scaled down — worth saying on screen so nobody misreads a figure.
    function isScaled() internal view returns (bool) {
        return scale() != 100;
    }

    /// @notice What Bob bridges in.
    function bridge() internal view returns (uint256) {
        return _scaled(FULL_BRIDGE);
    }

    /// @notice The mandate's per-action ceiling. Half the bridged amount, always.
    function perCall() internal view returns (uint256) {
        return _scaled(FULL_PER_CALL);
    }

    /**
     * @notice The mandate's lifetime budget.
     *
     * @dev    Deliberately above `perCall` and below `2 * perCall`. That is what makes one stake
     *         pass and a second fail — G5's entire point — so the relationship is preserved at any
     *         scale.
     */
    function total() internal view returns (uint256) {
        return _scaled(FULL_TOTAL);
    }

    /// @dev Truncating division is fine: every figure is a round number of whole USDC at any scale
    ///      that divides evenly, and the ratios hold regardless.
    function _scaled(uint256 amount) private view returns (uint256) {
        return (amount * scale()) / 100;
    }
}
