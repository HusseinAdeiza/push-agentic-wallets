// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { MandateType } from "../../src/libraries/PushWalletTypes.sol";
import { MockPRC20Source } from "../mocks/MockPRC20Source.sol";

/**
 * @title  URP — every shape that can reach the envelope decoder.
 *
 * @notice THE PROPERTY, stated once and asserted once per row: NOTHING MIS-DECODES INTO A LIVE
 *         CONFIG. Every malformed, legacy or wrong-mode blob ends in a revert, and the ones that can
 *         be named ARE named.
 *
 *         This matters more than it looks. The envelope is `abi.encode(string chain, bytes body)`
 *         and the ABI decoder is lenient about offsets — it will accept an offset of 1 and read a
 *         length at an unaligned position. A v2 `(uint8 1, bytes)` wrapper therefore decodes to a
 *         256-byte "chain" made of whatever followed it in memory. That is not exploitable — only
 *         the exact bytes of this chain's identifier hash to NATIVE — but it is exactly the kind of
 *         thing that is easy to assume away and expensive to be wrong about, so each case is
 *         measured rather than reasoned.
 *
 * @dev    SEVERAL BARE `vm.expectRevert()` CALLS LIVE HERE, each with its own justification. They are
 *         permitted under `CLAUDE.md` standing test rule 1 only because these reverts genuinely
 *         carry no data: the ABI decoder fails without a selector, and naming the failures would
 *         require heuristically decoding an ambiguous blob to guess what the caller meant — which is
 *         strictly worse than failing closed. Where a named error IS available, it is asserted.
 */
contract URPEnvelopeTest is BaseTest {
    address internal ACCOUNT;
    address internal CEA;
    address internal PROTOCOL;
    address internal ASSET;

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0xE117)));

    uint48 internal constant VALID_UNTIL = 2_000_000_000;
    bytes4 internal constant SWAP = bytes4(keccak256("swap(address,uint256)"));
    bytes4 internal constant STAKE = bytes4(keccak256("stake(uint256)"));

    function setUp() public override {
        super.setUp();
        ACCOUNT = makeAddr("wallet");
        CEA = makeAddr("cea");
        PROTOCOL = makeAddr("protocol");
        ASSET = address(new MockPRC20Source(CHAIN_SEPOLIA));
        vm.warp(1_000_000_000);
    }

    function _universalCfg() internal view returns (IURP.Config memory cfg) {
        IURP.AllowedCall[] memory calls = new IURP.AllowedCall[](1);
        calls[0] = IURP.AllowedCall({
            target: PROTOCOL, selector: SWAP, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0
        });
        cfg.validUntil = VALID_UNTIL;
        cfg.expectedCEA = CEA;
        cfg.asset = ASSET;
        cfg.maxAmountPerCall = 100e6;
        cfg.maxAmountTotal = 1000e6;
        cfg.maxPCPerCall = 5 ether;
        cfg.allowedCalls = calls;
    }

    function _nativeCfg() internal view returns (IURP.NativeConfig memory cfg) {
        cfg.validUntil = VALID_UNTIL;
        cfg.target = PROTOCOL;
        cfg.selector = STAKE;
        cfg.maxValuePerCall = 1 ether;
        cfg.maxValueTotal = 10 ether;
    }

    function _init(bytes memory initData) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, initData);
    }

    // ═══════════════════════════ the two valid shapes ═══════════════════════════

    function test_Envelope_universalAccepted() public {
        _init(universalInitData(CHAIN_SEPOLIA, _universalCfg()));
        IURP.ModeSlot memory s = urp.getMode(CID, ACCOUNT);
        assertEq(uint8(s.mode), uint8(MandateType.UNIVERSAL), "universal");
        assertEq(s.chainHash, keccak256(bytes(CHAIN_SEPOLIA)), "chain recorded");
    }

    function test_Envelope_nativeAccepted() public {
        _init(nativeInitData(_nativeCfg()));
        IURP.ModeSlot memory s = urp.getMode(CID, ACCOUNT);
        assertEq(uint8(s.mode), uint8(MandateType.NATIVE), "native");
        assertEq(s.chainHash, keccak256(bytes(nativeChain())), "this chain recorded");
    }

    // ═══════════════════════ named refusals ═══════════════════════

    /// An empty chain is the one string-level check URP performs, and it is named.
    function test_Envelope_emptyChainIsNamed() public {
        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, envelope("", abi.encode(_terms(_universalCfg()))));
    }

    /**
     * A v2 `(uint8 0, bytes)` wrapper — the shape a stale SDK would send for a universal mandate.
     *
     * MEASURED, and better than expected: word 0 is `0`, read as the string's offset; the length is
     * then read at position 0, which is that same zero. So it decodes to an EMPTY chain and gets the
     * NAMED `EmptyChain()` rather than an unnamed decoder failure. Two of the three legacy shapes
     * land here, which makes this exception narrower than the one it replaces.
     */
    function test_Envelope_v2UniversalWrapperIsNamedEmptyChain() public {
        bytes memory legacy = abi.encode(uint8(0), abi.encode(_universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, legacy);
    }

    /**
     * ⚠️ THE NARROWED THIRD EXCEPTION. A bare `abi.encode(Config)` — no envelope at all.
     *
     * Same mechanism as the v2 wrapper above: the struct's head is an offset of 0x20, and the word
     * there is `initialized` — false, so zero — which reads as a zero-length string. NAMED.
     *
     * The property under test is REVERTS-NOT-MIS-DECODES; that it can now be named is a bonus this
     * change bought, and `CLAUDE.md` test rule 1 was updated to say so.
     */
    function test_Envelope_bareUniversalStructIsNamedEmptyChain() public {
        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(_universalCfg()));
    }

    /// And the native bare struct, same mechanism, same named outcome.
    function test_Envelope_bareNativeStructIsNamedEmptyChain() public {
        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(_nativeCfg()));
    }

    /// Sixty-four zero bytes: a zero-length chain and a zero-length body. Named, fails closed.
    function test_Envelope_zeroWordsAreNamedEmptyChain() public {
        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(uint256(0), uint256(0)));
    }

    // ═══════════════════════ unnamed, fail-closed refusals ═══════════════════════

    /**
     * A Scope-D-era `(uint8, bytes32, bytes)` header — a shape that existed only in design drafts,
     * covered because an SDK built against one would produce it.
     *
     * ⚠️ BARE `expectRevert`, JUSTIFIED: word 1 is a 32-byte hash, read as the `bytes` offset, which
     * points far outside the blob. The decoder aborts with no data. There is no selector to assert.
     */
    function test_Envelope_scopeDHeaderRevertsUnnamed() public {
        bytes memory d = abi.encode(uint8(0), keccak256("some chain"), abi.encode(_universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, d);
    }

    /**
     * A v2 `(uint8 2, bytes)` wrapper — what an out-of-range mode byte used to be.
     *
     * ⚠️ BARE `expectRevert`, JUSTIFIED: offset 2 sends the decoder to read a length from an
     * unaligned position, yielding an absurd length that exceeds the blob. Unnamed by construction.
     * The error this USED to produce, `InvalidPolicyMode(2)`, no longer exists — there is no mode
     * byte to be out of range.
     */
    function test_Envelope_v2OutOfRangeModeRevertsUnnamed() public {
        bytes memory d = abi.encode(uint8(2), abi.encode(_universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, d);
    }

    /// ⚠️ BARE `expectRevert`, JUSTIFIED: too short to contain two head words at all.
    function test_Envelope_tooShortRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, abi.encode(uint256(0)));
    }

    /// ⚠️ BARE `expectRevert`, JUSTIFIED: empty calldata has no head at all.
    function test_Envelope_emptyRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, "");
    }

    // ═══════════════════════ well-formed envelope, wrong body ═══════════════════════

    /**
     * A NATIVE chain carrying a UNIVERSAL body. The envelope decodes; the mode derives to NATIVE;
     * `_initNative` then tries to read a `UniversalTerms` blob as `NativeTerms` and fails.
     *
     * ⚠️ BARE `expectRevert`, JUSTIFIED: an ABI type mismatch, no selector. This is reachable ONLY
     * on the owner-door-direct-to-engine path — through `grantMandate` the wallet would have refused
     * the target/chain combination first, which is the layering working as designed.
     */
    function test_Envelope_nativeChainUniversalBodyRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, envelope(nativeChain(), abi.encode(_terms(_universalCfg()))));
    }

    /// The mirror: a foreign chain carrying a native body.
    function test_Envelope_foreignChainNativeBodyRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, envelope(CHAIN_SEPOLIA, abi.encode(_terms(_nativeCfg()))));
    }

    /**
     * A doubly-wrapped envelope: the body is itself an envelope. Derives NATIVE, then fails to read
     * the inner envelope as `NativeTerms`.
     *
     * ⚠️ BARE `expectRevert`, JUSTIFIED: ABI type mismatch, no selector. This is the signature of an
     * SDK that kept wrapping after the wallet stopped expecting it to.
     */
    function test_Envelope_doubleWrappedRevertsUnnamed() public {
        bytes memory inner = nativeInitData(_nativeCfg());

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, envelope(nativeChain(), inner));
    }

    // ═══════════════════════ the guard that precedes them all ═══════════════════════

    /**
     * ⚠️ ON AN ALREADY-INITIALISED CONFIG, EVERY SHAPE IS NAMED.
     *
     * The re-init guard runs BEFORE the decode, so a malformed blob aimed at a live config reports
     * `AlreadyInitialized` rather than a decoder failure. That ordering is deliberate and this is
     * what pins it: move the decode above the guard and this test reverts unnamed instead.
     */
    function test_Envelope_reinitGuardPrecedesTheDecoder() public {
        _init(universalInitData(CHAIN_SEPOLIA, _universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, hex"deadbeef");
    }

    /// Even a well-formed envelope cannot re-initialise, across modes or within one.
    function test_Envelope_reinitAcrossModesRefused() public {
        _init(universalInitData(CHAIN_SEPOLIA, _universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(_nativeCfg()));
    }
}
