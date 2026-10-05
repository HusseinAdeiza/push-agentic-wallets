// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PushChainLib } from "../../src/libraries/PushChainLib.sol";
import { RulesType } from "../../src/libraries/Types.sol";

/**
 * @title  PushChainLib — the mode derivation, and the formula it rests on.
 *
 * @notice Two contracts derive one mandate's mode from one string. This suite pins the string, the
 *         formula that hashes it, and the rule that maps it to a rulebook. If any of the three
 *         moves, a mandate silently changes kind — which is the one failure this design cannot
 *         detect at runtime, because both contracts would move together.
 *
 * @dev    THE LIBRARY IS `internal`, so it is exercised through a harness contract rather than
 *         called directly. That also proves the thing production cares about: the value as seen
 *         from inside a contract's own frame, where `block.chainid` is whatever the chain says.
 */
contract ChainLibHarness {
    function selfChainHash() external view returns (bytes32) {
        return PushChainLib.selfChainHash();
    }

    function deriveMode(bytes32 chainHash) external view returns (RulesType) {
        return PushChainLib.deriveMode(chainHash);
    }

    function gasOfSelfChainHash() external view returns (uint256 used) {
        uint256 g0 = gasleft();
        bytes32 h = PushChainLib.selfChainHash();
        used = g0 - gasleft();
        h; // silence the unused warning without changing what was measured
    }
}

contract PushChainLibTest is Test {
    ChainLibHarness internal lib;

    /// @dev Measured with `cast keccak "eip155:42101"`, and independently by the architecture review.
    bytes32 internal constant DONUT_PIN = 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9;
    /// @dev `cast keccak "eip155:11155111"`.
    bytes32 internal constant SEPOLIA_PIN = 0xafa90c317deacd3d68f330a30f96e4fa7736e35e8d1426b2e1b2c04bce1c2fb7;
    /// @dev `cast keccak "eip155:1"`.
    bytes32 internal constant MAINNET_PIN = 0x38b2caf37cccf00b6fbc0feb1e534daf567950e4d48066d0e3669028fe5f83e6;

    function setUp() public {
        lib = new ChainLibHarness();
    }

    /**
     * The Donut value, against a LITERAL taken from `cast`, not recomputed from the formula.
     *
     * An assertion that rebuilt the string with `string.concat` and hashed it would agree with the
     * implementation by construction and prove nothing — it would pass just as happily if both were
     * wrong. The literal is what makes this a pin: change the formula and this breaks.
     */
    function test_ChainLib_selfChainHash_matchesDonutPin() public {
        vm.chainId(42_101);
        assertEq(lib.selfChainHash(), DONUT_PIN, "Donut's CAIP-2 hash");
    }

    /// The same formula on two other chains, so the pin above is not a coincidence of one value.
    function test_ChainLib_selfChainHash_sepoliaAndMainnet() public {
        vm.chainId(11_155_111);
        assertEq(lib.selfChainHash(), SEPOLIA_PIN, "Sepolia");

        vm.chainId(1);
        assertEq(lib.selfChainHash(), MAINNET_PIN, "Ethereum mainnet");
    }

    /// The whole rule: this chain is NATIVE, every other chain is UNIVERSAL.
    function test_ChainLib_deriveMode_pushIsNative_othersUniversal() public {
        vm.chainId(42_101);

        assertEq(uint8(lib.deriveMode(DONUT_PIN)), uint8(RulesType.NATIVE), "this chain is native");
        assertEq(uint8(lib.deriveMode(SEPOLIA_PIN)), uint8(RulesType.UNIVERSAL), "Sepolia is universal");
        assertEq(uint8(lib.deriveMode(MAINNET_PIN)), uint8(RulesType.UNIVERSAL), "mainnet is universal");
        assertEq(uint8(lib.deriveMode(bytes32(0))), uint8(RulesType.UNIVERSAL), "an unknown chain is universal");
    }

    /**
     * The derivation FOLLOWS the chain rather than naming it.
     *
     * The same hash means NATIVE on one chain and UNIVERSAL on another. That is the property that
     * makes `PUSH_CHAIN_HASH` unnecessary: there is no constant to configure, so there is no constant
     * to configure wrongly, and a fork moves both contracts together.
     */
    function test_ChainLib_deriveMode_followsTheChain() public {
        vm.chainId(42_101);
        assertEq(uint8(lib.deriveMode(DONUT_PIN)), uint8(RulesType.NATIVE), "native on Donut");

        vm.chainId(1);
        assertEq(uint8(lib.deriveMode(DONUT_PIN)), uint8(RulesType.UNIVERSAL), "the same hash, universal on mainnet");
        assertEq(uint8(lib.deriveMode(MAINNET_PIN)), uint8(RulesType.NATIVE), "and mainnet is now the native one");
    }

    /**
     * ⚠️ THE FORMULA IS THE COLON STRING, NOT THE UEAFACTORY TWO-STRING FORM.
     *
     * `keccak256(abi.encode("eip155", "42101"))` is a DIFFERENT value for the same chain, and it is
     * the formula core's `UEAFactory` uses to derive UEA addresses. Both live in this ecosystem and
     * they must never be conflated: before this change a since-removed `Config` chain field had acquired FOUR
     * different conventions across the repo — the colon form, the two-string form, a packed form,
     * and plain zero — precisely because nothing ever compared the field.
     *
     * This test exists to fail if someone "harmonises" the two.
     */
    function test_ChainLib_notTheTwoStringFormula() public {
        vm.chainId(42_101);

        bytes32 ueaFactoryForm = keccak256(abi.encode("eip155", "42101"));
        assertTrue(lib.selfChainHash() != ueaFactoryForm, "the two chain-hash conventions must stay distinct");

        // And the one this system uses is the colon form.
        assertEq(lib.selfChainHash(), keccak256(bytes("eip155:42101")), "colon form");
    }

    /**
     * Case and padding are NOT normalised, deliberately.
     *
     * The hash comparison is the entire rule. A string parser in the wallet would be a second
     * rulebook and a heuristic — the same objection that keeps URP's decoder from guessing at
     * malformed `initData`. A near-miss string derives UNIVERSAL and is then refused against the
     * action targets with a named error, which is a worse diagnostic but a safer contract.
     */
    function test_ChainLib_nearMissStringsAreNotThisChain() public {
        vm.chainId(42_101);

        assertTrue(lib.selfChainHash() != keccak256(bytes("EIP155:42101")), "uppercase namespace is a different chain");
        assertTrue(lib.selfChainHash() != keccak256(bytes("eip155:042101")), "a leading zero is a different chain");
        assertTrue(lib.selfChainHash() != keccak256(bytes(" eip155:42101")), "whitespace is a different chain");
        assertTrue(lib.selfChainHash() != keccak256(bytes("eip155:42101 ")), "trailing whitespace too");
    }

    /// Cost, on the record: called once per grant and once per config init, never at runtime.
    function test_ChainLib_gas() public {
        vm.chainId(42_101);
        uint256 used = lib.gasOfSelfChainHash();
        assertLt(used, 3000, "selfChainHash stays cheap enough to call twice per grant");
    }
}
