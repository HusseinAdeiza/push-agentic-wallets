// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { ACPActionPolicy } from "../../src/policies/ACPActionPolicy.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import {
    ModeLib,
    ModeCode,
    CallType,
    ExecType,
    ModePayload,
    ModeSelector,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT
} from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { MockValidator, MockTarget } from "../mocks/Mocks.sol";

/// @dev Exposes the internals under test.
contract HashHarness {
    bytes32 internal constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v1");

    function computeOpHash(
        address wallet,
        address validator,
        ModeCode mode,
        bytes memory executionCalldata,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint256 chainId
    ) external pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN,
                chainId,
                wallet,
                validator,
                ModeCode.unwrap(mode),
                keccak256(executionCalldata),
                nonceKey,
                nonceSeq
            )
        );
    }
}

/// @dev Mirrors ACPActionPolicy._extractBeneficiary for bounds fuzzing (F-02).
contract ExtractHarness {
    error MalformedInnerCalldata();

    function extract(bytes memory data, uint16 offset) external pure returns (address) {
        if (uint256(offset) + 32 > data.length) revert MalformedInnerCalldata();
        bytes32 word;
        assembly {
            word := mload(add(add(data, 0x20), offset))
        }
        return address(uint160(uint256(word)));
    }
}

/// @notice PRD §11.6 — fuzz properties F-01 … F-04.
contract PushWalletFuzzTest is Test {
    PushAgentWallet internal wallet;
    AgentWalletFactory internal factory;
    MockValidator internal validator;
    MockTarget internal target;
    HashHarness internal hasher;
    ExtractHarness internal extractor;

    address internal ownerUEA = address(0xB0B);

    function setUp() public {
        PushAgentWallet impl = new PushAgentWallet();
        factory = new AgentWalletFactory(address(impl));
        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(keccak256("f"))));

        validator = new MockValidator();
        target = new MockTarget();
        hasher = new HashHarness();
        extractor = new ExtractHarness();

        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");
    }

    /**
     * F-01 — opHash never collides across differing inputs.
     * Any single differing field must produce a different digest.
     */
    struct OpInputs {
        address wallet;
        address validator;
        bytes32 mode;
        bytes cd;
        uint192 key;
        uint64 seq;
    }

    function testFuzz_F01_opHashNeverCollidesAcrossDifferingInputs(OpInputs memory a, OpInputs memory b) public view {
        bytes32 hA = hasher.computeOpHash(a.wallet, a.validator, ModeCode.wrap(a.mode), a.cd, a.key, a.seq, block.chainid);
        bytes32 hB = hasher.computeOpHash(b.wallet, b.validator, ModeCode.wrap(b.mode), b.cd, b.key, b.seq, block.chainid);

        bool sameInputs = a.wallet == b.wallet && a.validator == b.validator && a.mode == b.mode
            && keccak256(a.cd) == keccak256(b.cd) && a.key == b.key && a.seq == b.seq;

        if (sameInputs) {
            assertEq(hA, hB, "identical inputs must hash identically");
        } else {
            assertTrue(hA != hB, "differing inputs must not collide");
        }
    }

    /// F-01b — the chain id is always bound.
    function testFuzz_F01b_opHashBindsChainId(uint256 chainA, uint256 chainB, bytes calldata cd) public view {
        vm.assume(chainA != chainB);
        bytes32 hA = hasher.computeOpHash(address(wallet), address(validator), ModeLib.encodeSimpleSingle(), cd, 0, 0, chainA);
        bytes32 hB = hasher.computeOpHash(address(wallet), address(validator), ModeLib.encodeSimpleSingle(), cd, 0, 0, chainB);
        assertTrue(hA != hB);
    }

    /**
     * F-02 — _extractBeneficiary either reverts or returns a value read from
     * strictly within bounds. It must never read past the end of the blob.
     */
    function testFuzz_F02_extractBeneficiaryStaysInBounds(bytes calldata blob, uint16 offset) public {
        if (uint256(offset) + 32 > blob.length) {
            vm.expectRevert(ExtractHarness.MalformedInnerCalldata.selector);
            extractor.extract(blob, offset);
        } else {
            address a = extractor.extract(blob, offset);
            // The returned address must equal the low 20 bytes of the in-bounds word.
            bytes32 expected;
            bytes memory b = blob;
            assembly {
                expected := mload(add(add(b, 0x20), offset))
            }
            assertEq(a, address(uint160(uint256(expected))));
        }
    }

    /**
     * F-03 — for any mode, execute either succeeds on a supported mode or reverts
     * with a typed error. It must never silently no-op.
     */
    function testFuzz_F03_executeNeverSilentlyNoOps(bytes32 rawMode) public {
        ModeCode mode = ModeCode.wrap(rawMode);
        (CallType ct, ExecType et,,) = ModeLib.decode(mode);

        bytes memory execCd =
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));

        // `execCd` is single-call encoded.
        //   SINGLE+DEFAULT → performs the call.
        //   BATCH+DEFAULT  → ExecutionLib.decodeBatch reads a length of 0 from this
        //                    calldata and returns an empty batch, so execute()
        //                    succeeds while performing NO call. See F-03b and
        //                    DEVIATIONS.md D-4.
        //   anything else  → typed revert.
        bool isSingle = (et == EXECTYPE_DEFAULT) && (ct == CALLTYPE_SINGLE);
        bool isBatch = (et == EXECTYPE_DEFAULT) && (ct == CALLTYPE_BATCH);

        uint256 before = target.callCount();
        vm.prank(ownerUEA);
        try wallet.execute(mode, execCd) {
            assertTrue(isSingle || isBatch, "only supported modes may succeed");
            if (isSingle) {
                assertEq(target.callCount(), before + 1, "SINGLE must perform the call");
            }
        } catch {
            assertFalse(isSingle, "SINGLE+DEFAULT must not revert");
            assertEq(target.callCount(), before, "a revert must leave no partial effect");
        }
    }

    /**
     * F-03b — ⚠ FINDING. Documents a real silent no-op.
     *
     * `ExecutionLib.decodeBatch` (specified verbatim in PRD §9.2) reads the array
     * length straight out of unvalidated calldata via assembly. Given single-call
     * encoded calldata, it decodes a length of 0 and returns an empty batch, so
     * `execute` in BATCH mode completes successfully having performed no call at
     * all — no revert, no effect.
     *
     * Impact is bounded: `mode` and `keccak256(executionCalldata)` are both bound
     * into opHash, so this cannot be used to execute anything unintended. The
     * consequence is that `executeWithSession` consumes a nonce and emits
     * SessionExecuted for an operation that did nothing.
     *
     * Recorded in DEVIATIONS.md D-4 rather than fixed, because §9.2 is specified
     * verbatim and §13.10 forbids unspecified changes.
     */
    function test_F03b_batchModeOnSingleCalldataSilentlyNoOps() public {
        bytes memory singleEncoded =
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));
        ModeCode batchMode = ModeLib.encodeSimpleBatch();

        uint256 before = target.callCount();
        vm.prank(ownerUEA);
        wallet.execute(batchMode, singleEncoded); // succeeds

        assertEq(target.callCount(), before, "no call is performed: the silent no-op");
    }

    /// F-04 — the nonce sequence is strictly monotonic per key.
    function testFuzz_F04_nonceStrictlyMonotonicPerKey(uint192 key, uint8 iterations) public {
        iterations = uint8(bound(iterations, 1, 12));

        uint64 prev = wallet.nonce(key);
        assertEq(prev, 0);

        for (uint64 i; i < iterations; ++i) {
            bytes memory execCd =
                ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (i)));
            wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), execCd, "", key, prev);

            uint64 next = wallet.nonce(key);
            assertEq(next, prev + 1, "must increment by exactly one");
            assertTrue(next > prev, "strictly increasing");
            prev = next;
        }
    }

    /// F-04b — a wrong sequence never advances the nonce.
    function testFuzz_F04b_wrongSeqNeverAdvancesNonce(uint192 key, uint64 wrongSeq) public {
        vm.assume(wrongSeq != 0);
        bytes memory execCd =
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));

        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, key, uint64(0), wrongSeq)
        );
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), execCd, "", key, wrongSeq);

        assertEq(wallet.nonce(key), 0, "nonce must be untouched");
    }

    /// Nonce keys are fully independent of one another.
    function testFuzz_nonceKeysIndependent(uint192 keyA, uint192 keyB) public {
        vm.assume(keyA != keyB);
        bytes memory execCd =
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));

        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), execCd, "", keyA, 0);
        assertEq(wallet.nonce(keyA), 1);
        assertEq(wallet.nonce(keyB), 0, "other keys unaffected");
    }

    /// The factory address derivation is deterministic and collision-free.
    function testFuzz_factoryAddressDeterministic(address owner_, bytes32 mandateA, bytes32 mandateB) public {
        vm.assume(owner_ != address(0));
        vm.assume(mandateA != mandateB);

        address predictedA = factory.computeAgentWallet(owner_, mandateA);
        address predictedB = factory.computeAgentWallet(owner_, mandateB);
        assertTrue(predictedA != predictedB, "distinct mandates must not collide");

        vm.prank(owner_);
        address actual = factory.deployAgentWallet(mandateA);
        assertEq(actual, predictedA);
    }

    /// Only the owner may ever execute directly.
    function testFuzz_onlyOwnerCanExecute(address caller) public {
        vm.assume(caller != ownerUEA && caller != address(wallet));
        bytes memory execCd =
            ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));

        vm.expectRevert(PushWalletErrors.Unauthorized.selector);
        vm.prank(caller);
        wallet.execute(ModeLib.encodeSimpleSingle(), execCd);
    }
}
