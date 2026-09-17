// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { OP_HASH_DOMAIN } from "../../src/libraries/PushWalletTypes.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

import { AgentSigning } from "../lib/AgentSigning.sol";

/**
 * @title  AgentSigningTest
 * @notice The equivalence proof for the op hash, and the structural claim that native mode reuses
 *         the cross-chain demo's signing layer UNCHANGED.
 *
 * @dev    TWO THINGS ARE PROVEN HERE, and the second is the interesting one.
 *
 *         1. `AgentSigning.opHash` equals an INDEPENDENT reimplementation of the wallet's ten-field
 *            hash. `_expected` spells the fields out literally rather than calling the library
 *            again — a test where both sides are the library asserts only that a function equals
 *            itself.
 *
 *         2. `demo-native/lib/AgentSigning.sol` is BYTE-IDENTICAL to `demo/lib/AgentSigning.sol`.
 *            That is a claim about the ARCHITECTURE, not about this folder: the agent-authorisation
 *            layer is mode-independent, so a native request and a cross-chain request are signed by
 *            the same code. If someone forks this file to make native mode work, the two modes have
 *            diverged somewhere they should not have, and this test is what says so.
 */
contract AgentSigningTest is Test {
    uint256 internal constant CHAIN_ID = 42101;

    address internal wallet = makeAddr("agw");
    address internal validator = makeAddr("engine");
    address internal stakeDummy = makeAddr("stakeDummy");
    address internal agent = makeAddr("agent");

    bytes32 internal permissionId = keccak256("permission");
    bytes32 internal mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    uint192 internal nonceKey = 0;
    uint64 internal nonceSeq = 3;
    uint48 internal requestExpiry = uint48(1_800_000_000);

    /// @dev The independent oracle: the ten fields, written out, in the order the wallet uses.
    function _expected(bytes memory executionCalldata, uint192 key, uint64 seq, uint48 expiry)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN,
                CHAIN_ID,
                wallet,
                validator,
                permissionId,
                mode,
                keccak256(executionCalldata),
                key,
                seq,
                expiry
            )
        );
    }

    /// @dev A native execution: ONE layer, straight at the target. No gateway, no outbound, no
    ///      multicall — the whole difference between the two demos, in one line.
    function _nativeCalldata() internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            stakeDummy, 0, abi.encodeWithSignature("stakeFor(address,uint256)", wallet, uint256(25e6))
        );
    }

    function test_opHash_matchesTheTenFieldOracle() public view {
        bytes memory cd = _nativeCalldata();
        assertEq(
            AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, cd, nonceKey, nonceSeq, requestExpiry),
            _expected(cd, nonceKey, nonceSeq, requestExpiry),
            "the op hash drifted from the ten-field layout"
        );
    }

    /// @dev Field 9. A different sequence must produce a different hash, or replay protection is
    ///      decorative.
    function test_opHash_bindsTheNonceSequence() public view {
        bytes memory cd = _nativeCalldata();
        assertTrue(
            AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, cd, nonceKey, 0, requestExpiry)
                != AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, cd, nonceKey, 1, requestExpiry),
            "two sequences produced one hash"
        );
    }

    /// @dev Field 8. Lanes are independent, so the same sequence on a different lane is a different
    ///      request — the property that lets the unstake mandate use lane 1 safely.
    function test_opHash_bindsTheNonceLane() public view {
        bytes memory cd = _nativeCalldata();
        assertTrue(
            AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, cd, 0, 0, requestExpiry)
                != AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, cd, 1, 0, requestExpiry),
            "two lanes produced one hash"
        );
    }

    /// @dev Field 5 — what makes a banked request die on revocation, and the basis of Act 4e.
    function test_opHash_bindsThePermissionId() public view {
        bytes memory cd = _nativeCalldata();
        bytes32 a = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, permissionId, mode, cd, nonceKey, nonceSeq, requestExpiry
        );
        bytes32 b = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, keccak256("other"), mode, cd, nonceKey, nonceSeq, requestExpiry
        );
        assertTrue(a != b, "the permission id is not bound into the hash");
    }

    /**
     * @dev Field 7 covers the payload to the last byte — including the BENEFICIARY WORD.
     *
     *      This is the signing-layer half of G3: changing only the beneficiary changes the hash, so
     *      a relayer cannot take a valid request and redirect it. The policy's pin is the other
     *      half, and neither alone is sufficient.
     */
    function test_opHash_bindsTheBeneficiaryWord() public view {
        bytes memory honest = _nativeCalldata();
        bytes memory redirected = ExecutionLib.encodeSingle(
            stakeDummy, 0, abi.encodeWithSignature("stakeFor(address,uint256)", agent, uint256(25e6))
        );

        assertTrue(
            AgentSigning.opHash(
                CHAIN_ID, wallet, validator, permissionId, mode, honest, nonceKey, nonceSeq, requestExpiry
            )
            != AgentSigning.opHash(
                CHAIN_ID, wallet, validator, permissionId, mode, redirected, nonceKey, nonceSeq, requestExpiry
            ),
            "the beneficiary is not covered by the signature"
        );
    }

    /// @dev The envelope the agent door parses: 1 mode byte + 32-byte permission id + 65-byte sig.
    function test_envelope_shape() public view {
        bytes memory sig = AgentSigning.envelope(permissionId, new bytes(65));
        assertEq(sig.length, 98, "the envelope must be 98 bytes");
        assertEq(uint8(sig[0]), AgentSigning.MODE_USE, "byte 0 must be SmartSessionMode.USE");

        bytes32 embedded;
        for (uint256 i; i < 32; ++i) {
            embedded |= bytes32(sig[1 + i]) >> (i * 8);
        }
        assertEq(embedded, permissionId, "bytes 1:33 must be the permission id");
    }

    /**
     * @notice ⚠️ THE STRUCTURAL CLAIM: this file's `AgentSigning` is byte-identical to the
     *         cross-chain demo's.
     *
     * @dev    Reads both files and compares their hashes. If this fails, someone forked the signing
     *         layer for native mode — which means the two mandate types no longer share an
     *         authorisation path, and that is a finding to report rather than a test to update.
     */
    function test_agentSigningIsByteIdenticalToTheCrossChainDemo() public view {
        bytes32 native_ = keccak256(bytes(vm.readFile("demo-native/lib/AgentSigning.sol")));
        bytes32 crossChain = keccak256(bytes(vm.readFile("demo/lib/AgentSigning.sol")));
        assertEq(native_, crossChain, "AgentSigning.sol has been forked - the two modes have diverged");
    }
}
