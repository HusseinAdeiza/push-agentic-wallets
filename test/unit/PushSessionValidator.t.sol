// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { IPushSessionValidator } from "../../src/interfaces/IPushSessionValidator.sol";

/**
 * @notice PushSessionValidator acceptance suite — written fresh (the prior suite was deleted with
 *         the v1/v2 code). Covers §11's required table plus P-01, P-02, P-03, P-04, P-05.
 *
 * @dev    EXACTLY ONE selector-less `vm.expectRevert()` exists in this file: P-05, where
 *         `validateConfig` and `validateSignatureWithData` both fail at the same `abi.decode` step
 *         and neither has a named error by design. Every other negative test names its error.
 *
 * @dev    P-03 is the only permitted skip; it is env-gated on PUSH_TESTNET_RPC.
 */
contract PushSessionValidatorTest is BaseTest {
    uint8 internal constant SCHEME_ECDSA = 0;
    uint8 internal constant SCHEME_ED25519 = 1;

    address internal signer;
    uint256 internal signerPk;

    bytes32 internal constant OP_HASH = keccak256("the ten-field operation hash");

    /// @dev A 32-byte Ed25519 public key. Its VALUE is irrelevant everywhere in this file: no local
    ///      test verifies a real Ed25519 signature — that is P-03's job against the live precompile.
    bytes32 internal constant ED_PUBKEY = bytes32(uint256(0xED25519));

    function setUp() public override {
        super.setUp();
        (signer, signerPk) = ecdsaKey("agentSigner");
    }

    // ───────────────────────────────── helpers ─────────────────────────────────

    function _ecdsaData(address key) internal pure returns (bytes memory) {
        return abi.encode(SCHEME_ECDSA, abi.encodePacked(key));
    }

    function _edData(bytes32 key) internal pure returns (bytes memory) {
        return abi.encode(SCHEME_ED25519, abi.encodePacked(key));
    }

    /// @dev A well-formed 64-byte Ed25519 signature. Contents are arbitrary — see ED_PUBKEY.
    function _edSig() internal pure returns (bytes memory) {
        return abi.encodePacked(keccak256("sig-hi"), keccak256("sig-lo"));
    }

    // ═════════════════════════════ ECDSA — V01…V04 ═════════════════════════════

    function test_V01_ecdsaValidSignature() public view {
        assertTrue(
            validator.validateSignatureWithData(OP_HASH, signOpHash(signerPk, OP_HASH), _ecdsaData(signer)),
            "a correct ECDSA signature over the op hash validates"
        );
    }

    function test_V02_ecdsaWrongKeyReturnsFalse() public {
        address other = makeAddr("someoneElse");
        assertFalse(
            validator.validateSignatureWithData(OP_HASH, signOpHash(signerPk, OP_HASH), _ecdsaData(other)),
            "wrong configured key returns FALSE, not revert"
        );
    }

    function test_V02b_ecdsaWrongHashReturnsFalse() public view {
        bytes32 otherHash = keccak256("a different operation");
        assertFalse(
            validator.validateSignatureWithData(otherHash, signOpHash(signerPk, OP_HASH), _ecdsaData(signer)),
            "signature over a different hash returns FALSE, not revert"
        );
    }

    /**
     * Runtime guard: a signature of the wrong LENGTH returns false rather than reverting.
     *
     * HONEST SCOPE. Deleting the contract's explicit `sig.length != 65` early-out does not change
     * any observable behaviour — verified by mutation, and by probing every length below directly:
     * OZ's `ECDSA.tryRecover` already returns `RecoverError.InvalidSignatureLength` for anything
     * that is not 65 bytes, which the next line converts to `false` anyway. So this test pins the
     * BEHAVIOUR (wrong length ⇒ false, never a revert), which is the property §6.1 specifies; it
     * does not and cannot pin that particular line's existence. The line stays because it states
     * the 65-byte rule locally instead of inheriting it from a dependency.
     */
    function test_V03_ecdsaMalformedSignatureReturnsFalse() public view {
        assertFalse(validator.validateSignatureWithData(OP_HASH, hex"1122", _ecdsaData(signer)), "64-byte-short sig");
        assertFalse(validator.validateSignatureWithData(OP_HASH, "", _ecdsaData(signer)), "empty sig");
        assertFalse(
            validator.validateSignatureWithData(OP_HASH, new bytes(64), _ecdsaData(signer)),
            "64 bytes is the Ed25519 length and is NOT accepted for scheme 0 (EIP-2098 deliberately absent)"
        );
        assertFalse(validator.validateSignatureWithData(OP_HASH, new bytes(66), _ecdsaData(signer)), "66-byte sig");
    }

    /// `tryRecover`, not `recover`: an unrecoverable signature returns false rather than reverting.
    function test_V03b_ecdsaInvalidRecoveryReturnsFalse() public view {
        // s above secp256k1n/2 — ECDSA.RecoverError.InvalidSignatureS
        bytes memory highS = abi.encodePacked(
            bytes32(uint256(1)),
            bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
            uint8(27)
        );
        assertFalse(validator.validateSignatureWithData(OP_HASH, highS, _ecdsaData(signer)), "high-s returns false");

        // an invalid v
        bytes memory badV = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(99));
        assertFalse(validator.validateSignatureWithData(OP_HASH, badV, _ecdsaData(signer)), "bad v returns false");
    }

    /// Config guard: a key that is not 20 bytes REVERTS — the owner's grant is broken, so it is loud.
    function test_V04_ecdsaBadConfigLengthReverts() public {
        bytes memory sig = signOpHash(signerPk, OP_HASH);

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ECDSA, new bytes(19)));

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ECDSA, new bytes(21)));

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ECDSA, new bytes(0)));

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ECDSA, new bytes(32)));
    }

    // ════════════════════════════ Ed25519 — V05…V08 ════════════════════════════

    /**
     * V-05 / V-06 — the accept and reject paths.
     *
     * OBSERVER, NEVER ORACLE — and this pair is the exception that proves the rule, so read the
     * boundary carefully. The USV observer returns a FIXED value; it is the only way to reach the
     * post-precompile `abi.decode(ret, (bool))` line locally, because no local EVM implements the
     * precompile. What these two tests prove is PROPAGATION: whatever USV answered, the validator
     * returned it unchanged.
     *
     * They prove NOTHING about Ed25519 correctness, and they must never be read that way. The
     * shipped critical bug (§2) survived review precisely because a mock supplied the behaviour
     * under test and a dead branch looked live. LIVENESS AND CORRECTNESS OF THIS BRANCH ARE PROVEN
     * ONLY BY P-03 against the real precompile; P-04 proves it fails closed when USV is absent.
     * The three are a set and none is sufficient alone.
     */
    function test_V05_ed25519ValidSignature() public {
        etchUSVObserver(); // answers a fixed `true`
        assertTrue(
            validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY)),
            "the precompile's TRUE is propagated unchanged (propagation, not correctness)"
        );
    }

    function test_V06_ed25519InvalidSignature() public {
        etchUSVFalseObserver(); // answers a fixed `false`
        assertFalse(
            validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY)),
            "the precompile's FALSE is propagated unchanged (propagation, not correctness)"
        );
    }

    /// Config guard, matching the ECDSA branch: a key that is not 32 bytes REVERTS.
    function test_V07_ed25519BadConfigLengthReverts() public {
        etchUSVObserver();
        bytes memory sig = _edSig();

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ED25519, new bytes(31)));

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ED25519, new bytes(33)));

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, abi.encode(SCHEME_ED25519, new bytes(20)));
    }

    /// Runtime guard: a signature of the wrong length returns FALSE — the split in §6.1.
    function test_V08_ed25519BadSignatureLengthReturnsFalse() public {
        etchUSVObserver();
        bytes memory data = _edData(ED_PUBKEY);

        assertFalse(validator.validateSignatureWithData(OP_HASH, new bytes(63), data), "63-byte sig");
        assertFalse(validator.validateSignatureWithData(OP_HASH, new bytes(65), data), "65 is the ECDSA length");
        assertFalse(validator.validateSignatureWithData(OP_HASH, "", data), "empty sig");
    }

    /**
     * THE METHOD PIN — `verifyEd25519RawMessage`, never `verifyEd25519`.
     *
     * `verifyEd25519` verifies over the ASCII of `"0x" + hex(digest)`, which no standard Ed25519
     * library produces for a headless agent. The message must be the RAW 32 bytes of the op hash.
     *
     * WHY A MOCK IS PERMITTED HERE, given that §2's history is that `vm.etch` at USV is exactly
     * what masked the shipped critical bug: the rule that separates the two cases is that A MOCK
     * MAY BE THE OBSERVER, NEVER THE ORACLE. The original mock supplied the behaviour under test,
     * so a dead branch looked live. This one asserts nothing about correctness — it only makes
     * observable WHICH method was called, which is otherwise unobservable from outside.
     *
     * LIVENESS OF THE BRANCH IS PROVEN BY P-03 AGAINST THE REAL PRECOMPILE, NOT HERE. The two
     * tests are a pair and neither is sufficient alone.
     */
    function test_ed25519UsesRawMessageVariant() public {
        etchUSVObserver();

        bytes memory key = abi.encodePacked(ED_PUBKEY);
        bytes memory sig = _edSig();

        // The exact calldata the raw-message variant must produce: method, key, RAW 32-byte
        // message (not a hex string), signature.
        expectUSVCall(
            abi.encodeWithSignature("verifyEd25519RawMessage(bytes,bytes,bytes)", key, abi.encodePacked(OP_HASH), sig)
        );

        validator.validateSignatureWithData(OP_HASH, sig, _edData(ED_PUBKEY));
    }

    /**
     * The negative half of the pin: the hex-ASCII variant must NEVER be reached.
     *
     * THE SIGNATURE HERE IS LOAD-BEARING AND EASY TO GET WRONG. The hex-ASCII method is
     * `verifyEd25519(bytes,bytes32,bytes)` — note the `bytes32` middle parameter
     * (`IUSigVerifier.sol:23`, and the audited `UEA_SVM.sol:169`, which is the only production
     * caller of it anywhere in the Push repos). An earlier version of this test asserted zero calls
     * to `verifyEd25519(bytes,bytes,bytes)`, a selector NO contract declares — so it could not
     * fail, and read as coverage while proving nothing.
     *
     * Mutation-verified: pointing the validator at the hex variant makes THIS test fail, not only
     * the positive pin above.
     */
    function test_ed25519NeverCallsHexAsciiVariant() public {
        etchUSVObserver();
        vm.expectCall(USV, abi.encodeWithSignature("verifyEd25519(bytes,bytes32,bytes)"), 0);
        validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY));
    }

    // ═══════════════════════════ scheme space — V09 ═══════════════════════════

    function test_V09_unknownSchemeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PushSessionValidator.UnsupportedScheme.selector, uint8(2)));
        validator.validateSignatureWithData(OP_HASH, _edSig(), abi.encode(uint8(2), abi.encodePacked(ED_PUBKEY)));
    }

    // ══════════════════════════ module plumbing — V10 ══════════════════════════

    /// `isModuleType(7)` is GRANT-BLOCKING, not decorative: `ConfigLib.sol:208-212` reverts
    /// `InvalidISessionValidator` unless it returns true.
    function test_V10_isModuleType() public view {
        assertTrue(validator.isModuleType(7), "type 7 - stateless validator");
        assertFalse(validator.isModuleType(0), "0");
        assertFalse(validator.isModuleType(1), "1 - plain validator");
        assertFalse(validator.isModuleType(2), "2 - executor");
        assertFalse(validator.isModuleType(3), "3 - fallback");
        assertFalse(validator.isModuleType(4), "4 - hook");
        assertFalse(validator.isModuleType(6), "6");
        assertFalse(validator.isModuleType(8), "8");
        assertFalse(validator.isModuleType(type(uint256).max), "max");
    }

    // ══════════════════════ USV independence — V12b / P-04 ══════════════════════

    /// The ECDSA path must be wholly independent of the precompile's state.
    function test_V12b_ecdsaUnaffectedByMissingUSV() public {
        stripUSV();
        assertEq(USV.code.length, 0, "USV really has no code");

        assertTrue(
            validator.validateSignatureWithData(OP_HASH, signOpHash(signerPk, OP_HASH), _ecdsaData(signer)),
            "ECDSA still validates with no precompile present"
        );
        assertFalse(
            validator.validateSignatureWithData(OP_HASH, signOpHash(signerPk, OP_HASH), _ecdsaData(makeAddr("other"))),
            "and still rejects correctly"
        );
    }

    /**
     * P-04 ⚠️ NEVER-DELETE — the regression guard for the shipped critical bug.
     *
     * The original code called the precompile through a high-level interface. Solidity inserts an
     * `extcodesize(target) > 0` check before any high-level call that ABI-decodes return data, and
     * precompiles have no code — so the ENTIRE Ed25519 branch was dead on the real chain while
     * every test passed, because `vm.etch` had placed code at the address and masked it.
     *
     * This test is mutation-verified against that pre-fix implementation: with a typed interface
     * call in place of the raw staticcall, it REVERTS instead of returning false.
     *
     * The property: no code at USV ⇒ scheme 1 returns FALSE, never reverts. Fail closed.
     */
    function test_V12_C1_ed25519FailsClosedWhenUSVHasNoCode() public {
        stripUSV();
        assertEq(USV.code.length, 0, "USV really has no code");

        bool result = validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY));
        assertFalse(result, "a codeless precompile yields a FAILED signature, never a bricked path");
    }

    /// The same fail-closed property when USV returns too few bytes to decode a bool.
    function test_ed25519FailsClosedOnShortReturn() public {
        vm.etch(USV, type(ShortReturnObserver).runtimeCode);
        assertFalse(
            validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY)), "ret.length < 32 fails closed"
        );
    }

    // ════════════════════════ statelessness & constants ════════════════════════

    function test_statelessLifecycleIsNoop() public view {
        // Neither lifecycle hook may revert or record anything; both are `pure`.
        validator.onInstall("");
        validator.onInstall(hex"deadbeef");
        validator.onUninstall("");
        validator.onUninstall(hex"deadbeef");

        // Stateless ⇒ honestly "initialized" for ANY account, including one that never installed it.
        assertTrue(validator.isInitialized(address(0)), "zero address");
        assertTrue(validator.isInitialized(OWNER), "an arbitrary account");
        assertTrue(validator.isInitialized(address(validator)), "itself");
    }

    /**
     * THE STATELESSNESS INVARIANT, asserted against the BUILD ARTIFACT (§4).
     *
     * A `vm.load` slot read is NOT acceptable here and the helper's docblock explains why: reading
     * chosen slots and asserting zero is equally satisfied by a contract that declares variables
     * and never writes them — a test that cannot fail. This asserts solc's own storageLayout is
     * empty, which is the only form that actually fails when storage is added.
     */
    function test_holdsNoStorage() public view {
        assertEmptyStorageLayout("PushSessionValidator");
    }

    function test_constants() public view {
        assertEq(validator.USV(), 0xEC00000000000000000000000000000000000001, "canonical V2 precompile address");
        assertEq(validator.SCHEME_ECDSA(), 0, "scheme 0 = ECDSA");
        assertEq(validator.SCHEME_ED25519(), 1, "scheme 1 = Ed25519");
    }

    // ═══════════════════════════════════ P-01 ═══════════════════════════════════

    /**
     * P-01 — case 1 of the §6.3 consistency law, and ONLY case 1:
     *
     *     validateConfig(data) == true  ⟺  validateSignatureWithData(·,·,data) does not revert
     *
     * A non-reverting runtime call returning FALSE is a SIGNATURE failure, not a config failure,
     * and is outside this law entirely — so the assertion is on revert/no-revert, never on the
     * returned bool.
     *
     * THE try/catch ON validateConfig IS MANDATORY, not defensive style. `validateConfig` is
     * three-valued, and a fuzzer reaches structurally garbled `data` immediately — an unwrapped
     * `bool ok = validator.validateConfig(data);` would revert INSIDE THE HARNESS before any
     * assertion runs.
     *
     * WHY THE INPUT IS BUILT FROM (scheme, key) RATHER THAN FUZZED AS RAW `bytes`. Measured: with
     * a raw `bytes` parameter, ZERO of 1024 runs decode as `(uint8, bytes)` — every run lands in
     * the catch and returns early, so the assertion below is never reached and the test cannot
     * fail. Confirmed by inverting the assertion, which still passed. Raw-`bytes` fuzzing tests
     * case 3, which is P-05's job (`testFuzz_P05` keeps it).
     *
     * Fuzzing the STRUCTURED space is what makes case 1 assertable: `scheme` roams the whole byte
     * range so supported and reserved schemes both appear, and `keyLen` roams 0..96 so correct and
     * incorrect key lengths both appear. `test_P01_LawOnKnownInputs` pins the same law on fixed
     * inputs so a seed change cannot silently lose coverage.
     */
    function testFuzz_P01_ValidateConfig_MatchesRuntime(uint8 scheme, uint8 rawKeyLen, bytes memory sig) public {
        etchUSVObserver(); // so scheme 1 has something to call; it supplies no correctness

        bytes memory data = abi.encode(scheme, new bytes(bound(rawKeyLen, 0, 96)));

        bool configSaysValid;
        try validator.validateConfig(data) returns (bool ok) {
            configSaysValid = ok;
        } catch {
            // Case 3 territory (P-05 owns it). Case 1 says nothing here.
            return;
        }

        bool runtimeReverted;
        try validator.validateSignatureWithData(OP_HASH, sig, data) returns (bool) {
            runtimeReverted = false;
        } catch {
            runtimeReverted = true;
        }

        assertEq(configSaysValid, !runtimeReverted, "validateConfig == true  <=>  the runtime does not revert");
    }

    /// The law's two directions, pinned on hand-built inputs so a fuzz seed change cannot lose them.
    function test_P01_LawOnKnownInputs() public {
        etchUSVObserver();
        bytes memory sig = signOpHash(signerPk, OP_HASH);

        // true  => does not revert
        assertTrue(validator.validateConfig(_ecdsaData(signer)), "valid ECDSA config");
        validator.validateSignatureWithData(OP_HASH, sig, _ecdsaData(signer));

        assertTrue(validator.validateConfig(_edData(ED_PUBKEY)), "valid Ed25519 config");
        validator.validateSignatureWithData(OP_HASH, _edSig(), _edData(ED_PUBKEY));

        // false => reverts (named — that is P-02's half)
        bytes memory shortKey = abi.encode(SCHEME_ECDSA, new bytes(19));
        assertFalse(validator.validateConfig(shortKey), "19-byte ECDSA key is invalid config");
        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, sig, shortKey);
    }

    // ═══════════════════════════════════ P-02 ═══════════════════════════════════

    /**
     * P-02 — the reserved scheme space, and §6.3 case 2.
     *
     * Scheme bytes 2+ are RESERVED (byte 2 is earmarked for the deferred contract-signer
     * capability). They must revert `UnsupportedScheme` today so a future builder cannot quietly
     * reuse one. Also proves case 2: `validateConfig == false` ⇒ a NAMED runtime error.
     */
    function test_P02_Scheme2_Reverts() public {
        bytes memory data = abi.encode(uint8(2), abi.encodePacked(ED_PUBKEY));

        assertFalse(validator.validateConfig(data), "scheme 2 is not a valid config");

        vm.expectRevert(abi.encodeWithSelector(PushSessionValidator.UnsupportedScheme.selector, uint8(2)));
        validator.validateSignatureWithData(OP_HASH, _edSig(), data);
    }

    function testFuzz_P02_ReservedSchemeSpaceReverts(uint8 scheme, bytes memory key) public {
        vm.assume(scheme >= 2); // 0 and 1 are the supported schemes
        bytes memory data = abi.encode(scheme, key);

        assertFalse(validator.validateConfig(data), "every reserved scheme is an invalid config");

        vm.expectRevert(abi.encodeWithSelector(PushSessionValidator.UnsupportedScheme.selector, scheme));
        validator.validateSignatureWithData(OP_HASH, _edSig(), data);
    }

    /// Case 2 for the OTHER named error: a supported scheme with a wrong key length.
    function testFuzz_P02_BadKeyLengthGivesNamedError(bool useEd, uint8 rawLen) public {
        uint8 scheme = useEd ? SCHEME_ED25519 : SCHEME_ECDSA;
        uint256 correct = useEd ? 32 : 20;
        uint256 len = bound(rawLen, 0, 96);
        vm.assume(len != correct);

        bytes memory data = abi.encode(scheme, new bytes(len));
        assertFalse(validator.validateConfig(data), "wrong key length is an invalid config");

        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(OP_HASH, _edSig(), data);
    }

    // ═══════════════════════════════════ P-05 ═══════════════════════════════════

    /**
     * P-05 — §6.3 case 3:
     *
     *     validateConfig(data) reverts  ⇒  validateSignatureWithData(·,·,data) also reverts
     *
     * Both fail at the SAME `abi.decode` step, so neither has a named error and this asserts ONLY
     * that both revert. THIS IS THE SINGLE SELECTOR-LESS expectRevert IN THIS FILE, and it is the
     * documented exception (validator PRD §11 P-05).
     *
     * This is also the counterexample that killed an earlier draft's single-biconditional
     * formulation of the law: garbled `data` satisfies "validateConfig does not return true", yet
     * the runtime reverts with a decode PANIC rather than `MalformedConfig`/`UnsupportedScheme` —
     * so it is not case 2, and the law had to be split into three.
     */
    function test_P05_ValidateConfig_RevertImpliesRuntimeRevert() public {
        bytes[4] memory garbled = [
            bytes(hex""), // empty — no head words at all
            bytes(hex"01"), // one byte
            abi.encodePacked(uint256(1)), // a single word: scheme present, no offset/length
            abi.encodePacked(uint256(0), uint256(type(uint256).max)) // an out-of-bounds offset
        ];

        for (uint256 i; i < garbled.length; ++i) {
            bool configReverted;
            try validator.validateConfig(garbled[i]) returns (bool) {
                configReverted = false;
            } catch {
                configReverted = true;
            }
            if (!configReverted) continue; // not case-3 input; nothing to assert

            vm.expectRevert();
            validator.validateSignatureWithData(OP_HASH, _edSig(), garbled[i]);
        }
    }

    /// The fuzz form of the same implication, so it is not pinned to four hand-picked inputs.
    function testFuzz_P05_RevertImpliesRuntimeRevert(bytes memory data) public view {
        try validator.validateConfig(data) returns (bool) {
            return; // did not revert — outside case 3
        } catch { }

        (bool ok,) = address(validator)
            .staticcall(abi.encodeWithSelector(validator.validateSignatureWithData.selector, OP_HASH, _edSig(), data));
        assertFalse(ok, "validateConfig reverting implies the runtime reverts too");
    }

    // ═══════════════════════════════════ P-03 ═══════════════════════════════════

    /**
     * P-03 ⚠️ BLOCKS TESTNET — the only test of the TRUE call path.
     *
     * Every other Ed25519 test in this file etches or strips code at USV, so the real precompile
     * has never been exercised. This is the project's highest-value remaining verification item
     * (§9 row 3, which names this test, as this test names it back).
     *
     * ENV-GATED, deliberately, rather than a bare `vm.skip(true)`: a fork test cannot run without
     * an RPC by construction, so nothing is skipped by a flag someone has to remember to flip.
     *
     * THE ONLY BLOCKER IS `PUSH_TESTNET_RPC`. The vector below is NOT a node-team dependency —
     * Ed25519 is RFC 8032 and `verifyEd25519RawMessage(pubKey, message, sig)` over raw bytes is
     * exactly what any standard library produces, so any correctly generated vector is known-good.
     *
     * WHAT THIS TEST ACTUALLY DECIDES, and why it is the highest-value item left. Two independent
     * assumptions sit under the Ed25519 branch and NEITHER is exercised by anything deployed:
     *   · the ADDRESS `0xEC00…0001`, taken from the docs address book;
     *   · the METHOD `verifyEd25519RawMessage(bytes,bytes,bytes)`, taken from IUSigVerifier NatSpec.
     * The only production caller of a Push Ed25519 precompile that exists in any repo we hold —
     * the audited `UEA_SVM.sol:42,167-171` — uses a DIFFERENT address (`0x…00ca`) and a DIFFERENT
     * method (`verifyEd25519(bytes,bytes32,bytes)`). If either of our assumptions is wrong the
     * failure is SILENT: every Ed25519 signature returns false, fail-closed, and a Solana-keyed
     * agent is simply dead. This test is what converts that silent failure into a loud one.
     */
    bytes internal constant P03_PUBKEY = hex"122663464c1abd4b4ba8f59952c161c23a48cc9fba7efd1f92b0b164dc8b030a";
    bytes32 internal constant P03_MESSAGE = hex"600b7dd903678cd59d002ff53b924e7df635300a6ea161b07df6b64464319d5d";
    bytes internal constant P03_SIGNATURE =
        hex"e57bf5b55d22b266a8bf0c5a24507335b6fe985aa824a96c3952ea5293ef6bf7c34952625a1b16c20f9be0314487b1ae79e85d38e811b617811aceed6e768f04";

    function test_V11_ed25519AgainstRealPrecompile() public {
        string memory rpc = vm.envOr("PUSH_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "P-03 requires PUSH_TESTNET_RPC - not set");
        }

        vm.createSelectFork(rpc);

        // DEPLOY AFTER THE FORK. `validator` comes from setUp(), and createSelectFork switches to a
        // fresh fork state where that deployment does not exist — only the test contract is
        // persistent by default. Calling the setUp() instance here would be a high-level call to a
        // codeless address and would revert with an EVM error before the vector was ever tested.
        // Deploying fresh also means this proves the contract AS DEPLOYED, with nothing carried
        // across from local state.
        PushSessionValidator live = new PushSessionValidator();

        // THE PRECOMPILE IS CODELESS, AND THAT IS THE POINT — asserted rather than assumed.
        // `extcodesize(USV) == 0` is the entire reason the raw staticcall exists (IUSigVerifier.sol
        // :9-11), and it is the fact P-04 depends on. An earlier version of this test asserted the
        // opposite (`assertGt(..., 0)`), which would have failed here first, with a message saying
        // the reverse of the truth.
        assertEq(USV.code.length, 0, "precompile is codeless - the raw-staticcall reason");

        bytes memory data = abi.encode(SCHEME_ED25519, P03_PUBKEY);

        // ACCEPT the known-good vector. This is what proves the ADDRESS and the METHOD are both
        // right — a wrong address or wrong selector yields a failed staticcall, hence `false`.
        assertTrue(
            live.validateSignatureWithData(P03_MESSAGE, P03_SIGNATURE, data),
            "the live precompile verifies a known-good vector"
        );

        // REJECT a corrupted one. Without this, a precompile that returned true unconditionally —
        // or an address that happens to answer anything — would pass the assertion above.
        bytes memory corrupted = P03_SIGNATURE;
        corrupted[0] = bytes1(uint8(corrupted[0]) ^ 0x01);
        assertFalse(
            live.validateSignatureWithData(P03_MESSAGE, corrupted, data),
            "the live precompile rejects a corrupted signature"
        );
    }
}

/// @dev Deployed only via vm.etch. Returns fewer than 32 bytes, so the validator's
///      `ret.length < 32` fail-closed guard is reachable. Observer, never oracle.
contract ShortReturnObserver {
    fallback(bytes calldata) external returns (bytes memory) {
        return hex"01";
    }
}
