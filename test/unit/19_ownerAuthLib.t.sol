// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { OwnerAuthLib } from "../../src/libraries/OwnerAuthLib.sol";
import {
    OwnerIntent,
    OWNER_INTENT_TYPEHASH,
    OWNER_INTENT_DOMAIN_TYPEHASH,
    OWNER_LANE_FLAG
} from "../../src/libraries/Types.sol";
import {
    MockUEA,
    Mock1271Owner,
    MockRevertingOwner,
    MockEmptyReturnOwner,
    MockWrongLengthOwner,
    MockEchoOwner
} from "../mocks/MockUEA.sol";

/// @dev Exposes the internal library over calldata, exactly as the factory and wallet call it.
contract OwnerAuthHarness {
    function isOwnerSig(address owner, bytes32 digest, bytes calldata sig) external view returns (bool) {
        return OwnerAuthLib.isOwnerSig(owner, digest, sig);
    }

    function hashIntent(OwnerIntent calldata i) external pure returns (bytes32) {
        return OwnerAuthLib.hashIntent(i);
    }

    function intentDigest(address factory, OwnerIntent calldata i) external view returns (bytes32) {
        return OwnerAuthLib.intentDigest(factory, i);
    }

    function domainSeparator(address factory, uint256 signerChainId) external view returns (bytes32) {
        return OwnerAuthLib.domainSeparator(factory, signerChainId);
    }
}

/**
 * @title  OwnerAuthLib — Change A of the UniversalMarketplace PRD.
 * @notice The A-series: owner verification across EOA, UEA, ERC-1271 and hostile contract owners, and
 *         the intent's EIP-712 hashing against an independently hand-built reference.
 */
contract OwnerAuthLibTest is BaseTest {
    OwnerAuthHarness internal h;
    address internal signer;
    uint256 internal signerPk;
    bytes32 internal constant DIGEST = keccak256("some digest");

    function setUp() public override {
        super.setUp();
        h = new OwnerAuthHarness();
        (signer, signerPk) = ecdsaKey("intentSigner");
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fixture() internal view returns (OwnerIntent memory i) {
        i = OwnerIntent({
            owner: address(0x1111),
            wallet: address(0x2222),
            executor: address(0x3333),
            index: 7,
            sessionHash: keccak256("session"),
            mode: bytes32(uint256(1) << 248),
            execCalldataHash: keccak256("exec"),
            nonceKey: OWNER_LANE_FLAG | 5,
            nonceSeq: 9,
            grantNonce: 3,
            deadline: uint48(block.timestamp + 100),
            signerChainId: 11_155_111
        });
    }

    // ─────────────────────────── EOA owners ───────────────────────────

    function test_A01_eoaOwner_validSig_true() public view {
        assertTrue(h.isOwnerSig(signer, DIGEST, _sig(signerPk, DIGEST)));
    }

    function test_A02_eoaOwner_wrongSigner_false() public {
        (, uint256 otherPk) = ecdsaKey("other");
        assertFalse(h.isOwnerSig(signer, DIGEST, _sig(otherPk, DIGEST)));
    }

    /// @dev OZ 5.7's bytes-form recover accepts 65 bytes only; 64 (EIP-2098 compact) and 66 both
    ///      return an error, never an address. The assertion is `false`, not merely "did not revert".
    function test_A03_eoaOwner_malformedSig_false() public view {
        bytes memory good = _sig(signerPk, DIGEST);
        bytes memory short64 = new bytes(64);
        bytes memory long66 = bytes.concat(good, hex"00");
        for (uint256 k; k < 64; ++k) {
            short64[k] = good[k];
        }
        assertFalse(h.isOwnerSig(signer, DIGEST, short64), "64-byte signature must be false");
        assertFalse(h.isOwnerSig(signer, DIGEST, long66), "66-byte signature must be false");
        assertFalse(h.isOwnerSig(signer, DIGEST, ""), "empty signature must be false");
    }

    // ─────────────────────────── UEA owners ───────────────────────────

    function test_A04_ueaOwner_validSig_true() public {
        MockUEA uea = new MockUEA(signer);
        assertTrue(h.isOwnerSig(address(uea), DIGEST, _sig(signerPk, DIGEST)));
    }

    function test_A05_ueaOwner_returnsFalse_false() public {
        MockUEA uea = new MockUEA(signer);
        (, uint256 otherPk) = ecdsaKey("other");
        assertFalse(h.isOwnerSig(address(uea), DIGEST, _sig(otherPk, DIGEST)));
    }

    // ───────────────────── other contract owners ─────────────────────

    function test_A06_contractOwner_noUEASelector_1271_true() public {
        Mock1271Owner safe = new Mock1271Owner(signer);
        assertTrue(h.isOwnerSig(address(safe), DIGEST, _sig(signerPk, DIGEST)));
    }

    function test_A07_contractOwner_bothRevert_false() public {
        MockRevertingOwner o = new MockRevertingOwner();
        assertFalse(h.isOwnerSig(address(o), DIGEST, _sig(signerPk, DIGEST)));
    }

    /// @dev The case a high-level `try` cannot survive. Must return false and must not revert.
    function test_A13_contractOwner_emptyReturnOnBoth_false() public {
        MockEmptyReturnOwner o = new MockEmptyReturnOwner();
        assertFalse(h.isOwnerSig(address(o), DIGEST, _sig(signerPk, DIGEST)));
    }

    function test_A16_contractOwner_returnsWrongLength_false() public {
        MockWrongLengthOwner o = new MockWrongLengthOwner();
        assertFalse(h.isOwnerSig(address(o), DIGEST, _sig(signerPk, DIGEST)));
    }

    // ─────────────────────────── hashing ───────────────────────────

    function test_A08_hashIntent_matchesReferenceEncoding() public view {
        OwnerIntent memory i = _fixture();
        bytes32 expected = keccak256(
            bytes.concat(
                abi.encode(OWNER_INTENT_TYPEHASH, i.owner, i.wallet, i.executor, i.index, i.sessionHash, i.mode),
                abi.encode(i.execCalldataHash, i.nonceKey, i.nonceSeq, i.grantNonce, i.deadline, i.signerChainId)
            )
        );
        assertEq(h.hashIntent(i), expected);
    }

    /// @dev Against BaseTest's hand-built witness, which lists every field and type string literally.
    function test_A09_intentDigest_matches0x1901Reference() public view {
        OwnerIntent memory i = _fixture();
        assertEq(h.intentDigest(FACTORY, i), intentDigestWitness(FACTORY, i));
    }

    function test_A10_domainSeparator_differsAcrossPushChainId() public {
        bytes32 a = h.domainSeparator(FACTORY, 1);
        vm.chainId(42_101);
        bytes32 b = h.domainSeparator(FACTORY, 1);
        assertTrue(a != b, "the Push chain id (salt) must change the separator");
    }

    function test_A11_domainSeparator_differsAcrossFactory() public view {
        assertTrue(h.domainSeparator(FACTORY, 1) != h.domainSeparator(address(0xBEEF), 1));
    }

    function test_A14_domainSeparator_usesSignerChainId_notBlockChainid() public view {
        assertTrue(h.domainSeparator(FACTORY, 1) != h.domainSeparator(FACTORY, 11_155_111));
        bytes32 expected = keccak256(
            abi.encode(
                OWNER_INTENT_DOMAIN_TYPEHASH,
                keccak256("AGWFactory"),
                keccak256("1"),
                uint256(1),
                FACTORY,
                bytes32(block.chainid)
            )
        );
        assertEq(h.domainSeparator(FACTORY, 1), expected);
    }

    function test_A15_domainSeparator_saltIsPushChainId() public {
        vm.chainId(42_101);
        bytes32 expected = keccak256(
            abi.encode(
                OWNER_INTENT_DOMAIN_TYPEHASH,
                keccak256("AGWFactory"),
                keccak256("1"),
                uint256(1),
                FACTORY,
                bytes32(uint256(42_101))
            )
        );
        assertEq(h.domainSeparator(FACTORY, 1), expected);
    }

    function test_A12_typehashes_matchLiteralStrings() public pure {
        assertEq(
            OWNER_INTENT_TYPEHASH,
            keccak256(
                "OwnerIntent(address owner,address wallet,address executor,uint96 index,bytes32 sessionHash,bytes32 mode,bytes32 execCalldataHash,uint192 nonceKey,uint64 nonceSeq,uint64 grantNonce,uint48 deadline,uint256 signerChainId)"
            )
        );
        assertEq(
            OWNER_INTENT_DOMAIN_TYPEHASH,
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)")
        );
    }

    /// @dev End to end through the library: a signature over the witness digest verifies for an EOA
    ///      and for a UEA owner.
    function test_A18_signedIntent_verifiesForEoaAndUea() public {
        OwnerIntent memory i = _fixture();
        bytes memory sig = signIntent(signerPk, i);
        bytes32 digest = h.intentDigest(FACTORY, i);
        assertTrue(h.isOwnerSig(signer, digest, sig));
        assertTrue(h.isOwnerSig(address(new MockUEA(signer)), digest, sig));
    }

    /// @dev An owner echoing calldata answers `0x1626ba7e ‖ digest[0:28]` to ERC-1271. Only the full-word
    ///      comparison rejects it; a four-byte comparison would accept every signature for this owner.
    function test_A19_contractOwner_echoesCalldata_false() public {
        MockEchoOwner o = new MockEchoOwner();
        assertFalse(h.isOwnerSig(address(o), DIGEST, _sig(signerPk, DIGEST)));
        assertFalse(h.isOwnerSig(address(o), DIGEST, ""));
    }

    /// @dev Pins (a) in isOwnerSig's NatSpec: a UEA that is not yet deployed has no code, so its address
    ///      is judged by the secp256k1 branch — and no key recovers to it, so the check fails closed.
    function test_A20_counterfactualUEAOwner_secp256k1BranchRejects() public {
        address predictedUEA = makeAddr("notYetDeployedUEA");
        assertEq(predictedUEA.code.length, 0);
        assertFalse(h.isOwnerSig(predictedUEA, DIGEST, _sig(signerPk, DIGEST)));
        // the same signature DOES verify once the UEA exists at that address (the origin key is an
        // immutable, so it travels with the etched code)
        vm.etch(predictedUEA, address(new MockUEA(signer)).code);
        assertTrue(h.isOwnerSig(predictedUEA, DIGEST, _sig(signerPk, DIGEST)));
    }
}
