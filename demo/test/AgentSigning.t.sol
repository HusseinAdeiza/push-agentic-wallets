// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { AgentSigning } from "../lib/AgentSigning.sol";
import { OP_HASH_DOMAIN } from "../../src/libraries/PushWalletTypes.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

/**
 * @title  AgentSigningTest
 * @notice The equivalence proof for the lifted helper.
 *
 * @dev    WHY THIS FILE EXISTS. `AgentSigning` is a transcription of the wallet's own
 *         `_computeOpHash`, which is `internal` and so cannot be called from a script. A
 *         transcription that drifts produces signatures the wallet rejects — and the failure
 *         surfaces on-chain as an opaque signature error, minutes and one chain away from the
 *         reordered field that caused it.
 *
 *         THE ORACLE IS AN INDEPENDENT REIMPLEMENTATION, not a second call into the same helper.
 *         `_expected` below spells the ten fields out literally. If both copies were the library,
 *         the test would assert only that a function equals itself.
 */
contract AgentSigningTest is Test {
    uint256 internal constant CHAIN_ID = 42101;

    address internal wallet = makeAddr("agw");
    address internal validator = makeAddr("engine");
    address internal gateway = makeAddr("gateway");

    bytes32 internal permissionId = keccak256("permission");
    /// @dev CALLTYPE_SINGLE + EXECTYPE_DEFAULT — the only mode the agent door accepts.
    bytes32 internal mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    uint192 internal nonceKey = 0;
    uint64 internal nonceSeq = 0;
    uint48 internal requestExpiry = uint48(1_800_000_000);

    /// @dev The independent oracle: the ten fields, written out, in the order the wallet uses.
    function _expected(bytes memory executionCalldata, uint64 seq, uint48 expiry) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN,
                CHAIN_ID,
                wallet,
                validator,
                permissionId,
                mode,
                keccak256(executionCalldata),
                nonceKey,
                seq,
                expiry
            )
        );
    }

    function _exec() internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(gateway, 1 ether, hex"deadbeef");
    }

    // ─────────────────────────────── equivalence ───────────────────────────────

    function test_opHash_matchesIndependentEncoding() public view {
        bytes memory exec = _exec();

        assertEq(
            AgentSigning.opHash(
                CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
            ),
            _expected(exec, nonceSeq, requestExpiry),
            "lifted op-hash must equal the ten-field encoding"
        );
    }

    /// @dev Ten distinct words. `abi.encode` of ten fields is exactly 320 bytes; `encodePacked`
    ///      would be shorter and would let two different requests collide on one hash.
    function test_opHash_usesFixedTenWordLayout() public view {
        bytes memory encoded = abi.encode(
            OP_HASH_DOMAIN,
            CHAIN_ID,
            wallet,
            validator,
            permissionId,
            mode,
            keccak256(_exec()),
            nonceKey,
            nonceSeq,
            requestExpiry
        );
        assertEq(encoded.length, 320, "ten 32-byte words");
    }

    // ──────────────────────── every field is load-bearing ────────────────────────

    /// @dev Field 7. Changing one byte of the execution calldata must change the hash — this is
    ///      what binds the gateway target, the PC value, the multicall and the beneficiary.
    function test_opHash_bindsExecutionCalldata() public view {
        bytes32 a = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, permissionId, mode, _exec(), nonceKey, nonceSeq, requestExpiry
        );
        bytes32 b = AgentSigning.opHash(
            CHAIN_ID,
            wallet,
            validator,
            permissionId,
            mode,
            ExecutionLib.encodeSingle(gateway, 1 ether, hex"deadbeff"),
            nonceKey,
            nonceSeq,
            requestExpiry
        );
        assertTrue(a != b, "one payload byte must change the hash");
    }

    /// @dev Field 5. This is what kills a banked signed request the moment a mandate is revoked
    ///      and regranted — the v3 addition Act 3 explains.
    function test_opHash_bindsPermissionId() public view {
        bytes memory exec = _exec();
        bytes32 a = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
        );
        bytes32 b = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, keccak256("other"), mode, exec, nonceKey, nonceSeq, requestExpiry
        );
        assertTrue(a != b, "a different mandate must yield a different hash");
    }

    /// @dev Field 9. Straight replay protection.
    function test_opHash_bindsNonceSeq() public view {
        bytes memory exec = _exec();
        assertTrue(
            AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, 0, requestExpiry)
                != AgentSigning.opHash(
                    CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, 1, requestExpiry
                ),
            "sequence must bind"
        );
    }

    /// @dev Field 10, a v3 addition over shipped v2's eight fields.
    function test_opHash_bindsRequestExpiry() public view {
        bytes memory exec = _exec();
        assertTrue(
            AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, 1000)
                != AgentSigning.opHash(CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, 2000),
            "expiry must bind"
        );
    }

    /// @dev Field 2. The same request cannot be replayed onto another chain.
    function test_opHash_bindsChainId() public view {
        bytes memory exec = _exec();
        assertTrue(
            AgentSigning.opHash(
                    CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
                )
                != AgentSigning.opHash(
                        1, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
                    ),
            "chain id must bind"
        );
    }

    /// @dev Field 3. Nor onto another wallet.
    function test_opHash_bindsWallet() public {
        bytes memory exec = _exec();
        assertTrue(
            AgentSigning.opHash(
                    CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
                )
                != AgentSigning.opHash(
                        CHAIN_ID,
                        makeAddr("other"),
                        validator,
                        permissionId,
                        mode,
                        exec,
                        nonceKey,
                        nonceSeq,
                        requestExpiry
                    ),
            "wallet must bind"
        );
    }

    // ───────────────────────────────── envelope ─────────────────────────────────

    /// @dev 98 bytes: mode byte + 32-byte permission id + 65-byte signature.
    function test_envelope_shapeAndContents() public pure {
        bytes32 pid = keccak256("p");
        bytes memory sessionSig = new bytes(65);
        bytes memory env = AgentSigning.envelope(pid, sessionSig);

        assertEq(env.length, 98, "98 bytes");
        assertEq(uint8(env[0]), 0x00, "byte 0 is SmartSessionMode.USE");

        bytes32 recovered;
        assembly {
            recovered := mload(add(env, 33))
        }
        assertEq(recovered, pid, "bytes 1:33 are the permission id");
    }

    /// @dev The wallet's own floor: it rejects anything shorter than 33 bytes.
    function test_envelope_exceedsWalletMinimum() public pure {
        assertGe(AgentSigning.envelope(keccak256("p"), new bytes(65)).length, 33, "at least 33 bytes");
    }

    // ────────────────────────────── sign + recover ──────────────────────────────

    /// @dev The signature must recover to the agent's address — the property the validator checks
    ///      on the ECDSA branch, exercised end to end rather than assumed.
    function test_sign_recoversToSigner() public {
        (address agent, uint256 pk) = makeAddrAndKey("agent");
        bytes32 digest = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, permissionId, mode, _exec(), nonceKey, nonceSeq, requestExpiry
        );

        bytes memory sig = AgentSigning.sign(pk, digest);
        assertEq(sig.length, 65, "65-byte r|s|v");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        assertEq(ecrecover(digest, v, r, s), agent, "recovers to the agent key");
    }

    /// @dev The composed helper must equal doing it by hand — the form every script calls.
    function test_signRequest_equalsManualComposition() public {
        (, uint256 pk) = makeAddrAndKey("agent");
        bytes memory exec = _exec();

        bytes32 digest = AgentSigning.opHash(
            CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
        );

        assertEq(
            AgentSigning.signRequest(
                pk, CHAIN_ID, wallet, validator, permissionId, mode, exec, nonceKey, nonceSeq, requestExpiry
            ),
            AgentSigning.envelope(permissionId, AgentSigning.sign(pk, digest)),
            "composed helper matches manual composition"
        );
    }
}
