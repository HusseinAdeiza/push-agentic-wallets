// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  Amounts
 * @notice THE PLAN IN ONE FILE. Every figure the native demo prints or sends comes from here.
 *
 * @dev    WHY CONSTANTS RATHER THAN A SCALE FACTOR. The cross-chain demo's `Amounts` is
 *         percentage-scaled, because its figures are bounded by a real bridged balance that varies
 *         between rehearsals. This demo mints its own token, so the numbers are chosen rather than
 *         negotiated — and a fixed set is what lets the manual print an expected counter value
 *         before the act runs.
 *
 *         THE ARITHMETIC IS LOAD-BEARING, NOT DECORATIVE. `PER_CALL` 25 and `TOTAL` 60 are chosen
 *         so that 25 + 25 + 10 exhausts the budget in three calls and leaves G7 (the lifetime cap)
 *         reachable in a live demo. Change either and the act plan stops working:
 *
 *           · Act 2  stakes ACT2  (25) -> amountSpent 25, callsUsed 1
 *           · Act 3b stakes ACT3B (25) -> amountSpent 50, callsUsed 2
 *           · Act 3c stakes ACT3C (10) -> amountSpent 60, callsUsed 3   <- budget exhausted
 *           · G7     requests    ( 1) -> N8 TotalNativeAmountExceeded(61e6, 60e6)
 *
 *         G8 (the call ceiling) deliberately lives on the UNSTAKE mandate, not here: N8 runs before
 *         N9, so a mandate cannot demonstrate both its lifetime cap and its call cap. See the
 *         build instruction's gauntlet section.
 */
library Amounts {
    // ─────────────────────────────── the mandate's caps ───────────────────────────────

    /// @notice `amount.maxPerCall` — the most the agent may stake in one call.
    uint256 internal constant PER_CALL = 25e6;

    /// @notice `amount.maxTotal` — the lifetime budget, and the owner's approval (they are equal
    ///         on purpose; see `APPROVAL`).
    uint256 internal constant TOTAL = 60e6;

    /// @notice `maxCalls` on the stake mandate. Never reached by the plan — the budget runs out
    ///         first, at three calls — and that is deliberate: see the file notes.
    uint32 internal constant MAX_CALLS = 4;

    /// @notice `maxCalls` on the unstake mandate. ONE, because "unstake once" is the honest shape,
    ///         and because it is what makes G8 fire at N9 before dispatch rather than letting
    ///         `StakeDummy.NothingStaked()` muddy the error.
    uint32 internal constant UNSTAKE_MAX_CALLS = 1;

    // ─────────────────────────────── the agent's requests ───────────────────────────────

    /// @notice Act 2 — the central beat.
    uint256 internal constant ACT2 = 25e6;

    /// @notice Act 3b — the second stake, at the per-call ceiling.
    uint256 internal constant ACT3B = 25e6;

    /// @notice Act 3c — the third stake, sized to land exactly on the lifetime cap.
    uint256 internal constant ACT3C = 10e6;

    // ─────────────────────────────── the gauntlet's mutations ───────────────────────────────

    /// @notice G4 — one unit over `PER_CALL`. The smallest violation that still fires the gate.
    uint256 internal constant G4_OVER_PER_CALL = 26e6;

    /// @notice G7 — any non-zero amount once the budget is exhausted. Small, so the on-screen
    ///         arithmetic (`60 + 1 > 60`) is immediately legible.
    uint256 internal constant G7_OVER_TOTAL = 1e6;

    /// @notice G5 — the native value a request must never carry. One wei, against a cap of zero.
    uint256 internal constant G5_VALUE = 1;

    // ─────────────────────────────── funding ───────────────────────────────

    /// @notice Minted to Bob in setup. 100 -> the wallet, 20 -> the throwaway wallet, 30 slack so a
    ///         rehearsal can repeat Act 1 without re-minting.
    uint256 internal constant MINT_TO_BOB = 150e6;

    /// @notice Act 1b — what Bob moves into the wallet. Comfortably above `TOTAL`, so the wallet's
    ///         balance is visibly NOT the binding constraint; the mandate is.
    uint256 internal constant WALLET_FUND = 100e6;

    /**
     * @notice Act 1c — the owner's approval to `StakeDummy`.
     *
     * @dev    EXACTLY `TOTAL`, never `type(uint256).max`. The approval is a SECOND, INDEPENDENT
     *         ceiling: even a wrong URP, or a mandate granted with a mistaken cap, could not move
     *         more than Bob approved. It costs nothing — `unstake` returns funds TO the wallet and
     *         needs no allowance — and it is the one place the demo shows defence in depth that is
     *         the owner's rather than the contract's.
     */
    uint256 internal constant APPROVAL = 60e6;

    /// @notice Setup — `StakeDummy.fundRewards`. At 10 per successful unstake, and one unstake per
    ///         run, this funds five rehearsals before `02_FundAll` must be re-run.
    uint256 internal constant REWARD_POOL = 50e6;

    /// @notice Act 4f — the throwaway wallet's balance, and therefore exactly what the accomplice
    ///         walks away with.
    uint256 internal constant THROWAWAY_FUND = 20e6;

    // ─────────────────────────────── mirrors ───────────────────────────────

    /**
     * @notice Mirror of `StakeDummy.REWARD`, FOR ASSERTIONS ONLY — never a value sent anywhere.
     * @dev    If this and the contract's constant ever disagree, the ASSERTION is wrong and the
     *         contract is right. `demo-native/test/StakeDummy.t.sol` pins them together so the
     *         disagreement is a failing test rather than a wrong number on screen.
     */
    uint256 internal constant REWARD = 10e6;

    /// @notice Decimals on `DemoUSDC`, for `DemoLog.money`. Matches real USDC.
    uint8 internal constant DECIMALS = 6;

    /// @notice Ticker shown on screen. Deliberately NOT "USDC" — see `DemoUSDC`.
    string internal constant SYMBOL = "dUSDC";
}
