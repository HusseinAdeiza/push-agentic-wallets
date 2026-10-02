// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AgentValidatorErrors } from "../../src/libraries/Errors.sol";
import { AgentConfigLib } from "../../src/libraries/AgentConfigLib.sol";

import { BaseTest } from "../Base.t.sol";
import { AgentValidator } from "../../src/validators/AgentValidator.sol";
import { IAgentValidator } from "../../src/interfaces/IAgentValidator.sol";

import { SmartSessionMode } from "smartsessions/DataTypes.sol";

/**
 * @notice AgentValidator acceptance suite — the sender validator.
 *
 * @dev    The validator's config is the agent's Push address, `abi.encode(address agent)`, and the
 *         "signature" the engine hands it is the 20-byte sender the wallet wrote into the operation.
 *         It verifies no cryptographic signature: external keys are verified by the agent's UEA.
 *
 * @dev    No selector-less `vm.expectRevert()` exists in this file. Every negative test names its
 *         error; `validateConfig` is two-valued and never reverts.
 */
contract PushSessionValidatorTest is BaseTest {
    /// @dev Any hash: the validator ignores it, which `testFuzz_SV05_hashIsIgnored` proves.
    bytes32 internal constant ANY_HASH = keccak256("any operation hash");

    // ───────────────────────────────── helpers ─────────────────────────────────

    /// @dev One ABI word with a non-zero top byte and `a` in the low 160 bits — dirty upper bytes.
    function _dirtyWord(address a) internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(0xff) << 248 | uint256(uint160(a)));
    }

    /// @dev Every malformed config the PRD names, in one list.
    function _malformedConfigs() internal view returns (bytes[] memory list) {
        list = new bytes[](7);
        list[0] = "";
        list[1] = new bytes(31);
        list[2] = new bytes(33);
        list[3] = abi.encode(address(0));
        list[4] = abi.encode(AGENT, AGENT);
        list[5] = _dirtyWord(AGENT);
        list[6] = abi.encode(uint8(0), abi.encodePacked(AGENT)); // the pre-D3 ECDSA config
    }

    // ═════════════════════════════ the sender check — SV01…SV05 ═════════════════════════════

    function test_SV01_agentSenderValidates() public view {
        assertTrue(
            validator.validateSignatureWithData(ANY_HASH, abi.encodePacked(AGENT), agentConfig(AGENT)),
            "the configured agent as sender validates"
        );
    }

    function test_SV02_wrongSenderReturnsFalse() public {
        assertFalse(
            validator.validateSignatureWithData(ANY_HASH, abi.encodePacked(makeAddr("other")), agentConfig(AGENT)),
            "another sender returns FALSE, not revert"
        );
    }

    function testFuzz_SV02_anySenderButTheAgentReturnsFalse(address s) public view {
        vm.assume(s != AGENT);
        assertFalse(
            validator.validateSignatureWithData(ANY_HASH, abi.encodePacked(s), agentConfig(AGENT)),
            "only the agent validates"
        );
    }

    /// A sender blob of any length but 20 returns FALSE — including the full 53-byte blob the wallet
    /// writes into the operation, which the engine strips to its last 20 bytes before calling here.
    function test_SV03_sigLengthNot20ReturnsFalse() public view {
        bytes memory config = agentConfig(AGENT);
        bytes memory fullBlob = abi.encodePacked(SmartSessionMode.USE, keccak256("pid"), AGENT);
        assertEq(fullBlob.length, 53, "mode byte, rules id, sender");

        assertFalse(validator.validateSignatureWithData(ANY_HASH, "", config), "0 bytes");
        assertFalse(validator.validateSignatureWithData(ANY_HASH, new bytes(19), config), "19 bytes");
        assertFalse(validator.validateSignatureWithData(ANY_HASH, abi.encodePacked(AGENT, hex"00"), config), "21");
        assertFalse(validator.validateSignatureWithData(ANY_HASH, abi.encode(AGENT), config), "32 bytes");
        assertFalse(validator.validateSignatureWithData(ANY_HASH, fullBlob, config), "53 bytes");
    }

    /// A malformed config REVERTS `MalformedConfig` — the owner's session is broken, so it is loud.
    function test_SV04_malformedConfigReverts() public {
        bytes[] memory configs = _malformedConfigs();
        for (uint256 i; i < configs.length; ++i) {
            vm.expectRevert(AgentValidatorErrors.MalformedConfig.selector);
            validator.validateSignatureWithData(ANY_HASH, abi.encodePacked(AGENT), configs[i]);
        }
    }

    function testFuzz_SV04_malformedConfigAlwaysReverts(bytes memory data, bytes memory sig) public {
        vm.assume(AgentConfigLib.decode(data) == address(0));
        vm.expectRevert(AgentValidatorErrors.MalformedConfig.selector);
        validator.validateSignatureWithData(ANY_HASH, sig, data);
    }

    function testFuzz_SV05_hashIsIgnored(bytes32 h) public view {
        assertTrue(
            validator.validateSignatureWithData(h, abi.encodePacked(AGENT), agentConfig(AGENT)),
            "the verdict never depends on the hash"
        );
    }

    // ══════════════════════════ validateConfig — SV06 ══════════════════════════

    function testFuzz_SV06_validateConfigNeverReverts(bytes memory data) public view {
        bool ok = validator.validateConfig(data); // a revert here fails the test
        assertEq(ok, AgentConfigLib.decode(data) != address(0), "two-valued, and equal to the shared decoder");
    }

    // ═══════════════════ the validator calls nothing — SV07 ═══════════════════

    /**
     * SV07 ⚠️ NEVER-DELETE — the successor of P-04, the regression guard for the shipped critical bug.
     *
     * That bug was a call to a codeless address (the Ed25519 precompile) through a typed interface:
     * solc's `extcodesize` check made the branch revert on the real chain while every test, which
     * etched code at the address, passed. The validator now makes no call at all, and this proves it
     * from solc's own ABI output: both entry points are `pure`, and a `pure` function cannot make an
     * external call. No precompile, oracle or contract can ever influence the agent check, so that
     * class of bug is unreachable by construction.
     */
    function test_SV07_validatorCallsNothing() public view {
        string memory artifact = vm.readFile("out/AgentValidator.sol/AgentValidator.json");

        uint256 found;
        for (uint256 i; vm.keyExistsJson(artifact, string.concat(".abi[", vm.toString(i), "]")); ++i) {
            string memory base = string.concat(".abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(artifact, string.concat(base, ".type")))) != keccak256("function")) {
                continue;
            }
            bytes32 name = keccak256(bytes(vm.parseJsonString(artifact, string.concat(base, ".name"))));
            if (name != keccak256("validateSignatureWithData") && name != keccak256("validateConfig")) continue;

            assertEq(
                vm.parseJsonString(artifact, string.concat(base, ".stateMutability")),
                "pure",
                "the agent check must be pure: no external call can reach it"
            );
            ++found;
        }
        assertEq(found, 2, "both entry points were found and checked");
    }

    // ═══════════════════════ the exact surface — SV08 ═══════════════════════

    function test_SV08_exactSelectorSet() public view {
        bytes4[] memory expected = new bytes4[](6);
        expected[0] = AgentValidator.validateSignatureWithData.selector;
        expected[1] = IAgentValidator.validateConfig.selector;
        expected[2] = AgentValidator.onInstall.selector;
        expected[3] = AgentValidator.onUninstall.selector;
        expected[4] = AgentValidator.isModuleType.selector;
        expected[5] = AgentValidator.isInitialized.selector;
        assertSelectorSet("AgentValidator", expected);
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

    // ════════════════════════════════ statelessness ════════════════════════════════

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
     * THE STATELESSNESS INVARIANT, asserted against the BUILD ARTIFACT.
     *
     * A `vm.load` slot read is NOT acceptable here and the helper's docblock explains why: reading
     * chosen slots and asserting zero is equally satisfied by a contract that declares variables
     * and never writes them — a test that cannot fail. This asserts solc's own storageLayout is
     * empty, which is the only form that actually fails when storage is added.
     */
    function test_holdsNoStorage() public view {
        assertEmptyStorageLayout("AgentValidator");
    }

    // ═══════════════════════════════════ P-01 ═══════════════════════════════════

    /**
     * P-01 — the consistency law between the grant-time check and the runtime check:
     *
     *     validateConfig(data) == true  ⟺  validateSignatureWithData(·,·,data) does not revert
     *
     * A non-reverting runtime call returning FALSE is a sender mismatch, not a config failure, and is
     * outside this law — so the assertion is on revert/no-revert, never on the returned bool.
     *
     * `shape` picks the input space so every branch of the decoder is reached: fully random bytes
     * (almost always the wrong length), a random 32-byte word (almost always dirty upper bytes), and
     * a clean address word (well-formed, or zero). `test_P01_LawOnKnownInputs` pins the same law on
     * fixed inputs so a seed change cannot silently lose coverage.
     */
    function testFuzz_P01_ValidateConfig_MatchesRuntime(bytes memory raw, uint256 word, uint8 shape, bytes memory sig)
        public
        view
    {
        bytes memory data;
        if (shape % 3 == 0) data = raw;
        else if (shape % 3 == 1) data = abi.encodePacked(bytes32(word));
        // forge-lint: disable-next-line(unsafe-typecast)
        else data = abi.encodePacked(uint256(uint160(word))); // truncation intended: a clean address word

        bool configSaysValid = validator.validateConfig(data);

        bool runtimeReverted;
        try validator.validateSignatureWithData(ANY_HASH, sig, data) returns (bool) {
            runtimeReverted = false;
        } catch {
            runtimeReverted = true;
        }

        assertEq(configSaysValid, !runtimeReverted, "validateConfig == true  <=>  the runtime does not revert");
    }

    /// The law's two directions, pinned on hand-built inputs so a fuzz seed change cannot lose them.
    function test_P01_LawOnKnownInputs() public {
        bytes memory sig = abi.encodePacked(AGENT);

        // true => does not revert
        assertTrue(validator.validateConfig(agentConfig(AGENT)), "abi.encode(AGENT) is a valid config");
        validator.validateSignatureWithData(ANY_HASH, sig, agentConfig(AGENT));

        // false => reverts, named
        bytes[] memory configs = new bytes[](6);
        configs[0] = abi.encode(address(0));
        configs[1] = "";
        configs[2] = new bytes(31);
        configs[3] = new bytes(33);
        configs[4] = abi.encode(AGENT, AGENT);
        configs[5] = _dirtyWord(AGENT);
        for (uint256 i; i < configs.length; ++i) {
            assertFalse(validator.validateConfig(configs[i]), "malformed config is invalid");
            vm.expectRevert(AgentValidatorErrors.MalformedConfig.selector);
            validator.validateSignatureWithData(ANY_HASH, sig, configs[i]);
        }
    }
}
