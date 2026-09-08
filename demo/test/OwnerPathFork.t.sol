// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BobPayload, IUEA, UniversalPayload } from "../lib/BobPayload.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  OwnerPathForkTest
 * @notice Proves the owner path — the mechanism every Act 1 script after the bridge depends on —
 *         against the live Donut chain, through the library the scripts actually use.
 *
 * @dev    WHAT THIS PINS, and why it earned a permanent test. The forwarding probe established
 *         that Push's inbound pipeline deploys the UEA and mints, but does NOT execute an attached
 *         payload. Act 1 therefore rests on the fallback: the owner signs a payload and a relayer
 *         with no authority submits it.
 *
 *         That path was proven manually first (Donut tx `0x88b2ac09…`, block 22638186: the UEA's
 *         pUSDC fell by 0.5, the relayer's rose by 0.5, and `nonce()` advanced 0 → 1). A manual
 *         proof decays — this test re-establishes it on every run, and does so through
 *         `BobPayload`, so a bug in the library is caught rather than a bug in a one-off shell
 *         command.
 *
 *         THE THREE PROPERTIES:
 *           · the digest can be ASKED OF the UEA, never hand-derived (Part 0.5);
 *           · a third party may submit — the signature is the authority, not the caller;
 *           · the nonce is real and monotonic, so replay is refused without the caller tracking it.
 *
 *         ENV-GATED, AND A SKIP IS NOT A PASS. Needs `PUSH_DONUT_RPC_URL` and a `PROBE_KEY` whose
 *         UEA exists. Run it against a real endpoint before trusting Act 1.
 */
contract OwnerPathForkTest is Test {
    /// @dev The probe's UEA, deployed by the inbound pipeline during the forwarding probe.
    address internal constant PROBE_UEA = 0x370358571111981f77De8D67e02F79311E37fA87;

    address internal prc20;
    uint256 internal ownerPk;

    /**
     * @dev The UEA's rejection selector, read off the live chain rather than guessed — it is not a
     *      named error in any interface we hold.
     *
     *      The UEA raises the SAME error for a forged signature and for a replayed payload, and
     *      that is not sloppiness. The STORED nonce is one of the hashed fields, so once the
     *      counter moves the old digest no longer reproduces and recovery yields a different
     *      address. Both failures really are "this signature does not authorise this payload".
     *
     *      Note it is the STORED counter that does this, not `payload.nonce` — the contract ignores
     *      that field entirely. See `UeaDigest` and `UeaDigestFork.t.sol`.
     *
     *      Consequence for these tests: `vm.expectRevert()` with no argument would pass for the
     *      wrong reason. Every negative below names this selector.
     */
    bytes4 internal constant UEA_SIGNATURE_REJECTED = 0xc7dbd31d;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("PUSH_DONUT_RPC_URL", string(""));
        string memory key = vm.envOr("PROBE_KEY", string(""));
        if (bytes(rpc).length == 0 || bytes(key).length == 0) return false;

        vm.createSelectFork(rpc);
        if (PROBE_UEA.code.length == 0) return false;

        ownerPk = vm.parseUint(string.concat("0x", key));
        prc20 = vm.parseJsonAddress(vm.readFile("deployments/address-book/donut_push_core.json"), ".PRC20_USDC");
        return true;
    }

    /**
     * @notice The whole owner path: read the nonce, ask the UEA for the digest, sign as the owner,
     *         submit as somebody else entirely.
     */
    function test_relayerSubmitsOwnerSignedPayload() public {
        if (!_fork()) return;

        address relayer = makeAddr("a relayer with no authority");
        uint256 ueaBefore = IERC20(prc20).balanceOf(PROBE_UEA);
        if (ueaBefore == 0) return; // nothing to move; the probe's balance was spent

        uint256 amount = ueaBefore / 2;
        uint256 nonceBefore = IUEA(PROBE_UEA).nonce();

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (relayer, amount)) });

        (UniversalPayload memory payload, bytes memory sig) =
            BobPayload.signedMulticall(PROBE_UEA, calls, ownerPk, 1 hours);

        // THE CALLER IS NOT THE OWNER. That is the property under test.
        vm.prank(relayer);
        IUEA(PROBE_UEA).executeUniversalTx(payload, sig);

        assertEq(IERC20(prc20).balanceOf(relayer), amount, "the multicall entry executed");
        assertEq(IERC20(prc20).balanceOf(PROBE_UEA), ueaBefore - amount, "funds left the UEA");
        assertEq(IUEA(PROBE_UEA).nonce(), nonceBefore + 1, "the nonce advanced");
    }

    /// @dev Replay is refused by the nonce, not by anything the caller has to remember.
    function test_replayOfTheSameSignedPayloadIsRefused() public {
        if (!_fork()) return;

        uint256 ueaBefore = IERC20(prc20).balanceOf(PROBE_UEA);
        if (ueaBefore == 0) return;

        address relayer = makeAddr("relayer");
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (relayer, 1)) });

        (UniversalPayload memory payload, bytes memory sig) =
            BobPayload.signedMulticall(PROBE_UEA, calls, ownerPk, 1 hours);

        vm.prank(relayer);
        IUEA(PROBE_UEA).executeUniversalTx(payload, sig);

        vm.prank(relayer);
        vm.expectRevert(abi.encodePacked(UEA_SIGNATURE_REJECTED));
        IUEA(PROBE_UEA).executeUniversalTx(payload, sig);
    }

    /// @dev A signature over a different payload must not authorise this one. Without this, the
    ///      test above would pass against a UEA that ignored the signature entirely.
    function test_signatureFromAnotherKeyIsRefused() public {
        if (!_fork()) return;

        address relayer = makeAddr("relayer");
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (relayer, 1)) });

        (, uint256 impostorPk) = makeAddrAndKey("impostor");
        (UniversalPayload memory payload, bytes memory sig) =
            BobPayload.signedMulticall(PROBE_UEA, calls, impostorPk, 1 hours);

        vm.prank(relayer);
        vm.expectRevert(abi.encodePacked(UEA_SIGNATURE_REJECTED));
        IUEA(PROBE_UEA).executeUniversalTx(payload, sig);
    }

    /**
     * @dev THE NONCE THE LIBRARY SIGNS MUST BE THE UEA'S CURRENT ONE.
     *
     *      Added after a mutation slipped through: changing `signedMulticall` to sign
     *      `currentNonce(uea) + 1` left every other test in this file green. The two negative tests
     *      still reverted — for the wrong reason — and the positive test never ran, because a
     *      stale-nonce payload cannot execute and the assertions after it were unreachable.
     *
     *      This asserts the nonce directly, which is the only form that fails when the library
     *      silently signs against the wrong one.
     */
    function test_signedNonceMatchesTheUeasCurrentNonce() public {
        if (!_fork()) return;

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (address(1), 0)) });

        uint256 expected = IUEA(PROBE_UEA).nonce();
        (UniversalPayload memory payload,) = BobPayload.signedMulticall(PROBE_UEA, calls, ownerPk, 1 hours);

        assertEq(payload.nonce, expected, "the library must sign against the UEA's CURRENT nonce");
    }

    /// @dev The same for the single-call builder, which Act 1 uses for every owner action after the
    ///      arrival multicall.
    function test_signedCallNonceMatchesTheUeasCurrentNonce() public {
        if (!_fork()) return;

        uint256 expected = IUEA(PROBE_UEA).nonce();
        (UniversalPayload memory payload,) = BobPayload.signedCall(
            PROBE_UEA, prc20, abi.encodeCall(IERC20.transfer, (address(1), 0)), ownerPk, 1 hours
        );

        assertEq(payload.nonce, expected, "signedCall must sign against the UEA's CURRENT nonce");
    }

    /// @dev The digest comes from the UEA itself, so it cannot drift from Push core's typehashes —
    ///      which is why nothing in this build reimplements the EIP-712 encoding.
    function test_digestIsAskedOfTheUeaNotDerived() public {
        if (!_fork()) return;

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (address(1), 0)) });

        UniversalPayload memory payload = BobPayload.multicallPayload(calls, IUEA(PROBE_UEA).nonce(), 0);
        assertTrue(IUEA(PROBE_UEA).getUniversalPayloadHash(payload) != bytes32(0), "the UEA answers with a digest");
    }
}
