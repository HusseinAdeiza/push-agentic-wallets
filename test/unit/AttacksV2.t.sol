// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MandateFixture } from "../helpers/MandateFixture.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ACPActionPolicy } from "../../src/policies/ACPActionPolicy.sol";
import { ModeLib } from "../../src/libraries/ModeLib.sol";
import { Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

import { Session, PolicyData, ActionData, PermissionId, ConfigId } from "smartsessions/DataTypes.sol";
import { SudoPolicy } from "smartsessions/external/policies/SudoPolicy.sol";

import { MockCEA } from "../mocks/Mocks.sol";

/**
 * @notice v2 Step 11 — attack tests (T-52 … T-56) and Step 13's F-25 marker (T-66).
 *
 * @dev Each test names the capability it denies. These are the attacks that Rule 2 either
 *      created (a shared wallet pools everything) or made worse (one CEA aggregates every
 *      mandate's positions), so they are the tests that justify v2's guard surface.
 */
contract AttacksV2Test is MandateFixture {
    function setUp() public {
        _deployStack();
    }

    // ── T-52 — A-14 composite: the three wildcards ────────────────────

    /**
     * T-52 — W-1, W-2, W-3 each attempted at GRANT time.
     *
     * All three are wildcards in SmartSession's action model that a shared wallet cannot
     * tolerate. They are denied at grant rather than at execution because a granted
     * wildcard is already a compromise: the user has signed something whose reach they
     * cannot enumerate.
     */
    function test_T52_A14_allThreeWildcardsDeniedAtGrant() public {
        _installSmartSession();

        // ── W-1: the fallback ActionId, armed with SudoPolicy.
        // DENIES: calling ANY unregistered (target, selector) with ACP never running.
        SudoPolicy sudo = new SudoPolicy();
        Session memory w1 = _session(mandateA, agentKey, type(uint256).max);
        w1.actions[0].actionTarget = address(1); // FALLBACK_TARGET_FLAG
        w1.actions[0].actionPolicies = new PolicyData[](1);
        w1.actions[0].actionPolicies[0] = PolicyData({ policy: address(sudo), initData: "" });

        vm.expectRevert(PushWalletErrors.FallbackActionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(w1);

        // ── W-2: SmartSession itself as the action target.
        // DENIES: enableSessions (self-granting a wider mandate) and removeSession
        // (killing the user's OTHER mandates) from a session key.
        SessionSpec memory spec2 = _spec(mandateA, agentKey, type(uint256).max);
        spec2.actionTarget = address(smartSession);
        Session memory w2 = _sessionFull(spec2);

        vm.expectRevert(PushWalletErrors.SmartSessionActionForbidden.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(w2);

        // ── W-3: a gateway action carrying the WRONG policy set.
        // DENIES: satisfying minPolicies == 1 with TimeFramePolicy alone, which would
        // leave every ACP rule (R1-R15) unenforced on a real outbound.
        SessionSpec memory spec3 = _spec(mandateA, agentKey, type(uint256).max);
        spec3.withACP = false;
        spec3.withValueLimit = false;
        Session memory w3 = _sessionFull(spec3);

        vm.expectRevert(PushWalletErrors.GatewayActionMissingACP.selector);
        vm.prank(ownerUEA);
        wallet.grantMandate(w3);
    }

    // ── T-53 — A-06: pooled-PC drain ──────────────────────────────────

    /**
     * T-53 — the gas budget is a real bound, not a per-call one.
     *
     * Under Rule 2 native PC is POOLED across every mandate, so a per-call cap alone would
     * let a compromised key drain the wallet through repeated in-cap calls. Drive
     * minimum-amount outbounds until `ValueLimitPolicy` rejects, then assert the TOTAL PC
     * forwarded never exceeded the mandate's lifetime allowance.
     */
    function test_T53_A06_totalPCForwardedNeverExceedsValueLimit() public {
        uint256 budget = 10 ether;
        SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
        spec.vLimit = budget;
        bytes32 pid = _grant(_sessionFull(spec));

        vm.deal(address(wallet), 1000 ether);
        uint256 perCall = 3 ether;

        uint256 forwarded;
        uint64 seq;
        for (uint256 i; i < 10; ++i) {
            uint256 before = address(gateway).balance;
            (bool ok,) = _tryExecWithValue(pid, agentPk, 1e6, seq, perCall);
            if (!ok) break;
            forwarded += address(gateway).balance - before;
            seq++;
        }

        assertEq(forwarded, 9 ether, "3 calls of 3 ether fit; the 4th must be refused");
        assertLe(forwarded, budget, "total PC forwarded must never exceed valueLimit");

        // The budget is genuinely exhausted, not merely paused.
        (bool okAfter,) = _tryExecWithValue(pid, agentPk, 1e6, seq, perCall);
        assertFalse(okAfter, "over-budget call must be refused");

        assertEq(valueLimit.getUsed(_acpConfigId(pid), address(smartSession), address(wallet)), 9 ether);
    }

    /// @dev R13 regression. A zero-amount outbound is rejected outright: the gateway would
    ///      infer GAS_AND_PAYLOAD, skip `_burnPRC20` so `spent` never moves, yet still take
    ///      `protocolFee` from msg.value — leaving every amount cap structurally blind.
    function test_T53b_R13_zeroAmountOutboundRejected() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));
        vm.deal(address(wallet), 100 ether);

        (bool ok, bytes memory ret) = _tryExecWithValue(pid, agentPk, 0, 0, 1 ether);
        assertFalse(ok, "zero-amount outbound must revert");
        assertGt(ret.length, 0, "must carry revert data");
    }

    // ── T-54 — A-02 fail-closed against real CEA semantics ────────────

    /**
     * T-54 — R14's backstop, proven against a verbatim mirror of the frozen CEA.
     *
     * ACP R6 requires the payload to be MULTICALL-prefixed. If that check were ever
     * bypassed, the payload would reach `CEA._handleSingleCall` with recipient ==
     * address(0) — because R14 forces `req.recipient` empty — and the frozen contract
     * reverts `InvalidRecipient()` rather than executing
     * `recipient.call{value: msg.value}(payload)`. That is the difference between a failed
     * transaction and direct theft.
     */
    function test_T54_A02_nonMulticallPayloadWithEmptyRecipientRevertsAtCEA() public {
        MockCEA cea = new MockCEA();

        // A non-multicall payload: a bare ERC-20 transfer to the attacker.
        bytes memory evil = abi.encodeWithSignature("transfer(address,uint256)", attacker, 1e18);

        vm.expectRevert(MockCEA.InvalidRecipient.selector);
        cea.handleExecution(address(0), evil);
    }

    /// @dev The park case still works: empty payload AND zero recipient is the documented
    ///      "leave the funds in the CEA" convention, which is what R14 relies on being
    ///      canonical rather than exceptional.
    function test_T54b_parkCaseStillSucceeds() public {
        MockCEA cea = new MockCEA();
        cea.handleExecution(address(0), "");
        assertTrue(cea.parked(), "park must remain a valid no-op");
    }

    /// @dev And a value-bearing self-call is rejected by the frozen multicall rule
    ///      (CEA.sol:196) — the constraint that makes the value-0 self-call the exit path
    ///      ACP R7 must close.
    function test_T54c_valueBearingSelfCallRejectedByCEA() public {
        MockCEA cea = new MockCEA();
        vm.deal(address(this), 1 ether);

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(address(cea), 1, "");

        vm.expectRevert(MockCEA.InvalidInput.selector);
        cea.handleExecution{ value: 1 }(address(0), abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls)));
    }

    // ── T-55 — A-01 regression ────────────────────────────────────────

    /// @dev The oldest attack: redirect the deposit beneficiary to the provider. Still
    ///      closed by R9, now via the `expectedArg == 0` CEA sentinel.
    function test_T55_A01_beneficiaryRedirectStillReverts() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));

        (bool ok, bytes memory ret) = _tryExec(pid, agentPk, attacker, 10e6, 0);
        assertFalse(ok, "redirecting the beneficiary must fail");
        assertGt(ret.length, 0);

        // The legitimate beneficiary still works.
        _executeSession(pid, agentPk, expectedCEA, 10e6, 0);
    }

    // ── T-56 — A-16: the guardian beats the latency window ────────────

    /**
     * T-56 — a compromised key's op fails immediately after `guardianPause`, in the SAME
     * block.
     *
     * This is the whole point of the guardian: owner revocation is an origin-chain round
     * trip (minutes), and a compromised key can act inside that window. Pause is one Push
     * transaction.
     */
    function test_T56_A16_pauseStopsCompromisedKeyInSameBlock() public {
        bytes32 pid = _grant(_session(mandateA, agentKey, type(uint256).max));

        uint256 blockBefore = block.number;

        // The key works right up to the moment of the pause.
        _executeSession(pid, agentPk, expectedCEA, 10e6, 0);

        vm.prank(guardian);
        wallet.guardianPause();

        (bool ok,) = _tryExec(pid, agentPk, expectedCEA, 10e6, 1);
        assertFalse(ok, "the compromised key must be stopped");
        assertEq(block.number, blockBefore, "same block: no origin-chain round trip needed");
    }

    // ── T-66 — F-25 watch item (Step 13) ──────────────────────────────

    /**
     * T-66 — DOCUMENTATION TEST for F-25. NEVER DELETE.
     *
     * G3a hardcodes `UNIVERSAL_GATEWAY_PC` as the ONLY permitted session action target.
     * That is the tightest closure of W-3 and correct for v2.0's entry-only scope.
     *
     * THE COST, recorded verbatim from F-25: "the wallet is an immutable clone, so a second
     * session action type later needs a new implementation and factory. Correct for
     * entry-only v2.0. ⚠ If ERC-8183 ever needs agent-initiated, session-path calls to the
     * kernel, this is the constraint that blocks it — revisit before mainnet, not after."
     *
     * This test exists so that constraint is discoverable in code, not only in the PRD.
     */
    function test_T66_F25_gatewayIsOnlySessionTarget() public {
        _installSmartSession();

        address[3] memory otherTargets = [usdc, aavePool, expectedCEA];
        for (uint256 i; i < otherTargets.length; ++i) {
            SessionSpec memory spec = _spec(mandateA, agentKey, type(uint256).max);
            spec.actionTarget = otherTargets[i];
            Session memory s = _sessionFull(spec);

            vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ActionTargetNotGateway.selector, otherTargets[i]));
            vm.prank(ownerUEA);
            wallet.grantMandate(s);
        }

        assertEq(wallet.UNIVERSAL_GATEWAY_PC(), address(gateway), "the sole permitted target");
    }

    // ── helpers ───────────────────────────────────────────────────────

    function _tryExec(bytes32 pid, uint256 pk, address beneficiary, uint256 amount, uint64 seq)
        internal
        returns (bool ok, bytes memory ret)
    {
        return _rawExec(pid, pk, beneficiary, amount, seq, 0);
    }

    function _tryExecWithValue(bytes32 pid, uint256 pk, uint256 amount, uint64 seq, uint256 pcValue)
        internal
        returns (bool ok, bytes memory ret)
    {
        return _rawExec(pid, pk, expectedCEA, amount, seq, pcValue);
    }

    function _rawExec(bytes32 pid, uint256 pk, address beneficiary, uint256 amount, uint64 seq, uint256 pcValue)
        internal
        returns (bool ok, bytes memory ret)
    {
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
}
