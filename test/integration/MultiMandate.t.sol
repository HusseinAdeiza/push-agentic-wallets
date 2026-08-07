// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MandateFixture } from "../helpers/MandateFixture.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ACPActionPolicy } from "../../src/policies/ACPActionPolicy.sol";
import { ModeLib } from "../../src/libraries/ModeLib.sol";

import { Session, PermissionId, ConfigId } from "smartsessions/DataTypes.sol";

/**
 * @notice v2 Step 12 — THE multi-mandate regression gate (T-57 … T-60).
 *
 * @dev THIS SUITE IS WHY v2 IS SAFE. v1 claimed isolation structurally: "one mandate's
 *      session cannot reach another's wallet, because they are different contracts." Rule 2
 *      WITHDRAWS that claim — there is now exactly one wallet per user, shared by every
 *      mandate. The replacement guarantee is the Mandate Bound (§C.6), and it rests
 *      entirely on SmartSession keying every policy config by
 *      ConfigId = f(account, PermissionId, actionId).
 *
 *      If that keying ever collapses, two mandates would share one budget and the entire
 *      v2 isolation story fails silently. These tests are the alarm.
 */
contract MultiMandateTest is MandateFixture {
    uint256 internal agentBPk = 0xB0B0B;
    address internal agentBKey;

    bytes32 internal pidA;
    bytes32 internal pidB;

    function setUp() public {
        _deployStack();
        agentBKey = vm.addr(agentBPk);

        // Two mandates on ONE wallet: different salts AND different agent keys.
        pidA = _grant(_session(mandateA, agentKey, 100e6));
        pidB = _grant(_session(mandateB, agentBKey, 500e6));
    }

    /**
     * T-57 — THE PERMANENT REGRESSION GATE. NEVER DELETE.
     *
     * Exhaust mandate A, then assert A is dead AND B retains its full budget. Also asserts
     * via `getConfig` that the two ConfigIds hold independent `spent` values, so the test
     * fails if the keying ever collapses rather than only if the caps happen to differ.
     */
    function test_T57_exhaustingOneMandateLeavesTheOtherIntact() public {
        ConfigId cidA = _acpConfigId(pidA);
        ConfigId cidB = _acpConfigId(pidB);
        assertTrue(ConfigId.unwrap(cidA) != ConfigId.unwrap(cidB), "ConfigIds must differ");

        // Spend A to exactly its 100e6 ceiling.
        _executeSession(pidA, agentPk, expectedCEA, 60e6, 0);
        _executeSession(pidA, agentPk, expectedCEA, 40e6, 1);

        (,,,,, uint256 totalA,, uint256 spentA,) = acp.getConfig(cidA, address(smartSession), address(wallet));
        assertEq(spentA, 100e6, "A exhausted");
        assertEq(totalA, 100e6);

        // A's next op must fail on the cumulative cap (R5b).
        (bool okA,) = _tryExecuteSession(pidA, agentPk, expectedCEA, 1e6, 2);
        assertFalse(okA, "A must be out of budget");

        // B is untouched: full 500e6 still available, zero spent.
        (,,,,, uint256 totalB,, uint256 spentB,) = acp.getConfig(cidB, address(smartSession), address(wallet));
        assertEq(totalB, 500e6, "B keeps its full cap");
        assertEq(spentB, 0, "B has spent nothing");

        // And B genuinely still executes, including an amount A could never have spent.
        _executeSession(pidB, agentBPk, expectedCEA, 100e6, 0);
        (,,,,,,, uint256 spentBAfter,) = acp.getConfig(cidB, address(smartSession), address(wallet));
        assertEq(spentBAfter, 100e6, "B spent independently");
    }

    /// @dev T-58 — the gas budgets are independent too. `ValueLimitPolicy` is keyed by the
    ///      same ConfigId, so exhausting A's PC budget must not touch B's.
    function test_T58_independentGasBudgets() public {
        ConfigId cidA = _acpConfigId(pidA);
        ConfigId cidB = _acpConfigId(pidB);

        vm.deal(address(wallet), 1000 ether);

        _executeSessionWithValue(pidA, agentPk, expectedCEA, 10e6, 0, 30 ether);

        assertEq(valueLimit.getUsed(cidA, address(smartSession), address(wallet)), 30 ether, "A used 30");
        assertEq(valueLimit.getUsed(cidB, address(smartSession), address(wallet)), 0, "B used nothing");
        assertEq(valueLimit.getValueLimit(cidB, address(smartSession), address(wallet)), VALUE_LIMIT);

        // Exhaust A's 100 ether budget; B still has its own full allowance.
        _executeSessionWithValue(pidA, agentPk, expectedCEA, 10e6, 1, 70 ether);
        (bool okA,) = _tryExecuteSessionWithValue(pidA, agentPk, expectedCEA, 10e6, 2, 1 ether);
        assertFalse(okA, "A's gas budget is spent");

        _executeSessionWithValue(pidB, agentBPk, expectedCEA, 10e6, 0, 90 ether);
        assertEq(valueLimit.getUsed(cidB, address(smartSession), address(wallet)), 90 ether, "B unaffected");
    }

    /**
     * T-59 — three concurrent mandates with `nonceKey = uint192(uint256(PermissionId))`
     * (S-3), interleaved. Each mandate owns its own nonce lane, so ops from different
     * mandates never contend and a stalled agent cannot block the others.
     */
    function test_T59_interleavedOpsAcrossThreeMandatesNoNonceCollision() public {
        uint256 agentCPk = 0xC0C0C;
        bytes32 pidC = _grant(_session(keccak256("mandate-C"), vm.addr(agentCPk), 300e6));

        uint192 keyA = uint192(uint256(pidA));
        uint192 keyB = uint192(uint256(pidB));
        uint192 keyC = uint192(uint256(pidC));
        assertTrue(keyA != keyB && keyB != keyC && keyA != keyC, "nonce lanes must be distinct");

        // Interleave: A0, B0, C0, A1, B1, C1.
        _executeSession(pidA, agentPk, expectedCEA, 10e6, 0);
        _executeSession(pidB, agentBPk, expectedCEA, 10e6, 0);
        _executeSession(pidC, agentCPk, expectedCEA, 10e6, 0);
        _executeSession(pidA, agentPk, expectedCEA, 10e6, 1);
        _executeSession(pidB, agentBPk, expectedCEA, 10e6, 1);
        _executeSession(pidC, agentCPk, expectedCEA, 10e6, 1);

        assertEq(wallet.nonce(keyA), 2);
        assertEq(wallet.nonce(keyB), 2);
        assertEq(wallet.nonce(keyC), 2);

        // Each mandate's spend is its own.
        (,,,,,,, uint256 sA,) = acp.getConfig(_acpConfigId(pidA), address(smartSession), address(wallet));
        (,,,,,,, uint256 sB,) = acp.getConfig(_acpConfigId(pidB), address(smartSession), address(wallet));
        (,,,,,,, uint256 sC,) = acp.getConfig(_acpConfigId(pidC), address(smartSession), address(wallet));
        assertEq(sA, 20e6);
        assertEq(sB, 20e6);
        assertEq(sC, 20e6);
    }

    /**
     * T-60 — mandate A's key cannot affect B's config, session or counters.
     *
     * Sweeps the obvious attempts. This is the closest direct test of the Mandate Bound's
     * last row: "other mandates' configs, sessions, modules — unreachable."
     */
    function test_T60_mandateAKeyCannotTouchMandateB() public {
        ConfigId cidB = _acpConfigId(pidB);

        // 1. A's key cannot sign for B's PermissionId: the signature is checked against
        //    B's own session validator config, which holds agentBKey.
        (bool ok,) = _tryExecuteSessionSigned(pidB, agentPk, expectedCEA, 10e6, 0);
        assertFalse(ok, "A's key must not authorize B's mandate");

        // 2. A's key cannot use B's nonce lane with its own permission id either — the
        //    opHash binds the nonce, so a mismatched lane fails signature validation.
        (bool ok2,) = _tryExecuteSessionWrongLane(pidA, agentPk, uint192(uint256(pidB)));
        assertFalse(ok2, "cross-lane replay must fail");

        // 3. Nothing above moved B's counters.
        (,,,,, uint256 totalB,, uint256 spentB,) = acp.getConfig(cidB, address(smartSession), address(wallet));
        assertEq(totalB, 500e6);
        assertEq(spentB, 0, "B's spend untouched by A's attempts");
        assertEq(valueLimit.getUsed(cidB, address(smartSession), address(wallet)), 0);

        // 4. B's session is still enabled and functional.
        assertTrue(smartSession.isPermissionEnabled(PermissionId.wrap(pidB), address(wallet)));
        _executeSession(pidB, agentBPk, expectedCEA, 10e6, 0);
    }

    /// @dev The agent key holds no wallet authority at all: it cannot grant, revoke or
    ///      reconfigure. Only the owner can (A-12, D-11 USE-mode only).
    function test_T60b_agentKeyHasNoLifecycleAuthority() public {
        Session memory s = _session(keccak256("mandate-X"), agentKey, 1e6);
        address agentEOA = agentKey;

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(agentEOA);
        wallet.grantMandate(s);

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(agentEOA);
        wallet.revokeMandate(pidB);

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(agentEOA);
        wallet.reconfigureMandate(s);
    }

    // ── helpers ───────────────────────────────────────────────────────

    function _tryExecuteSessionWithValue(
        bytes32 pid,
        uint256 pk,
        address beneficiary,
        uint256 amount,
        uint64 seq,
        uint256 pcValue
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory execCd = _execCalldataWithValue(beneficiary, amount, pcValue);
        uint192 key = uint192(uint256(pid));
        bytes memory sig = _sign(pk, pid, _opHash(ModeLib.encodeSimpleSingle(), execCd, key, seq));
        (ok, ret) = address(wallet)
            .call(
                abi.encodeCall(
                    PushAgentWallet.executeWithSession,
                    (address(smartSession), ModeLib.encodeSimpleSingle(), execCd, sig, key, seq)
                )
            );
    }

    /// @dev Signs for `pid` with the WRONG key.
    function _tryExecuteSessionSigned(bytes32 pid, uint256 wrongPk, address beneficiary, uint256 amount, uint64 seq)
        internal
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = _tryExecuteSessionWithValue(pid, wrongPk, beneficiary, amount, seq, 0);
    }

    /// @dev Uses `pid`'s own key but another mandate's nonce lane.
    function _tryExecuteSessionWrongLane(bytes32 pid, uint256 pk, uint192 foreignLane)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory execCd = _execCalldataWithValue(expectedCEA, 10e6, 0);
        uint64 seq = wallet.nonce(foreignLane);
        // Sign over the CORRECT lane, then submit against the foreign one.
        bytes memory sig = _sign(pk, pid, _opHash(ModeLib.encodeSimpleSingle(), execCd, uint192(uint256(pid)), seq));
        (ok, ret) = address(wallet)
            .call(
                abi.encodeCall(
                    PushAgentWallet.executeWithSession,
                    (address(smartSession), ModeLib.encodeSimpleSingle(), execCd, sig, foreignLane, seq)
                )
            );
    }
}
