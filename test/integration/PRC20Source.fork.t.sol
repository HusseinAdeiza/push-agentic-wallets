// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IPRC20Source } from "../../src/interfaces/IPRC20Source.sol";
import { PushChainLib } from "../../src/libraries/PushChainLib.sol";

/**
 * @title  IPRC20Source — pinned against a LIVE PRC20 on Push Chain Donut.
 *
 * @notice URP's universal init reads exactly one view from the asset,
 *         `SOURCE_CHAIN_NAMESPACE()`, and refuses the grant unless it matches the chain the policy
 *         envelope declares. Every unit test for that path uses a mock, and a mock only ever proves
 *         that URP compares two strings correctly — it cannot prove the interface is the one the
 *         real token implements.
 *
 *         THIS IS THE ONLY TEST THAT PROVES THE MIRROR IS REAL. push-chain-core is not a submodule
 *         of this repository, so there is nothing for the compiler to check `IPRC20Source` against;
 *         the mirror is a hand-copied signature, and a hand-copied signature stays correct only
 *         until the thing it copies moves. The field has been renamed once already
 *         (`SOURCE_CHAIN_ID`, now deprecated), which is the argument for this test rather than
 *         against the coupling.
 *
 * @dev    ⚠️ ENV-GATED, AND A SKIPPED TEST IS NOT A PASSING TEST. Gated on `PUSH_TESTNET_RPC`, the
 *         SAME variable P-03 already uses — deliberately not a third RPC name. Run it against a real
 *         endpoint at least once before reporting this phase done.
 *
 * @dev    NO MOCK APPEARS IN THIS FILE, by design. The whole point is the absence of one.
 */
contract PRC20SourceForkTest is Test {
    /// @dev `USDC.eth` on Donut. From `deployments/address-book/donut_push_core.json`, where it is
    ///      recorded as the live PRC20 whose `symbol()` is "USDC.eth" — NOT the deprecated
    ///      "USDC.eth.old" at `0x387b9C8D...`. Never invented.
    address internal constant USDC_ETH = 0x7A58048036206bB898008b5bBDA85697DB1e5d66;

    /// @dev `pETH`, resolved live from `UniversalCore.gasTokenPRC20ByChainNamespace("eip155:11155111")`
    ///      rather than copied from a truncated book entry.
    address internal constant PETH = 0x2971824Db68229D087931155C2b8bB820B275809;

    /// @dev `cast keccak "eip155:11155111"`.
    bytes32 internal constant SEPOLIA_PIN = 0xafa90c317deacd3d68f330a30f96e4fa7736e35e8d1426b2e1b2c04bce1c2fb7;
    /// @dev `cast keccak "eip155:42101"`.
    bytes32 internal constant DONUT_PIN = 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9;

    uint256 internal constant DONUT_CHAIN_ID = 42_101;

    function _forkOrSkip() internal {
        string memory rpc = vm.envOr("PUSH_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "requires PUSH_TESTNET_RPC - not set");
        }
        vm.createSelectFork(rpc);
    }

    /**
     * The mirror answers, and answers the string URP expects.
     *
     * If `SOURCE_CHAIN_NAMESPACE()` were ever renamed or retyped upstream, this call reverts and
     * this test fails — which is the whole reason it exists. The unit tests would keep passing
     * against their mock, happily verifying a comparison that production could never reach.
     */
    function test_Fork_usdcEthReportsSepolia() public {
        _forkOrSkip();

        string memory ns = IPRC20Source(USDC_ETH).SOURCE_CHAIN_NAMESPACE();
        assertEq(ns, "eip155:11155111", "USDC.eth reports its origin chain");
        assertEq(keccak256(bytes(ns)), SEPOLIA_PIN, "and hashes to the pin the SDK must produce");
    }

    /// A second live token, so the first is not a single coincidence.
    function test_Fork_pethReportsSepolia() public {
        _forkOrSkip();

        string memory ns = IPRC20Source(PETH).SOURCE_CHAIN_NAMESPACE();
        assertEq(ns, "eip155:11155111", "pETH reports the same origin");
        assertEq(keccak256(bytes(ns)), SEPOLIA_PIN, "same pin");
    }

    /**
     * A live Sepolia asset is NOT this chain — so a mandate naming it derives UNIVERSAL.
     *
     * This is the derivation and the teeth meeting on real data: the string a deployed token
     * actually returns, hashed by the real library, against the real chain id.
     */
    function test_Fork_liveAssetDerivesUniversal() public {
        _forkOrSkip();
        assertEq(block.chainid, DONUT_CHAIN_ID, "the fork really is Donut");

        bytes32 assetChain = keccak256(bytes(IPRC20Source(USDC_ETH).SOURCE_CHAIN_NAMESPACE()));
        assertTrue(assetChain != DONUT_PIN, "a Sepolia asset is not this chain");
    }

    /**
     * Donut's own identity, derived on Donut, equals the pin every other test hard-codes.
     *
     * Ties the whole scheme to the live chain: `PushChainLib` is given no configuration anywhere, so
     * if `block.chainid` on Donut were not 42101 — or if Push named itself differently — this is
     * where that would surface, rather than at a grant.
     */
    function test_Fork_selfChainHashOnDonut() public {
        _forkOrSkip();

        ForkChainLibHarness h = new ForkChainLibHarness();
        assertEq(h.selfChainHash(), DONUT_PIN, "Donut derives its own CAIP-2 hash");
    }
}

/// @dev The library is `internal`; this exposes it from inside a real contract frame on the fork.
contract ForkChainLibHarness {
    function selfChainHash() external view returns (bytes32) {
        return PushChainLib.selfChainHash();
    }
}
