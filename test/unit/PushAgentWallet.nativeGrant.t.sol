// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { IURP, MAX_PINS } from "../../src/interfaces/IURP.sol";
import { MandateType } from "../../src/libraries/PushWalletTypes.sol";

import { StakeDummy } from "../mocks/StakeDummy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { ISmartSession } from "smartsessions/ISmartSession.sol";
import {
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context,
    PermissionId
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

/**
 * @title  PushAgentWallet — native grant shape, and the Phase 3 gas gate.
 * @notice The forbidden-target and forbidden-selector lists in full, plus the two asserted gas
 *         budgets of decision 41.
 *
 * @dev    THE GAS BUDGETS ARE ASSERTIONS, NOT REPORTS. Decision 41 fixes them at 8,000,000 for a
 *         maximal 8x8 grant end to end and 2,000,000 for `stopMandate` on one maximal mandate,
 *         chosen against a mainnet-realistic 30M block rather than Donut's 4.29-BILLION testnet
 *         limit — a limit nothing can fail against is not a gate. `stopAll` over five mandates is
 *         REPORTED only, because its cost scales with N by design (decision 43: `stopMandate` is
 *         the bounded lever; `stopAll` is the convenience over N).
 */
contract PushAgentWalletNativeGrantTest is BaseTest {
    PushAgentWallet internal wallet;
    address internal WALLET_OWNER;

    StakeDummy internal stakeDummy;
    MockERC20 internal token;

    /// @dev Decision 41's budgets.
    uint256 internal constant MAX_GRANT_GAS = 8_000_000;
    uint256 internal constant MAX_STOP_MANDATE_GAS = 2_000_000;

    function setUp() public override {
        super.setUp();
        WALLET_OWNER = makeAddr("walletOwner");
        wallet = newWallet(WALLET_OWNER);
        token = new MockERC20();
        stakeDummy = new StakeDummy(token);
    }

    // ───────────────────────────────── builders ─────────────────────────────────

    function _cfg(address target, bytes4 selector, uint256 pinCount)
        internal
        view
        returns (IURP.NativeConfig memory c)
    {
        IURP.ArgPin[] memory pins = new IURP.ArgPin[](pinCount);
        for (uint256 i; i < pinCount; ++i) {
            pins[i] = IURP.ArgPin({ offset: uint16(4 + i * 32), expected: bytes32(uint256(i + 1)) });
        }
        c = IURP.NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 30 days),
            target: target,
            selector: selector,
            maxValuePerCall: 1 ether,
            maxValueTotal: 10 ether,
            valueSpent: 0,
            amount: IURP.AmountRule({ enabled: true, offset: 36, maxPerCall: 1e6, maxTotal: 10e6 }),
            amountSpent: 0,
            maxCalls: 100,
            callsUsed: 0,
            pins: pins
        });
    }

    function _action(address target, bytes4 selector, uint256 pinCount) internal view returns (ActionData memory) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(_cfg(target, selector, pinCount)) });
        return ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: ps });
    }

    function _session(ActionData[] memory actions, bytes32 saltSeed) internal view returns (Session memory) {
        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: ecdsaConfig(address(uint160(uint256(saltSeed)))),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    /// @dev The MAXIMAL native mandate: eight actions, each with the full eight pins.
    function _maximalSession(bytes32 saltSeed) internal view returns (Session memory) {
        ActionData[] memory a = new ActionData[](8);
        for (uint256 i; i < 8; ++i) {
            a[i] = _action(address(stakeDummy), bytes4(uint32(0x33000000 + i)), MAX_PINS);
        }
        return _session(a, saltSeed);
    }

    // ═══════════════════════ forbidden targets, one by one ═══════════════════════

    function _expectForbiddenTarget(address target) internal {
        ActionData[] memory a = new ActionData[](1);
        a[0] = _action(target, bytes4(0x12345678), 0);

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ForbiddenActionTarget.selector, target));
        wallet.grantMandate(_session(a, bytes32(uint256(1))));
    }

    function test_forbidden_zeroAddress() public {
        _expectForbiddenTarget(address(0));
    }

    function test_forbidden_engineFallbackFlag() public {
        _expectForbiddenTarget(address(1));
    }

    function test_forbidden_theWalletItself() public {
        _expectForbiddenTarget(address(wallet));
    }

    function test_forbidden_theEngine() public {
        _expectForbiddenTarget(address(engine));
    }

    function test_forbidden_urp() public {
        _expectForbiddenTarget(address(urp));
    }

    function test_forbidden_theValidator() public {
        _expectForbiddenTarget(address(validator));
    }

    function test_forbidden_theFactory() public {
        _expectForbiddenTarget(FACTORY);
    }

    /// `0xFFFFFFFF` is value-only and is deliberately NOT forbidden.
    function test_valueSelectorIsPermitted() public {
        IURP.NativeConfig memory c = _cfg(address(stakeDummy), 0xFFFFFFFF, 0);
        c.amount = IURP.AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: 0xFFFFFFFF, actionTarget: address(stakeDummy), actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantMandate(_session(a, bytes32(uint256(2))));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "value-only is grantable");
    }

    /// The event carries the declared type.
    function test_grantEmitsMandateType() public {
        ActionData[] memory a = new ActionData[](1);
        a[0] = _action(address(stakeDummy), bytes4(0x12345678), 0);

        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantMandate(_session(a, bytes32(uint256(3))));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool saw;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(wallet)
                    && logs[i].topics[0] == keccak256("MandateGranted(bytes32,uint8,bytes32,string)")
            ) {
                assertEq(logs[i].topics[1], pid, "id");
                // topics[2] is the chain hash — indexed so an indexer filters by chain without
                // decoding. It is DERIVED from the envelope, which is what makes the type below
                // NATIVE; nobody declared either.
                assertEq(logs[i].topics[2], keccak256(bytes(nativeChain())), "chain hash");
                (uint8 mode, string memory chain) = abi.decode(logs[i].data, (uint8, string));
                assertEq(mode, uint8(MandateType.NATIVE), "type NATIVE");
                assertEq(chain, nativeChain(), "chain string carried for human readers");
                saw = true;
            }
        }
        assertTrue(saw, "MandateGranted emitted");
    }

    // ═════════════════════════ decision 41 — the gas gate ═════════════════════════

    /**
     * ⚠️ ASSERTED, NOT REPORTED. A maximal 8x8 grant, end to end through the engine.
     *
     * "End to end" means the whole `grantMandate` call: the shape check, the O(n^2) duplicate scan,
     * `enableSessions`, the engine's per-action bookkeeping, and eight full `NativeConfig` writes
     * with eight pins each. Measured, not estimated.
     */
    function test_gasGate_maximalGrantUnder8M() public {
        Session memory s = _maximalSession(bytes32(uint256(0xA1)));

        vm.prank(WALLET_OWNER);
        uint256 before = gasleft();
        wallet.grantMandate(s);
        uint256 used = before - gasleft();

        emit log_named_uint("GAS GATE - maximal 8x8 native grant", used);
        emit log_named_uint("GAS GATE - budget", MAX_GRANT_GAS);
        assertLt(used, MAX_GRANT_GAS, "a maximal native grant must fit inside 8M gas");
    }

    /**
     * ⚠️ ASSERTED. `stopMandate` on one maximal mandate — THE BOUNDED LEVER.
     *
     * This is the half decision 43 cares about: Rule 3's invariant is that the WALLET adds nothing
     * to removal that can fail, and `stopMandate` is the lever that is guaranteed to work. Its cost
     * is bounded by one mandate's action count, so it is assertable in a way `stopAll` is not.
     */
    function test_gasGate_stopMandateOnMaximalMandateUnder2M() public {
        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantMandate(_maximalSession(bytes32(uint256(0xB1))));

        vm.prank(WALLET_OWNER);
        uint256 before = gasleft();
        wallet.stopMandate(pid);
        uint256 used = before - gasleft();

        emit log_named_uint("GAS GATE - stopMandate on a maximal native mandate", used);
        emit log_named_uint("GAS GATE - budget", MAX_STOP_MANDATE_GAS);
        assertLt(used, MAX_STOP_MANDATE_GAS, "stopMandate on a maximal mandate must fit inside 2M gas");

        assertFalse(
            engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "and the mandate is really gone"
        );
    }

    /**
     * REPORTED, NOT ASSERTED. `stopAll` over five maximal mandates.
     *
     * Its cost scales with N by design and N is unbounded, so an assertion here would either be
     * arbitrary or unfailable. Decision 43 is explicit that `stopAll` is the convenience over N and
     * `stopMandate` is the guarantee. The number is reported so a regression is visible.
     */
    function test_gasReport_stopAllOverFiveMaximalMandates() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(WALLET_OWNER);
            wallet.grantMandate(_maximalSession(bytes32(uint256(0xC1 + i))));
        }

        vm.prank(WALLET_OWNER);
        uint256 before = gasleft();
        wallet.stopAll();
        uint256 used = before - gasleft();

        emit log_named_uint("GAS REPORT - stopAll over five maximal native mandates", used);
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "stopAll removed every mandate");
    }
}
