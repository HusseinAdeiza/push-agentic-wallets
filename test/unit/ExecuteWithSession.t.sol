// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import {
    ModeLib,
    ModeCode,
    ModePayload,
    CALLTYPE_SINGLE,
    EXECTYPE_DEFAULT,
    MODE_DEFAULT
} from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { MockValidator, MockTarget } from "../mocks/Mocks.sol";

/// @notice PRD §11.2 — unit tests S-01 … S-16 for the native-AA entry point.
contract ExecuteWithSessionTest is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;
    PushAgentWallet internal wallet;

    MockValidator internal validator;
    MockTarget internal target;

    address internal ownerUEA = address(0xB0B);
    address internal relayer = address(0xDEFEC8);
    bytes32 internal mandateId = keccak256("m");

    bytes32 internal constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v1");

    event SessionExecuted(address indexed validator, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash);

    function setUp() public {
        impl = new PushAgentWallet();
        factory = new AgentWalletFactory(address(impl));
        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(mandateId)));

        validator = new MockValidator();
        target = new MockTarget();

        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");
    }

    function _execCalldata(uint256 v) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (v)));
    }

    /// Mirror of PushAgentWallet._computeOpHash, for hash-binding assertions.
    function _expectedOpHash(
        address wallet_,
        address validator_,
        ModeCode mode,
        bytes memory execCalldata,
        uint192 key,
        uint64 seq,
        uint256 chainId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN, chainId, wallet_, validator_, ModeCode.unwrap(mode), keccak256(execCalldata), key, seq
            )
        );
    }

    // ── S-01 / S-02 ───────────────────────────────────────────────────

    function test_S01_happyPathExecutes() public {
        validator.setValidationData(0);
        bytes memory cd = _execCalldata(99);

        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, hex"5165", 0, 0);

        assertEq(target.value(), 99);
        assertEq(validator.lastSender(), address(wallet), "op.sender must be the wallet");
        assertEq(validator.lastSignature(), hex"5165");
        assertEq(validator.lastNonce(), 0);
    }

    function test_S02_uninstalledValidatorReverts() public {
        MockValidator other = new MockValidator();
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ValidatorNotInstalled.selector, address(other)));
        wallet.executeWithSession(address(other), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
    }

    // ── S-03 … S-05 — nonces ──────────────────────────────────────────

    function test_S03_wrongNonceSeqReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, uint192(0), uint64(0), uint64(5))
        );
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 5);
    }

    /// S-04 / A-07 — a consumed signature cannot be replayed.
    function test_S04_A07_nonceIncrementsAndReplayReverts() public {
        bytes memory cd = _execCalldata(1);
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, "", 0, 0);
        assertEq(wallet.nonce(0), 1);

        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, uint192(0), uint64(1), uint64(0))
        );
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, "", 0, 0);
    }

    function test_S05_independentNonceKeys() public {
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(2), "", 7, 0);

        assertEq(wallet.nonce(0), 1);
        assertEq(wallet.nonce(7), 1);
        assertEq(wallet.nonce(9), 0);

        // each key advances on its own
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(3), "", 7, 1);
        assertEq(wallet.nonce(0), 1);
        assertEq(wallet.nonce(7), 2);
    }

    // ── S-06 … S-10 — ValidationData unpacking ────────────────────────

    function test_S06_sigValidationFailedReverts() public {
        validator.setValidationData(1);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.SignatureValidationFailed.selector, address(validator), uint256(1))
        );
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
    }

    /// S-07 — aggregators are not supported; any non-zero authorizer reverts.
    function test_S07_aggregatorAuthorizerReverts() public {
        uint256 vd = uint256(uint160(address(0xA66A6A)));
        validator.setValidationData(vd);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.SignatureValidationFailed.selector, address(validator), vd)
        );
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
    }

    /// S-08 / A-16 — validUntil == 0 means NO EXPIRY, not "expired at epoch 0".
    function test_S08_A16_validUntilZeroMeansNoExpiry() public {
        vm.warp(1_000_000);
        validator.setValidationData(0); // authorizer 0, validUntil 0, validAfter 0
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(5), "", 0, 0);
        assertEq(target.value(), 5, "must execute despite validUntil == 0");
    }

    function test_S09_expiredValidUntilReverts() public {
        vm.warp(1_000_000);
        uint48 validUntil = 999_999;
        validator.setValidationData(uint256(validUntil) << 160);

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.OperationExpired.selector, validUntil));
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
    }

    function test_S09b_validUntilInFuturePasses() public {
        vm.warp(1_000_000);
        validator.setValidationData(uint256(uint48(1_000_001)) << 160);
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(6), "", 0, 0);
        assertEq(target.value(), 6);
    }

    function test_S10_validAfterInFutureReverts() public {
        vm.warp(1_000_000);
        uint48 validAfter = 1_000_001;
        validator.setValidationData(uint256(validAfter) << 208);

        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.OperationNotYetValid.selector, validAfter));
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
    }

    function test_S10b_validAfterInPastPasses() public {
        vm.warp(1_000_000);
        validator.setValidationData(uint256(uint48(999_999)) << 208);
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(4), "", 0, 0);
        assertEq(target.value(), 4);
    }

    // ── S-11 … S-15 — opHash binding ──────────────────────────────────

    function test_S11_A02_opHashBindsChainId() public {
        bytes memory cd = _execCalldata(1);
        ModeCode mode = ModeLib.encodeSimpleSingle();

        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);
        bytes32 h1 = validator.lastOpHash();

        assertEq(
            h1,
            _expectedOpHash(address(wallet), address(validator), mode, cd, 0, 0, block.chainid),
            "hash must match the documented preimage"
        );

        // Same op on a different chain id produces a different hash.
        vm.chainId(block.chainid + 1);
        wallet.executeWithSession(address(validator), mode, cd, "", 0, 1);
        assertTrue(validator.lastOpHash() != h1, "chainid must be bound");
    }

    function test_S12_A03_opHashBindsAccount() public {
        bytes memory cd = _execCalldata(1);
        ModeCode mode = ModeLib.encodeSimpleSingle();

        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);
        bytes32 h1 = validator.lastOpHash();

        // A second wallet, same owner, different mandate.
        vm.prank(ownerUEA);
        PushAgentWallet w2 = PushAgentWallet(payable(factory.deployAgentWallet(keccak256("m2"))));
        vm.prank(ownerUEA);
        w2.installModule(1, address(validator), "");
        w2.executeWithSession(address(validator), mode, cd, "", 0, 0);

        assertTrue(validator.lastOpHash() != h1, "address(this) must be bound");
    }

    function test_S13_A09_opHashBindsValidator() public {
        bytes memory cd = _execCalldata(1);
        ModeCode mode = ModeLib.encodeSimpleSingle();

        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);
        bytes32 h1 = validator.lastOpHash();

        MockValidator v2 = new MockValidator();
        vm.prank(ownerUEA);
        wallet.installModule(1, address(v2), "");
        wallet.executeWithSession(address(v2), mode, cd, "", 0, 1);

        assertTrue(v2.lastOpHash() != h1, "validator must be bound");
    }

    function test_S14_A08_opHashBindsMode() public {
        bytes memory cd = _execCalldata(1);

        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, "", 0, 0);
        bytes32 h1 = validator.lastOpHash();

        // Same call type/exec type but a different mode payload → different hash.
        ModeCode other =
            ModeLib.encode(CALLTYPE_SINGLE, EXECTYPE_DEFAULT, MODE_DEFAULT, ModePayload.wrap(bytes22(uint176(1))));
        wallet.executeWithSession(address(validator), other, cd, "", 0, 1);

        assertTrue(validator.lastOpHash() != h1, "mode must be bound");
    }

    function test_S15_opHashBindsCalldataByOneByte() public {
        ModeCode mode = ModeLib.encodeSimpleSingle();

        wallet.executeWithSession(address(validator), mode, _execCalldata(1), "", 0, 0);
        bytes32 h1 = validator.lastOpHash();

        wallet.executeWithSession(address(validator), mode, _execCalldata(2), "", 0, 1);
        assertTrue(validator.lastOpHash() != h1, "payload must be bound");
    }

    function test_S15b_opHashBindsNonce() public {
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory cd = _execCalldata(1);

        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);
        bytes32 hSeq0 = validator.lastOpHash();

        wallet.executeWithSession(address(validator), mode, cd, "", 0, 1);
        bytes32 hSeq1 = validator.lastOpHash();
        assertTrue(hSeq0 != hSeq1, "nonceSeq must be bound");

        wallet.executeWithSession(address(validator), mode, cd, "", 3, 0);
        assertTrue(validator.lastOpHash() != hSeq0, "nonceKey must be bound");
    }

    // ── S-16 — open submission ────────────────────────────────────────

    /// D-16 — the function is deliberately callable by any address; authorization
    /// is the signature checked inside, not msg.sender.
    function test_S16_callableByArbitrarySubmitter() public {
        vm.prank(relayer);
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(77), "", 0, 0);
        assertEq(target.value(), 77);
    }

    function test_S16b_emitsSessionExecuted() public {
        bytes memory cd = _execCalldata(1);
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes32 expected = _expectedOpHash(address(wallet), address(validator), mode, cd, 0, 0, block.chainid);

        vm.expectEmit(true, true, false, true);
        emit SessionExecuted(address(validator), 0, 0, expected);
        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);
    }

    /// The op passed to the validator carries the execute() callData shape.
    function test_opCallDataIsEncodedExecuteCall() public {
        bytes memory cd = _execCalldata(1);
        ModeCode mode = ModeLib.encodeSimpleSingle();
        wallet.executeWithSession(address(validator), mode, cd, "", 0, 0);

        assertEq(validator.lastCallData(), abi.encodeCall(PushAgentWallet.execute, (mode, cd)));
    }

    /// Nonce is consumed before validation, so a failed validation still reverts
    /// the whole tx and leaves the sequence unchanged.
    function test_failedValidationRevertsEntireTxLeavingNonceUnchanged() public {
        validator.setValidationData(1);
        vm.expectRevert();
        wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), _execCalldata(1), "", 0, 0);
        assertEq(wallet.nonce(0), 0, "state rolled back");
    }
}
