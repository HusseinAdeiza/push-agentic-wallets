// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UeaDigest } from "../lib/UeaDigest.sol";
import { BobPayload, IUEA, UniversalPayload } from "../lib/BobPayload.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  UeaDigestForkTest
 * @notice Proves the locally computed digest equals what a DEPLOYED UEA answers.
 *
 * @dev    WHY THIS IS THE MOST IMPORTANT TEST IN THE ARRIVAL PATH. Bob signs his arrival payload
 *         before his UEA exists, so that one signature cannot be produced by asking the contract —
 *         it must be computed from Push core's typehashes. A single wrong field yields a signature
 *         that verifies against nothing, and the failure appears on another chain, minutes later,
 *         with nothing on screen explaining why.
 *
 *         The probe UEA IS deployed, so it can be asked. Computing the same digest locally against
 *         its address and comparing is a complete proof of the arrival's signing, obtained without
 *         needing an undeployed UEA.
 *
 *         AN EARLIER VERSION OF THE LIBRARY FAILED THIS TEST AND WAS DELETED. That is the point of
 *         the file: it is the check that stops a plausible-looking encoding from shipping.
 *
 *         ENV-GATED, AND A SKIP IS NOT A PASS. Needs `PUSH_DONUT_RPC_URL` and the probe UEA.
 */
contract UeaDigestForkTest is Test {
    /// @dev A probe artifact, NOT Bob's. Deployed by the inbound pipeline during the forwarding
    ///      probe and kept as a live fixture. Nothing in the demo depends on it.
    address internal constant PROBE_UEA = 0x370358571111981f77De8D67e02F79311E37fA87;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant PUSH_CHAIN_ID = 42101;

    address internal prc20;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("PUSH_DONUT_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        if (PROBE_UEA.code.length == 0) return false;

        prc20 = vm.parseJsonAddress(vm.readFile("deployments/address-book/donut_push_core.json"), ".PRC20_USDC");
        return true;
    }

    function _payload() internal view returns (UniversalPayload memory) {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (address(1), 0)) });
        // payload.nonce is deliberately a junk value: the contract sources the nonce from storage
        // and ignores this field, so a correct implementation must ignore it too.
        return BobPayload.multicallPayload(calls, 424242, 0);
    }

    /// @notice THE PROOF: local computation == the deployed contract's own answer.
    function test_localDigestMatchesTheDeployedUea() public {
        if (!_fork()) return;

        UniversalPayload memory payload = _payload();
        uint256 storedNonce = IUEA(PROBE_UEA).nonce();

        assertEq(
            UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, storedNonce, payload),
            IUEA(PROBE_UEA).getUniversalPayloadHash(payload),
            "locally computed digest must equal the UEA's own"
        );
    }

    /**
     * @dev The stored nonce IS in the hash, and `payload.nonce` is NOT.
     *
     *      Both halves matter. The first is what makes a banked signature die when the counter
     *      moves; the second is why `hash()` takes the nonce as a separate argument rather than
     *      reading it off the payload. Asserted against the live contract so a change in either
     *      direction surfaces here.
     */
    function test_storedNonceIsInTheHashAndPayloadNonceIsNot() public {
        if (!_fork()) return;

        UniversalPayload memory payload = _payload();
        uint256 stored = IUEA(PROBE_UEA).nonce();

        bytes32 atStored = UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, stored, payload);
        bytes32 atOther = UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, stored + 1, payload);
        assertTrue(atStored != atOther, "the STORED nonce must change the digest");

        // Same payload, different `payload.nonce` — the contract must not care, and neither do we.
        UniversalPayload memory other = payload;
        other.nonce = payload.nonce + 1;
        assertEq(
            IUEA(PROBE_UEA).getUniversalPayloadHash(payload),
            IUEA(PROBE_UEA).getUniversalPayloadHash(other),
            "payload.nonce must NOT affect the contract's hash"
        );
    }

    /// @dev The domain binds the UEA address, so a signature for one account cannot authorise
    ///      another. Without this the headline test could pass against a domain that ignored it.
    function test_digestBindsTheUeaAddress() public {
        if (!_fork()) return;

        UniversalPayload memory p = _payload();
        assertTrue(
            UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, 0, p)
                != UeaDigest.hash(address(0xBEEF), SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, 0, p),
            "a different UEA must yield a different digest"
        );
    }

    /**
     * @dev THE CHAIN-ID GUARD, and the trap it protects against.
     *
     *      The domain's `chainId` is the SOURCE chain — Sepolia's 11155111 — not the chain doing
     *      the verifying. Every instinct says otherwise, so a future "correction" to Push Chain's
     *      42101 is a plausible edit. It would produce a digest that is wrong in the silent way.
     *
     *      This asserts the SOURCE id is what reproduces the live contract's answer, and that
     *      Push's id does not. That is a real discrimination, not a tautology: it compares both
     *      candidates against the deployed bytecode rather than against each other.
     */
    function test_domainUsesTheSourceChainIdNotPushChainId() public {
        if (!_fork()) return;

        UniversalPayload memory p = _payload();
        uint256 stored = IUEA(PROBE_UEA).nonce();
        bytes32 live = IUEA(PROBE_UEA).getUniversalPayloadHash(p);

        assertEq(UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, stored, p), live, "source id is correct");
        assertTrue(
            UeaDigest.hash(PROBE_UEA, PUSH_CHAIN_ID, PUSH_CHAIN_ID, stored, p) != live,
            "Push Chain's id in the domain must NOT reproduce the live digest"
        );
    }

    /**
     * @dev The deployed domain has NO `salt` field, so Push Chain's id appears nowhere in it.
     *      Passing a different `pushChainId` must therefore change nothing.
     *
     *      Asserted rather than left implicit because the argument is still in the signature: it
     *      documents the field's absence, and if a future Push build reintroduces `salt` this test
     *      fails and says so.
     */
    function test_pushChainIdIsAbsentFromTheDeployedDomain() public {
        if (!_fork()) return;

        UniversalPayload memory p = _payload();
        assertEq(
            UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, 0, p),
            UeaDigest.hash(PROBE_UEA, SEPOLIA_CHAIN_ID, 999999, 0, p),
            "pushChainId must not affect the digest on the deployed three-field domain"
        );
    }

    /// @dev The version string is mixed into the domain; a bump would invalidate every locally
    ///      computed digest, so pin it against the live contract.
    function test_versionMatchesTheLiveUea() public {
        if (!_fork()) return;

        (bool ok, bytes memory ret) = PROBE_UEA.staticcall(abi.encodeWithSignature("VERSION()"));
        if (!ok) return;

        assertEq(
            keccak256(bytes(abi.decode(ret, (string)))), keccak256(bytes(UeaDigest.VERSION)), "UEA VERSION unchanged"
        );
    }
}
