// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import {
    MockPRC20Source,
    RevertingPRC20Source,
    NonStringPRC20Source,
    EmptyReturnPRC20Source
} from "../mocks/MockPRC20Source.sol";

/**
 * @title  URP — the teeth. The chain a mandate declares is checked against the asset that carries it.
 *
 * @notice WHAT THIS BUYS, stated once. The gateway routes an outbound to whatever chain the PRC20
 *         `token` says it came from — `IPRC20(token).SOURCE_CHAIN_NAMESPACE()`, read through
 *         `UniversalCore.getOutboundTxGasAndFees` on every single outbound. Gate 5 pins
 *         `req.token == cfg.asset` on every request. So checking the asset's chain ONCE at grant
 *         makes the owner's declared chain true for every request the mandate will ever authorise —
 *         with no runtime change, and no external call anywhere near `checkAction`.
 *
 *         Without it the chain would be a label: an owner could declare Sepolia, name a Polygon
 *         PRC20 as the asset, and the contract would keep the declaration while sending the money to
 *         Polygon. A mandatory input the system ignores is worse than no input.
 *
 * @dev    ⚠️ THE MOCKS ARE OBSERVERS, NEVER ORACLES. They supply the string; URP hashes it and does
 *         the comparing. A mock that decided the outcome could make this whole branch look alive
 *         while it was dead — which is exactly how this repo's one shipped critical bug survived
 *         review.
 *
 * @dev    INIT REVERTS ARE NOT TRUNCATED. `checkAction` reverts get wrapped by the engine into
 *         `PolicyCheckReverted(bytes32)`, which is why gate tests use `expectUrpGate`. But
 *         `initializeWithMultiplexer` is a plain call from `ConfigLib`, so these bubble with full
 *         data and are asserted with every argument.
 */
contract URPTeethTest is BaseTest {
    address internal ACCOUNT;
    address internal CEA;
    address internal PROTOCOL;

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0xEE77)));

    uint48 internal constant VALID_UNTIL = 2_000_000_000;
    bytes4 internal constant SWAP = bytes4(keccak256("swap(address,uint256)"));

    function setUp() public override {
        super.setUp();
        ACCOUNT = makeAddr("wallet");
        CEA = makeAddr("cea");
        PROTOCOL = makeAddr("protocol");
        vm.warp(1_000_000_000);
    }

    function _config(address asset) internal view returns (IURP.Config memory cfg) {
        IURP.AllowedCall[] memory calls = new IURP.AllowedCall[](1);
        calls[0] = IURP.AllowedCall({
            target: PROTOCOL, selector: SWAP, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0
        });

        cfg = IURP.Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            destChainHash: bytes32(0),
            expectedCEA: CEA,
            asset: asset,
            maxAmountPerCall: 100e6,
            maxAmountTotal: 1000e6,
            maxPCPerCall: 5 ether,
            spent: 0,
            allowedCalls: calls
        });
    }

    function _init(string memory chain, address asset) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(chain, _config(asset)));
    }

    // ═══════════════════════════════ the happy path ═══════════════════════════════

    /// The asset agrees with the envelope, so the mandate is written and the chain is recorded.
    function test_Teeth_matchingAssetChainAccepted() public {
        address asset = address(new MockPRC20Source(CHAIN_SEPOLIA));
        _init(CHAIN_SEPOLIA, asset);

        IURP.ModeSlot memory slot = urp.getMode(CID, ACCOUNT);
        assertTrue(slot.initialized, "config written");
        assertEq(slot.chainHash, keccak256(bytes(CHAIN_SEPOLIA)), "and the chain recorded on the mode slot");
        assertEq(urp.getConfig(CID, ACCOUNT).asset, asset, "asset stored");
    }

    // ══════════════════════════════ the refusals ══════════════════════════════

    /**
     * THE CASE THIS WHOLE MECHANISM EXISTS FOR: the owner declares one chain and supplies a token
     * from another. Caught at grant, named, with both hashes so the SDK can say which is which.
     */
    function test_Teeth_mismatchedAssetChainRefused() public {
        address polygonAsset = address(new MockPRC20Source("eip155:137"));

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                IURP.ChainMismatch.selector, keccak256(bytes(CHAIN_SEPOLIA)), keccak256(bytes("eip155:137"))
            )
        );
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(polygonAsset)));
    }

    /**
     * ⚠️ THE `code.length` GUARD IS WHAT MAKES THIS NAMED. Delete that one line and this test fails
     * with an unnamed revert instead — measured, not theorised.
     *
     * Since solc 0.8.10 the compiler omits the `extcodesize` check when a call expects return data.
     * The call to a codeless address therefore SUCCEEDS with empty returndata, and the failure lands
     * in URP's own ABI decode — outside the `try/catch`, which never fires. A typo'd asset address
     * is the likeliest real mistake here, so it is the one that most deserves a name.
     */
    function test_Teeth_assetWithNoCodeRefused() public {
        address noCode = makeAddr("not-a-token");

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidAsset.selector, noCode));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(noCode)));
    }

    /// The same guard, second shape: an EOA. Also named, also only because of the guard.
    function test_Teeth_eoaAssetRefused() public {
        (address eoa,) = makeAddrAndKey("an-eoa");

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidAsset.selector, eoa));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(eoa)));
    }

    /// A contract that reverts when asked. THE ONLY failure mode `try/catch` actually catches.
    function test_Teeth_assetThatRevertsRefused() public {
        address reverting = address(new RevertingPRC20Source());

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(IURP.InvalidAsset.selector, reverting));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(reverting)));
    }

    /**
     * A contract that ANSWERS, but with a word instead of a string.
     *
     * ⚠️ BARE `vm.expectRevert()`, JUSTIFIED: this revert genuinely carries no data. The call
     * succeeds and the ABI decode fails inside URP's frame, which produces an empty revert that no
     * `catch` sees and no selector describes. Naming it would mean guessing at an arbitrary blob —
     * the same heuristic-decoding objection that governs the malformed-envelope cases. The property
     * asserted is the one that matters: it FAILS CLOSED rather than accepting garbage as a chain.
     */
    function test_Teeth_assetReturningGarbageRevertsUnnamed() public {
        address garbage = address(new NonStringPRC20Source());

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(garbage)));
    }

    /// Same again, with nothing at all returned. Different shape, same fail-closed outcome.
    function test_Teeth_assetReturningNothingRevertsUnnamed() public {
        address empty = address(new EmptyReturnPRC20Source());

        vm.prank(address(engine));
        vm.expectRevert();
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(CHAIN_SEPOLIA, _config(empty)));
    }

    // ═════════════════════════ native makes no external call ═════════════════════════

    /**
     * A native config has NO ASSET, so there is nothing to interrogate — and nothing to check: the
     * chain IS this chain, which is what made the mode NATIVE in the first place.
     *
     * The observable is that init touches nothing external. Asserted by pointing the native target
     * at a contract that would REVERT if URP called it, then initialising successfully: if the
     * universal branch's teeth ever leaked into the native path, this reverts.
     */
    function test_Teeth_nativeInitMakesNoExternalCall() public {
        address hostileTarget = address(new RevertingPRC20Source());

        IURP.NativeConfig memory cfg;
        cfg.validUntil = VALID_UNTIL;
        cfg.target = hostileTarget;
        cfg.selector = bytes4(keccak256("stake(uint256)"));

        // ⚠️ THE ASSERTION THAT MAKES THE NAME TRUE. Count 0 means "must never be called", and empty
        // calldata matches ANY calldata — so this fails if native init calls the target with any
        // selector at all, not merely with `SOURCE_CHAIN_NAMESPACE()`.
        //
        // Without it, this test rested on the mock reverting, which proves only that URP did not
        // make the ONE call the mock rejects. A call with a different selector would have gone
        // unobserved, and the test would have kept its name while covering less than it claimed.
        vm.expectCall(hostileTarget, "", 0);

        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(cfg));

        IURP.ModeSlot memory slot = urp.getMode(CID, ACCOUNT);
        assertTrue(slot.initialized, "native config written without touching the target");
        assertEq(slot.chainHash, keccak256(bytes(nativeChain())), "native records this chain");
    }

    // ═════════════════════════════ the empty chain ═════════════════════════════

    /// URP validates the string itself in exactly one way, and this is it.
    function test_Teeth_emptyChainRefused() public {
        address asset = address(new MockPRC20Source(CHAIN_SEPOLIA));

        vm.prank(address(engine));
        vm.expectRevert(IURP.EmptyChain.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData("", _config(asset)));
    }
}
