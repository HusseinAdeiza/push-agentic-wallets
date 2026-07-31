// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { MockUSV } from "../mocks/Mocks.sol";

/// @notice PRD §11.3 — unit tests V-01 … V-11.
contract PushSessionValidatorTest is Test {
    PushSessionValidator internal validator;
    MockUSV internal usv;

    address internal constant USV_ADDR = 0xEC00000000000000000000000000000000000001;

    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    function setUp() public {
        validator = new PushSessionValidator();
        signer = vm.addr(signerPk);

        usv = new MockUSV();
        vm.etch(USV_ADDR, address(usv).code);
    }

    function _ecdsaConfig(address a) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), abi.encodePacked(a));
    }

    function _ed25519Config(bytes32 pubKey) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), abi.encodePacked(pubKey));
    }

    function _setUsvResult(bool r) internal {
        vm.store(USV_ADDR, bytes32(uint256(0)), bytes32(uint256(r ? 1 : 0)));
    }

    // ── V-01 … V-04 — ECDSA ───────────────────────────────────────────

    function test_V01_ecdsaValidSignature() public view {
        bytes32 hash = keccak256("op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertTrue(validator.validateSignatureWithData(hash, sig, _ecdsaConfig(signer)));
    }

    function test_V02_ecdsaWrongKeyReturnsFalse() public view {
        bytes32 hash = keccak256("op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertFalse(validator.validateSignatureWithData(hash, sig, _ecdsaConfig(address(0xBAD))));
    }

    function test_V02b_ecdsaWrongHashReturnsFalse() public view {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, keccak256("op"));
        bytes memory sig = abi.encodePacked(r, s, v);

        assertFalse(validator.validateSignatureWithData(keccak256("other"), sig, _ecdsaConfig(signer)));
    }

    /// V-03 — a malformed signature must return false, never revert.
    function test_V03_ecdsaMalformedSignatureReturnsFalse() public view {
        bytes memory sig64 = new bytes(64);
        assertFalse(validator.validateSignatureWithData(keccak256("op"), sig64, _ecdsaConfig(signer)));

        bytes memory sigEmpty = "";
        assertFalse(validator.validateSignatureWithData(keccak256("op"), sigEmpty, _ecdsaConfig(signer)));
    }

    /// V-03b — a 65-byte but cryptographically invalid signature returns false, not revert.
    function test_V03b_ecdsaInvalidRecoveryReturnsFalse() public view {
        bytes memory sig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        assertFalse(validator.validateSignatureWithData(keccak256("op"), sig, _ecdsaConfig(signer)));
    }

    function test_V04_ecdsaBadConfigLengthReverts() public {
        bytes memory badCfg = abi.encode(uint8(0), abi.encodePacked(bytes19(0)));
        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(keccak256("op"), new bytes(65), badCfg);
    }

    // ── V-05 … V-08 — Ed25519 ─────────────────────────────────────────

    function test_V05_ed25519ValidSignature() public {
        _setUsvResult(true);
        bytes32 pubKey = keccak256("pubkey");
        assertTrue(validator.validateSignatureWithData(keccak256("op"), new bytes(64), _ed25519Config(pubKey)));
    }

    function test_V06_ed25519InvalidSignature() public {
        _setUsvResult(false);
        bytes32 pubKey = keccak256("pubkey");
        assertFalse(validator.validateSignatureWithData(keccak256("op"), new bytes(64), _ed25519Config(pubKey)));
    }

    function test_V07_ed25519BadConfigLengthReverts() public {
        bytes memory badCfg = abi.encode(uint8(1), abi.encodePacked(bytes31(0)));
        vm.expectRevert(PushSessionValidator.MalformedConfig.selector);
        validator.validateSignatureWithData(keccak256("op"), new bytes(64), badCfg);
    }

    function test_V08_ed25519BadSignatureLengthReturnsFalse() public {
        _setUsvResult(true);
        bytes32 pubKey = keccak256("pubkey");
        assertFalse(
            validator.validateSignatureWithData(keccak256("op"), new bytes(63), _ed25519Config(pubKey)),
            "63-byte sig must fail"
        );
        assertFalse(
            validator.validateSignatureWithData(keccak256("op"), new bytes(65), _ed25519Config(pubKey)),
            "65-byte sig must fail"
        );
    }

    /// D-18 — the raw-message variant is used, with message = the 32 bytes of hash.
    function test_ed25519UsesRawMessageVariant() public {
        bytes32 hash = keccak256("op");
        bytes32 pubKey = keccak256("pubkey");
        bytes memory sig = new bytes(64);

        vm.expectCall(
            USV_ADDR,
            abi.encodeWithSignature(
                "verifyEd25519RawMessage(bytes,bytes,bytes)", abi.encodePacked(pubKey), abi.encodePacked(hash), sig
            )
        );
        _setUsvResult(true);
        validator.validateSignatureWithData(hash, sig, _ed25519Config(pubKey));
    }

    /**
     * V-12 — REGRESSION GUARD for C-1. Must not use vm.etch.
     *
     * A precompile has NO bytecode. A high-level interface call inserts an
     * `extcodesize(target) > 0` check and reverts when the target is empty, so the
     * Ed25519 path was non-functional on the real chain while every mocked test
     * passed. The mock did not merely fail to prove the real path — it masked the bug.
     *
     * With the raw staticcall, an empty target must FAIL CLOSED (return false),
     * never revert. This test fails against the pre-fix implementation.
     */
    function test_V12_C1_ed25519FailsClosedWhenUSVHasNoCode() public {
        // setUp() etches a mock at USV for the rest of the suite. Strip it here to
        // reproduce the real-chain condition: a precompile address with no bytecode.
        PushSessionValidator fresh = new PushSessionValidator();
        address usvAddr = fresh.USV();
        vm.etch(usvAddr, "");

        uint256 codeLen;
        assembly {
            codeLen := extcodesize(usvAddr)
        }
        assertEq(codeLen, 0, "precondition: USV must have no code for this test to mean anything");

        bool result =
            fresh.validateSignatureWithData(keccak256("op"), new bytes(64), _ed25519Config(keccak256("pubkey")));
        assertFalse(result, "must fail closed, not revert");
    }

    /// V-12b — the ECDSA path is unaffected by USV having no code.
    function test_V12b_ecdsaUnaffectedByMissingUSV() public {
        PushSessionValidator fresh = new PushSessionValidator();
        bytes32 hash = keccak256("op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, hash);
        assertTrue(fresh.validateSignatureWithData(hash, abi.encodePacked(r, s, v), _ecdsaConfig(signer)));
    }

    // ── V-09 / V-10 ───────────────────────────────────────────────────

    function test_V09_unknownSchemeReverts() public {
        bytes memory cfg = abi.encode(uint8(2), abi.encodePacked(bytes20(0)));
        vm.expectRevert(abi.encodeWithSelector(PushSessionValidator.UnsupportedScheme.selector, uint8(2)));
        validator.validateSignatureWithData(keccak256("op"), new bytes(65), cfg);
    }

    function test_V10_isModuleType() public view {
        assertTrue(validator.isModuleType(7));
        assertFalse(validator.isModuleType(1));
        assertFalse(validator.isModuleType(2));
        assertFalse(validator.isModuleType(4));
        assertFalse(validator.isModuleType(0));
    }

    function test_statelessLifecycleIsNoop() public view {
        assertTrue(validator.isInitialized(address(0)));
        assertTrue(validator.isInitialized(address(0xB0B)));
    }

    function test_onInstallOnUninstallAreNoops() public view {
        validator.onInstall("");
        validator.onUninstall("");
        validator.onInstall(hex"deadbeef");
        validator.onUninstall(hex"deadbeef");
    }

    function test_constants() public view {
        assertEq(validator.USV(), USV_ADDR);
        assertEq(validator.SCHEME_ECDSA(), 0);
        assertEq(validator.SCHEME_ED25519(), 1);
    }

    /// The validator holds no storage — one deployment serves every account.
    function test_holdsNoStorage() public view {
        for (uint256 i; i < 8; ++i) {
            assertEq(vm.load(address(validator), bytes32(i)), bytes32(0));
        }
    }
}
