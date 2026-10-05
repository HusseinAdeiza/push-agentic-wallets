// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";

import { ConfigId } from "smartsessions/DataTypes.sol";

import { AllowedCall, Config, ModeSlot, NativeConfig, RulesType } from "../../src/libraries/Types.sol";

import { MockPRC20Source } from "../mocks/MockPRC20Source.sol";
import { AGW } from "../../src/AGW.sol";
import { stdError } from "forge-std/StdError.sol";

/**
 * @title  URP — every shape that can reach the envelope decoder.
 *
 * @notice THE PROPERTY, stated once and asserted once per row: NOTHING MIS-DECODES INTO A LIVE
 *         CONFIG. Every malformed, legacy or wrong-mode blob ends in a revert, and the ones that can
 *         be named ARE named.
 *
 *         The envelope is `abi.encode(uint16 version, string chain, bytes body)`. URP reads the
 *         version from the FIRST WORD before decoding anything else, so almost every malformed,
 *         legacy or pre-version blob is refused NAMED as `UnsupportedEnvelopeVersion(firstWord)`.
 *         What remains unnamed: blobs shorter than one word, and a version-1 envelope whose body is
 *         the wrong `Terms` type for the derived mode. Each case is measured rather than reasoned.
 *
 * @dev    A FEW BARE `vm.expectRevert()` CALLS LIVE HERE, each with its own justification. They are
 *         permitted under `CLAUDE.md` standing test rule 1 only because these reverts genuinely
 *         carry no data: a calldata slice or the ABI decoder fails without a selector. Where a named
 *         error IS available, it is asserted.
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

    function _universalCfg() internal view returns (Config memory cfg) {
        AllowedCall[] memory calls = new AllowedCall[](1);
        calls[0] =
            AllowedCall({ target: PROTOCOL, selector: SWAP, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0 });
        cfg.validUntil = VALID_UNTIL;
        cfg.expectedCEA = CEA;
        cfg.assets = oneAsset(ASSET, 100e6, 1000e6);
        cfg.maxGasPerCall = 5 ether;
        cfg.allowedCalls = calls;
    }

    function _nativeCfg() internal view returns (NativeConfig memory cfg) {
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
        ModeSlot memory s = urp.getMode(CID, ACCOUNT);
        assertEq(uint8(s.mode), uint8(RulesType.UNIVERSAL), "universal");
        assertEq(s.chainHash, keccak256(bytes(CHAIN_SEPOLIA)), "chain recorded");
    }

    function test_Envelope_nativeAccepted() public {
        _init(nativeInitData(_nativeCfg()));
        ModeSlot memory s = urp.getMode(CID, ACCOUNT);
        assertEq(uint8(s.mode), uint8(RulesType.NATIVE), "native");
        assertEq(s.chainHash, keccak256(bytes(nativeChain())), "this chain recorded");
    }

    // ═══════════════════════ named refusals ═══════════════════════

    /// An empty chain is the one string-level check URP performs, and it is named.
    function test_Envelope_emptyChainIsNamed() public {
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, envelope("", abi.encode(_terms(_universalCfg()))));
    }

    /// @dev Expect `UnsupportedEnvelopeVersion(version)` for `initData`, aimed at an empty config.
    function _expectVersionRefused(bytes memory initData, uint256 version) internal {
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.UnsupportedEnvelopeVersion.selector, version));
        urp.initializeWithMultiplexer(ACCOUNT, CID, initData);
    }

    /**
     * ⚠️ THE VERSION GATE. URP reads the version from the FIRST WORD before decoding anything else,
     * and refuses every value but `ENVELOPE_VERSION`. Versions 0 and 2 of a well-formed envelope are
     * refused named.
     */
    function test_Envelope_onlyVersionOneIsAccepted() public {
        bytes memory body = abi.encode(_terms(_universalCfg()));
        _expectVersionRefused(abi.encode(uint16(0), CHAIN_SEPOLIA, body), 0);
        _expectVersionRefused(abi.encode(uint16(2), CHAIN_SEPOLIA, body), 2);
        _init(abi.encode(uint16(1), CHAIN_SEPOLIA, body));
        assertTrue(urp.getMode(CID, ACCOUNT).initialized, "version 1 is accepted");
    }

    /// The WHOLE first word is compared, not its low 16 bits: 65537 truncates to 1 and must still fail.
    function test_Envelope_versionIsTheWholeFirstWord() public {
        bytes memory body = abi.encode(_terms(_universalCfg()));
        _expectVersionRefused(abi.encode(uint256(1) + 2 ** 16, CHAIN_SEPOLIA, body), 2 ** 16 + 1);
    }

    /**
     * A pre-version two-field `(string chain, bytes body)` envelope — what an SDK built before the
     * version shipped would send. Its first word is the string's offset, 0x40, so it is refused as
     * version 64, named.
     */
    function test_Envelope_preVersionTwoFieldEnvelopeIsNamed() public {
        _expectVersionRefused(abi.encode(CHAIN_SEPOLIA, abi.encode(_terms(_universalCfg()))), 0x40);
    }

    /// A v2 `(uint8 0, bytes)` wrapper — the shape a stale SDK would send for a universal mandate.
    function test_Envelope_v2UniversalWrapperIsNamed() public {
        _expectVersionRefused(abi.encode(uint8(0), abi.encode(_universalCfg())), 0);
    }

    /// A bare `abi.encode(Config)` — no envelope at all. Its head is an offset of 0x20.
    function test_Envelope_bareUniversalStructIsNamed() public {
        _expectVersionRefused(abi.encode(_universalCfg()), 0x20);
    }

    /// And the native bare struct, same mechanism, same named outcome.
    function test_Envelope_bareNativeStructIsNamed() public {
        _expectVersionRefused(abi.encode(_nativeCfg()), 0x20);
    }

    /// Sixty-four zero bytes: version 0.
    function test_Envelope_zeroWordsAreNamed() public {
        _expectVersionRefused(abi.encode(uint256(0), uint256(0)), 0);
    }

    /// A Scope-D-era `(uint8, bytes32, bytes)` header, covered because an SDK built against one would
    /// produce it. Version 0.
    function test_Envelope_scopeDHeaderIsNamed() public {
        _expectVersionRefused(abi.encode(uint8(0), keccak256("some chain"), abi.encode(_universalCfg())), 0);
    }

    /// A v2 `(uint8 2, bytes)` wrapper — what an out-of-range mode byte used to be. Version 2.
    function test_Envelope_v2OutOfRangeModeIsNamed() public {
        _expectVersionRefused(abi.encode(uint8(2), abi.encode(_universalCfg())), 2);
    }

    /// One word is enough to read a version: a single zero word is version 0, named.
    function test_Envelope_singleZeroWordIsNamed() public {
        _expectVersionRefused(abi.encode(uint256(0)), 0);
    }

    // ═══════════════════════ unnamed, fail-closed refusals ═══════════════════════

    /// ⚠️ BARE `expectRevert`, JUSTIFIED: shorter than one word, so there is no version to read; the
    /// calldata slice fails with no data.
    function test_Envelope_shorterThanOneWordRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, hex"0000000000000000000000000000000000000000000000000000000001");
    }

    /// ⚠️ BARE `expectRevert`, JUSTIFIED: empty calldata has no head at all.
    function test_Envelope_emptyRevertsUnnamed() public {
        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, "");
    }

    // ═══════════════════════ through the wallet ═══════════════════════

    /// An unsupported version through the real wallet: the wallet reads the chain and passes the bytes
    /// on untouched, URP refuses the version at init, and the error reaches the owner NAMED (init
    /// reverts bubble with full data; only `checkAction` reverts are truncated by the engine).
    function test_Envelope_throughTheWallet_unsupportedVersionIsNamed() public {
        address owner = makeAddr("envelopeOwner");
        AGW wallet = newWallet(owner);
        bytes memory initData = abi.encode(uint16(2), CHAIN_SEPOLIA, abi.encode(_terms(_universalCfg())));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.UnsupportedEnvelopeVersion.selector, uint256(2))
        );
        wallet.grantRules(canonicalSession(agentConfig(makeAddr("envelopeAgent")), initData));
    }

    /**
     * A pre-version two-field envelope through the real wallet fails EARLIER, in the wallet's own
     * decode: the wallet reads the chain with the three-field decoder, the old layout points it at a
     * garbage string length, and the decoder panics (0x41, memory allocation). Fails closed before URP
     * is reached. The wallet deliberately does not judge the version — URP is the one judge of the
     * envelope's terms — so this panic, not a named error, is what a stale SDK sees through a grant.
     */
    function test_Envelope_throughTheWallet_preVersionEnvelopePanicsInTheWalletDecode() public {
        address owner = makeAddr("envelopeOwner");
        AGW wallet = newWallet(owner);
        bytes memory initData = abi.encode(CHAIN_SEPOLIA, abi.encode(_terms(_universalCfg())));
        vm.prank(owner);
        vm.expectRevert(stdError.memOverflowError);
        wallet.grantRules(canonicalSession(agentConfig(makeAddr("envelopeAgent")), initData));
    }

    // ═══════════════════════ well-formed envelope, wrong body ═══════════════════════

    /**
     * A NATIVE chain carrying a UNIVERSAL body. The envelope decodes; the mode derives to NATIVE;
     * `_initNative` then tries to read a `UniversalTerms` blob as `NativeTerms` and fails.
     *
     * ⚠️ BARE `expectRevert`, JUSTIFIED: an ABI type mismatch, no selector. This is reachable ONLY
     * on the owner-door-direct-to-engine path — through `grantRules` the wallet would have refused
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
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, hex"deadbeef");
    }

    /// Even a well-formed envelope cannot re-initialise, across modes or within one.
    function test_Envelope_reinitAcrossModesRefused() public {
        _init(universalInitData(CHAIN_SEPOLIA, _universalCfg()));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(_nativeCfg()));
    }
}
