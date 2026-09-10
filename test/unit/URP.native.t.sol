// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { URP } from "../../src/policies/URP.sol";
import { IURP, MAX_PINS } from "../../src/interfaces/IURP.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { MandateType, VALUE_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";
import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";

/**
 * @title  URP — native mode.
 * @notice Gates N1-N9, the init guards, the mode routing, the cross-mode surface, and the
 *         effects-last discipline.
 *
 * @dev    SAME HARNESS CONVENTION AS `URP.t.sol`: the deployed URP is a TransparentUpgradeableProxy
 *         initialised with `SESSION_ENGINE = address(engine)`, and both engine-facing entry points
 *         are driven with `vm.prank(address(engine))`. The engine is NOT mocked — we call from its
 *         address, which is what the multiplexer key means.
 *
 * @dev    ONE selector-less `vm.expectRevert()` exists in this file, and it is the documented THIRD
 *         standing-test-rule-1 exception: a legacy v2-style bare `abi.encode(Config)` passed to the
 *         mode decoder. It reverts unnamed because naming it would require heuristic decoding of an
 *         ambiguous blob, which is worse than the unnamed revert. The property that matters — and
 *         the one asserted — is that it REVERTS rather than mis-decoding into a live config.
 */
contract URPNativeTest is BaseTest {
    address internal ACCOUNT;
    address internal STAKE;

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0xBEEF01)));
    ConfigId internal constant CID2 = ConfigId.wrap(bytes32(uint256(0xBEEF02)));

    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));

    /// @dev Beneficiary word at 4 (first arg), amount word at 36 (second arg).
    uint16 internal constant PIN_OFFSET = 4;
    uint16 internal constant AMOUNT_OFFSET = 36;

    function setUp() public override {
        super.setUp();
        ACCOUNT = makeAddr("wallet");
        STAKE = makeAddr("stakeDummy");
        vm.warp(1_000_000_000);
    }

    // ───────────────────────────── config builders ─────────────────────────────

    /// @dev The canonical native config: one pin (beneficiary == the wallet), amount metered.
    function _nativeConfig() internal view returns (IURP.NativeConfig memory cfg) {
        IURP.ArgPin[] memory pins = new IURP.ArgPin[](1);
        pins[0] = IURP.ArgPin({ offset: PIN_OFFSET, expected: bytes32(uint256(uint160(ACCOUNT))) });

        cfg = IURP.NativeConfig({
            initialized: false,
            validUntil: VALID_UNTIL,
            target: STAKE,
            selector: STAKE_FOR,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: IURP.AmountRule({ enabled: true, offset: AMOUNT_OFFSET, maxPerCall: 50e6, maxTotal: 60e6 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: pins
        });
    }

    /// @dev A value-only config: empty calldata, native value capped, no pins, no amount rule.
    function _valueOnlyConfig() internal view returns (IURP.NativeConfig memory cfg) {
        cfg = _nativeConfig();
        cfg.selector = VALUE_SELECTOR;
        cfg.maxValuePerCall = 5 ether;
        cfg.maxValueTotal = 20 ether;
        cfg.amount = IURP.AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });
        cfg.pins = new IURP.ArgPin[](0);
    }

    function _initNative(ConfigId id, IURP.NativeConfig memory cfg) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, id, nativeInitData(cfg));
    }

    function _initDefaultNative() internal {
        _initNative(CID, _nativeConfig());
    }

    /// @dev `stakeFor(beneficiary, amount)` calldata.
    function _stakeCalldata(address beneficiary, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(STAKE_FOR, beneficiary, amount);
    }

    function _check(ConfigId id, address target, uint256 value, bytes memory data) internal returns (uint256) {
        vm.prank(address(engine));
        return urp.checkAction(id, ACCOUNT, target, value, data);
    }

    function _cfg(ConfigId id) internal view returns (IURP.NativeConfig memory) {
        return urp.getNativeConfig(id, ACCOUNT);
    }

    // ═════════════════════════════ the mode wrapper ═════════════════════════════

    function test_native_initStoresModeAndConfig() public {
        _initDefaultNative();

        IURP.ModeSlot memory slot = urp.getMode(CID, ACCOUNT);
        assertTrue(slot.initialized, "mode slot initialised");
        assertEq(uint8(slot.mode), uint8(MandateType.NATIVE), "mode is NATIVE");

        IURP.NativeConfig memory cfg = _cfg(CID);
        assertTrue(cfg.initialized, "config initialised");
        assertEq(cfg.target, STAKE, "target");
        assertEq(cfg.selector, STAKE_FOR, "selector");
        assertEq(cfg.pins.length, 1, "pins deep-copied");
        assertEq(cfg.pins[0].offset, PIN_OFFSET, "pin offset");
        assertEq(cfg.amount.maxPerCall, 50e6, "amount rule copied");
    }

    /// An out-of-range mode is NAMED, which is the entire reason the wrapper carries a `uint8`
    /// rather than the enum — decoding straight into `MandateType` would panic unnamed.
    function test_native_init_invalidPolicyMode() public {
        bytes memory body = abi.encode(_nativeConfig());
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidPolicyMode.selector, uint8(2)));
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(uint8(2), body));
    }

    /**
     * ⚠️ THE THIRD DOCUMENTED UNNAMED-REVERT EXCEPTION (standing test rule 1).
     *
     * A v2-style bare `abi.encode(Config)` is not a valid `(uint8, bytes)` wrapper. It reverts
     * inside the decoder rather than mis-decoding into a live config. Naming it would require
     * heuristically decoding an ambiguous blob to guess what the caller meant, which is strictly
     * worse than failing closed. The property under test is REVERTS-NOT-MIS-DECODES.
     */
    function test_native_init_legacyBareEncodingReverts() public {
        IURP.Config memory legacy;
        legacy.validUntil = VALID_UNTIL;

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(legacy));
    }

    // ═════════════════════════════ native init guards ═════════════════════════════

    function test_native_init_rejectsZeroTarget() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.target = address(0);
        vm.prank(address(engine));
        vm.expectRevert(IURP.NativeTargetZero.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    /// Half of the consistency lock: a native config may never name the gateway.
    function test_native_init_rejectsGatewayTarget() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.target = GATEWAY;
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.NativeTargetIsGateway.selector, GATEWAY));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    function test_native_init_rejectsZeroExpiry() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.validUntil = 0;
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidExpiry.selector, uint48(0)));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    function test_native_init_rejectsPastExpiry() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.validUntil = uint48(block.timestamp - 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidExpiry.selector, cfg.validUntil));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    function test_native_init_rejectsTooManyPins() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.pins = new IURP.ArgPin[](MAX_PINS + 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.TooManyPins.selector, MAX_PINS + 1));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    function test_native_init_acceptsExactlyMaxPins() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.pins = new IURP.ArgPin[](MAX_PINS);
        for (uint256 i; i < MAX_PINS; ++i) {
            cfg.pins[i] = IURP.ArgPin({ offset: uint16(4 + i * 32), expected: bytes32(i) });
        }
        _initNative(CID, cfg);
        assertEq(_cfg(CID).pins.length, MAX_PINS, "MAX_PINS is inclusive");
    }

    /// A value-only config that carries pins could never authorise anything — every request would
    /// die at N7. Refused at init rather than left to fail closed, because it is a misconfiguration
    /// the owner believes they granted.
    function test_native_init_rejectsValueOnlyWithPins() public {
        IURP.NativeConfig memory cfg = _valueOnlyConfig();
        cfg.pins = new IURP.ArgPin[](1);
        cfg.pins[0] = IURP.ArgPin({ offset: 4, expected: bytes32(0) });
        vm.prank(address(engine));
        vm.expectRevert(IURP.ValueOnlyWithPins.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    function test_native_init_rejectsValueOnlyWithAmountRule() public {
        IURP.NativeConfig memory cfg = _valueOnlyConfig();
        cfg.amount = IURP.AmountRule({ enabled: true, offset: 4, maxPerCall: 1, maxTotal: 1 });
        vm.prank(address(engine));
        vm.expectRevert(IURP.ValueOnlyWithAmountRule.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));
    }

    /// Counters are forced to zero: a caller-set counter would be a granted head start on the caps.
    function test_native_init_forcesCountersToZero() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.valueSpent = 999 ether;
        cfg.amountSpent = 999e6;
        cfg.callsUsed = 77;
        _initNative(CID, cfg);

        IURP.NativeConfig memory got = _cfg(CID);
        assertEq(got.valueSpent, 0, "valueSpent forced to zero");
        assertEq(got.amountSpent, 0, "amountSpent forced to zero");
        assertEq(got.callsUsed, 0, "callsUsed forced to zero");
    }

    /// Re-initialisation is refused ACROSS modes — the ModeSlot is the single flag.
    function test_native_init_refusesReinitAsNative() public {
        _initDefaultNative();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(_nativeConfig()));
    }

    function test_native_init_refusesReinitAsUniversalAfterNative() public {
        _initDefaultNative();

        IURP.AllowedCall[] memory rules = new IURP.AllowedCall[](1);
        rules[0] = IURP.AllowedCall({
            target: STAKE, selector: STAKE_FOR, beneficiaryOffset: 0, hasBeneficiary: false, maxValue: 0
        });
        IURP.Config memory u = IURP.Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            destChainHash: bytes32(0),
            expectedCEA: makeAddr("cea"),
            asset: makeAddr("asset"),
            maxAmountPerCall: 1,
            maxAmountTotal: 1,
            maxPCPerCall: 1,
            spent: 0,
            allowedCalls: rules
        });

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(u));
    }

    // ═════════════════════════════ the gates, N1-N9 ═════════════════════════════

    function test_native_happyPath_returnsSuccessAndMeters() public {
        _initDefaultNative();

        uint256 vd = _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 10e6));
        assertEq(vd, VALIDATION_SUCCESS, "validation success");

        IURP.NativeConfig memory cfg = _cfg(CID);
        assertEq(cfg.amountSpent, 10e6, "amount metered");
        assertEq(cfg.callsUsed, 1, "call counted");
        assertEq(cfg.valueSpent, 0, "no value on a non-payable action");
    }

    /// N1 — a config that was never initialised. Routed to the UNIVERSAL path (its mode slot is
    /// empty), so the error is universal gate 1's. Fail-closed either way.
    function test_native_N1_uninitialisedRoutesToUniversalAndReverts() public {
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.NotInitialized.selector, CID, ACCOUNT));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));
    }

    function test_native_N2_expired() public {
        _initDefaultNative();
        vm.warp(uint256(VALID_UNTIL) + 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.MandateExpired.selector, VALID_UNTIL));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));
    }

    /**
     * ⚠️ NEVER-DELETE (§8.1). N3 — THE CONSISTENCY LOCK, and the proof it is not dead code.
     *
     * Init refuses a gateway `target` FIELD, and the wallet refuses a gateway action under NATIVE,
     * so N3 can only ever fire on state those two layers make unreachable. The test manufactures
     * exactly that: a config whose stored target is legitimate, reached by a request whose incoming
     * target is the gateway. N3 fires because THE INCOMING TARGET IS THE GATEWAY — not because of
     * anything about the stored one.
     *
     * NAME CORRECTED 2026-09-10. This shipped as `test_native_N3_gatewayTargetRefused`, which is
     * not the name §8.1 specifies. Test names are specification and the never-delete registry is
     * consulted BY NAME, so a right-behaviour-wrong-name test is one a future refactor deletes
     * without ever finding it on the list. Found by auditing the eighteen registry names against
     * the tree, not by reading the suite.
     */
    function test_URP_NativeConfigOnGatewayFailsClosed() public {
        _initDefaultNative();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.NativeTargetIsGateway.selector, GATEWAY));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _stakeCalldata(ACCOUNT, 1e6));
    }

    function test_native_N4_targetMismatch() public {
        _initDefaultNative();
        address wrong = makeAddr("wrongTarget");
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.TargetMismatch.selector, wrong, STAKE));
        urp.checkAction(CID, ACCOUNT, wrong, 0, _stakeCalldata(ACCOUNT, 1e6));
    }

    function test_native_N5_selectorMismatch() public {
        _initDefaultNative();
        bytes4 wrong = bytes4(keccak256("somethingElse(address,uint256)"));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.SelectorMismatch.selector, wrong, STAKE_FOR));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, abi.encodeWithSelector(wrong, ACCOUNT, uint256(1e6)));
    }

    /// Under four bytes maps to the value-only selector, which a selector config does not match.
    function test_native_N5_shortCalldataBecomesValueSelector() public {
        _initDefaultNative();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.SelectorMismatch.selector, VALUE_SELECTOR, STAKE_FOR));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, hex"aabb");
    }

    function test_native_N6_valueExceedsPerCallCap() public {
        IURP.NativeConfig memory cfg = _valueOnlyConfig();
        _initNative(CID, cfg);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.ValueExceedsCap.selector, 6 ether, 5 ether));
        urp.checkAction(CID, ACCOUNT, STAKE, 6 ether, "");
    }

    function test_native_N6_valueExceedsLifetimeCap() public {
        IURP.NativeConfig memory cfg = _valueOnlyConfig();
        cfg.maxValueTotal = 7 ether;
        _initNative(CID, cfg);

        _check(CID, STAKE, 5 ether, "");
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.TotalValueExceeded.selector, 10 ether, 7 ether));
        urp.checkAction(CID, ACCOUNT, STAKE, 5 ether, "");
    }

    function test_native_N7_pinMismatch() public {
        _initDefaultNative();
        address attacker = makeAddr("attacker");
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                IURP.ArgPinMismatch.selector,
                bytes32(uint256(uint160(attacker))),
                uint256(0),
                bytes32(uint256(uint160(ACCOUNT)))
            )
        );
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(attacker, 1e6));
    }

    /// The bounds check, not a Solidity panic. `uint256(offset) + 32` is computed in uint256
    /// precisely so a large uint16 offset cannot wrap.
    function test_native_N7_calldataTooShortForPin() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.pins[0] = IURP.ArgPin({ offset: 1000, expected: bytes32(uint256(uint160(ACCOUNT))) });
        cfg.amount.enabled = false;
        _initNative(CID, cfg);

        bytes memory data = _stakeCalldata(ACCOUNT, 1e6); // 68 bytes
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.CalldataTooShortForPin.selector, data.length, uint256(0), 1032));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, data);
    }

    /// A pin on an address argument compares the FULL word: a dirty high half is a mismatch,
    /// deliberately, because full-word equality also proves the ABI padding is clean.
    function test_native_N7_dirtyHighHalfIsAMismatch() public {
        _initDefaultNative();

        bytes32 dirty = bytes32(uint256(uint160(ACCOUNT)) | (uint256(1) << 200));
        bytes memory data = abi.encodePacked(STAKE_FOR, dirty, uint256(1e6));

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(IURP.ArgPinMismatch.selector, dirty, uint256(0), bytes32(uint256(uint160(ACCOUNT))))
        );
        urp.checkAction(CID, ACCOUNT, STAKE, 0, data);
    }

    function test_native_N8_amountExceedsPerCallCap() public {
        _initDefaultNative();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.NativeAmountExceedsCap.selector, 51e6, 50e6));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 51e6));
    }

    function test_native_N8_amountExceedsLifetimeCap() public {
        _initDefaultNative();
        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 40e6));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.TotalNativeAmountExceeded.selector, 80e6, 60e6));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 40e6));
    }

    function test_native_N8_calldataTooShortForAmount() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.pins = new IURP.ArgPin[](0);
        cfg.amount.offset = 1000;
        _initNative(CID, cfg);

        bytes memory data = _stakeCalldata(ACCOUNT, 1e6);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.CalldataTooShortForAmount.selector, data.length, 1032));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, data);
    }

    function test_native_N9_callLimitReached() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.maxCalls = 2;
        _initNative(CID, cfg);

        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));
        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.CallLimitReached.selector, uint32(2), uint32(2)));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));
    }

    function test_native_N9_zeroMaxCallsIsUnlimited() public {
        _initDefaultNative();
        for (uint256 i; i < 5; ++i) {
            _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 1e6));
        }
        assertEq(_cfg(CID).callsUsed, 5, "maxCalls == 0 means unlimited");
    }

    // ═══════════════════════ decision 22 — the divergence ═══════════════════════

    /**
     * ⚠️ THE ONE DELIBERATE DIVERGENCE FROM UNIVERSAL MODE.
     *
     * A zero-value, zero-amount native call STILL increments `callsUsed`. Universal's zero-amount
     * rule writes nothing; native cannot copy it, because `maxCalls` is a USAGE limit and a
     * zero-value call is a use. Mirroring universal would let an agent exhaust nothing while making
     * unlimited calls — the limit would be advisory.
     */
    function test_native_zeroValueZeroAmountStillMetersACall() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.maxCalls = 3;
        _initNative(CID, cfg);

        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 0));

        IURP.NativeConfig memory got = _cfg(CID);
        assertEq(got.callsUsed, 1, "a zero call is still a call");
        assertEq(got.amountSpent, 0, "nothing metered");
        assertEq(got.valueSpent, 0, "nothing spent");
    }

    /// And the limit is genuinely reachable with zero-value calls, which is the point.
    function test_native_zeroValueCallsExhaustMaxCalls() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.maxCalls = 2;
        _initNative(CID, cfg);

        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 0));
        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 0));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.CallLimitReached.selector, uint32(2), uint32(2)));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 0));
    }

    // ═══════════════════════════ effects-last discipline ═══════════════════════════

    /**
     * A request that fails at N9 leaves the N6 and N8 counters untouched.
     *
     * This is what "all checks, then all effects" buys, and it is the discipline decision 22 rides
     * on: if effects were applied as each gate passed, a later gate's revert would still have moved
     * `valueSpent` and `amountSpent` — and because the engine calls this with a real (non-static)
     * call, that write would persist for the rest of the transaction.
     */
    function test_native_effectsLast_failedN9LeavesCountersUntouched() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.maxCalls = 1;
        _initNative(CID, cfg);

        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 10e6));
        IURP.NativeConfig memory before = _cfg(CID);

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.CallLimitReached.selector, uint32(1), uint32(1)));
        urp.checkAction(CID, ACCOUNT, STAKE, 0, _stakeCalldata(ACCOUNT, 10e6));

        IURP.NativeConfig memory got = _cfg(CID);
        assertEq(got.amountSpent, before.amountSpent, "amountSpent untouched by the failed call");
        assertEq(got.valueSpent, before.valueSpent, "valueSpent untouched");
        assertEq(got.callsUsed, before.callsUsed, "callsUsed untouched");
    }

    /// The metering event mirrors the effects, and fires even when both values are zero.
    function test_native_emitsNativeCallMetered() public {
        _initDefaultNative();

        vm.expectEmit(true, true, true, true, address(urp));
        emit IURP.NativeCallMetered(CID, address(engine), ACCOUNT, 0, 7e6);

        _check(CID, STAKE, 0, _stakeCalldata(ACCOUNT, 7e6));
    }

    // ═════════════════════════ the value-only path ═════════════════════════

    /// `data.length == 0` is the ONLY true value-only shape — a no-argument function still carries
    /// four bytes and is a normal selector action.
    function test_native_valueOnly_emptyCalldataPasses() public {
        _initNative(CID, _valueOnlyConfig());

        uint256 vd = _check(CID, STAKE, 3 ether, "");
        assertEq(vd, VALIDATION_SUCCESS, "value-only call validates");

        IURP.NativeConfig memory cfg = _cfg(CID);
        assertEq(cfg.valueSpent, 3 ether, "value metered");
        assertEq(cfg.callsUsed, 1, "call counted");
    }

    /**
     * Value-only means EMPTY calldata — 1..3 bytes is refused (review §2.3, register N-46).
     *
     * The engine buckets anything under four bytes under `VALUE_SELECTOR`, so N5's selector match
     * alone would let a 1..3-byte payload through a value-only config. URP is the layer that makes
     * the documented meaning true; without this the doc and the contract disagree.
     */
    function test_native_valueOnly_rejectsShortNonEmptyCalldata() public {
        _initNative(CID, _valueOnlyConfig());

        bytes[3] memory shorts = [bytes(hex"01"), bytes(hex"0102"), bytes(hex"010203")];
        for (uint256 i; i < shorts.length; ++i) {
            vm.prank(address(engine));
            vm.expectRevert(abi.encodeWithSelector(IURP.ValueOnlyCalldataNotEmpty.selector, shorts[i].length));
            urp.checkAction(CID, ACCOUNT, STAKE, 1 ether, shorts[i]);
        }

        // Empty still passes — the boundary is exact.
        assertEq(_check(CID, STAKE, 1 ether, ""), VALIDATION_SUCCESS, "empty calldata is the value-only shape");
    }

    // ═════════════════════════ cross-mode surface ═════════════════════════

    /**
     * A LEGACY universal config — `$configs` live, `$mode` empty — is reported and guarded
     * correctly by the mode-sensitive views (review §2.1).
     *
     * `_modeOf` derives UNIVERSAL from `$configs[..].initialized`, so these must behave exactly as
     * they would for a post-upgrade universal config: the native getter refuses, and the native
     * `assertSpent` refuses with `WrongModeForCall`, NOT `NotInitialized`.
     */
    function test_native_legacyUniversalSlot_isGuardedByTheViews() public {
        _initUniversalAt(CID2);

        // Make it legacy-shaped: $mode never written.
        bytes32 modeSlot = keccak256(
            abi.encode(ACCOUNT, keccak256(abi.encode(address(engine), keccak256(abi.encode(CID2, uint256(5))))))
        );
        vm.store(address(urp), modeSlot, bytes32(0));
        assertEq(vm.load(address(urp), modeSlot), bytes32(0), "legacy shape: raw slot empty");

        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.UNIVERSAL));
        urp.getNativeConfig(CID2, ACCOUNT);

        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.UNIVERSAL));
        urp.assertSpent(CID2, ACCOUNT, 0, 0, 0);
    }

    function test_native_getConfig_revertsOnNativeSlot() public {
        _initDefaultNative();
        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.NATIVE));
        urp.getConfig(CID, ACCOUNT);
    }

    function test_native_getNativeConfig_revertsOnUniversalSlot() public {
        _initUniversalAt(CID2);
        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.UNIVERSAL));
        urp.getNativeConfig(CID2, ACCOUNT);
    }

    /// An EMPTY slot is a STATE, not a caller bug: both getters return the zeroed struct, exactly
    /// as `getConfig` always has. Only a wrong-MODE read is loud.
    function test_native_getters_emptySlotReturnsZeroed() public view {
        IURP.Config memory u = urp.getConfig(CID, ACCOUNT);
        assertFalse(u.initialized, "universal getter: zeroed on an empty slot");

        IURP.NativeConfig memory n = urp.getNativeConfig(CID, ACCOUNT);
        assertFalse(n.initialized, "native getter: zeroed on an empty slot");
        assertEq(n.pins.length, 0, "and its dynamic array encodes cleanly");
    }

    function test_native_getMode_neverReverts() public {
        IURP.ModeSlot memory empty = urp.getMode(CID, ACCOUNT);
        assertFalse(empty.initialized, "empty slot: not initialised");
        assertEq(uint8(empty.mode), uint8(MandateType.UNIVERSAL), "and its mode value is meaningless");

        _initDefaultNative();
        IURP.ModeSlot memory native = urp.getMode(CID, ACCOUNT);
        assertTrue(native.initialized, "native slot: initialised");
        assertEq(uint8(native.mode), uint8(MandateType.NATIVE), "mode NATIVE");

        _initUniversalAt(CID2);
        IURP.ModeSlot memory uni = urp.getMode(CID2, ACCOUNT);
        assertTrue(uni.initialized, "universal slot: initialised");
        assertEq(uint8(uni.mode), uint8(MandateType.UNIVERSAL), "mode UNIVERSAL");
    }

    // ═════════════════════════ assertSpent, both overloads ═════════════════════════

    /**
     * ALL THREE counters, each mismatched INDIVIDUALLY, in both directions.
     *
     * The name always claimed three; an earlier version only exercised two, leaving the
     * `valueSpent` arm — the FIRST of the three checks — with no test at all. Found by reading the
     * branch-coverage report, not by reading the test. A guard that exists to catch stale belief
     * must itself be caught when it stops working.
     *
     * The config here meters VALUE as well as amount, so all three counters are non-zero and every
     * arm is genuinely distinguishable.
     */
    function test_native_assertSpent_exactEqualityOnAllThree() public {
        IURP.NativeConfig memory cfg = _nativeConfig();
        cfg.maxValuePerCall = 5 ether;
        cfg.maxValueTotal = 20 ether;
        _initNative(CID, cfg);

        _check(CID, STAKE, 3 ether, _stakeCalldata(ACCOUNT, 12e6));

        // The truth: 3 ether spent, 12e6 metered, one call.
        urp.assertSpent(CID, ACCOUNT, 3 ether, 12e6, 1);

        // (1) valueSpent — too low, then too high.
        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(2 ether), uint256(3 ether)));
        urp.assertSpent(CID, ACCOUNT, 2 ether, 12e6, 1);

        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(4 ether), uint256(3 ether)));
        urp.assertSpent(CID, ACCOUNT, 4 ether, 12e6, 1);

        // (2) amountSpent — both directions.
        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(11e6), uint256(12e6)));
        urp.assertSpent(CID, ACCOUNT, 3 ether, 11e6, 1);

        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(13e6), uint256(12e6)));
        urp.assertSpent(CID, ACCOUNT, 3 ether, 13e6, 1);

        // (3) callsUsed — both directions.
        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(2), uint256(1)));
        urp.assertSpent(CID, ACCOUNT, 3 ether, 12e6, 2);

        vm.expectRevert(abi.encodeWithSelector(IURP.SpentMismatch.selector, uint256(0), uint256(1)));
        urp.assertSpent(CID, ACCOUNT, 3 ether, 12e6, 0);
    }

    function test_native_assertSpent_wrongModeBothWays() public {
        _initDefaultNative();
        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.NATIVE));
        urp.assertSpent(CID, ACCOUNT, 0);

        _initUniversalAt(CID2);
        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.UNIVERSAL));
        urp.assertSpent(CID2, ACCOUNT, 0, 0, 0);
    }

    /// No silent-pass mode on a ghost: reading zero from a ghost is indistinguishable from reading
    /// zero from a real unused mandate, and this function exists to catch stale belief.
    function test_native_assertSpent_ghostReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IURP.NotInitialized.selector, CID, ACCOUNT));
        urp.assertSpent(CID, ACCOUNT, 0, 0, 0);
    }

    // ═════════════════════════ creditRevert is universal-only ═════════════════════════

    /// `creditRevert` is untouched by native mode. On a native slot the universal config is empty,
    /// so it reverts `NotInitialized` — BEFORE the `$credited` write, which keeps a misrouted credit
    /// retryable rather than burning the outbound id forever.
    function test_native_creditRevert_notInitialisedOnNativeSlot() public {
        _initDefaultNative();
        bytes32 txId = keccak256("outbound-1");

        vm.prank(EXECUTOR_MODULE);
        vm.expectRevert(abi.encodeWithSelector(IURP.NotInitialized.selector, CID, ACCOUNT));
        urp.creditRevert(CID, ACCOUNT, txId, 1e6);

        assertFalse(urp.isCredited(txId), "the outbound id was NOT burned");
    }

    // ───────────────────────────── universal helper ─────────────────────────────

    function _initUniversalAt(ConfigId id) internal {
        IURP.AllowedCall[] memory rules = new IURP.AllowedCall[](1);
        rules[0] = IURP.AllowedCall({
            target: STAKE, selector: STAKE_FOR, beneficiaryOffset: 0, hasBeneficiary: false, maxValue: 0
        });
        IURP.Config memory u = IURP.Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            destChainHash: bytes32(0),
            expectedCEA: makeAddr("cea"),
            asset: makeAddr("asset"),
            maxAmountPerCall: 1 ether,
            maxAmountTotal: 1 ether,
            maxPCPerCall: 1 ether,
            spent: 0,
            allowedCalls: rules
        });
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, id, universalInitData(u));
    }
}
