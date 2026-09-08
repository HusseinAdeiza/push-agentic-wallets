// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../../test/Base.t.sol";
import { AgentSigning } from "../lib/AgentSigning.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { IPushAgentWallet } from "../../src/interfaces/IPushAgentWallet.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";
import { MockUniversalGateway } from "../../test/mocks/MockUniversalGateway.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 6-decimal stand-in for the pUSDC PRC20.
contract MockPRC20 is ERC20 {
    constructor() ERC20("USDC.eth", "USDC.eth") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title  AgentSigningLiveTest
 * @notice THE EQUIVALENCE PROOF that `demo/lib/AgentSigning.sol` matches the shipped wallet.
 *
 * @dev    WHY A SECOND FILE. `AgentSigning.t.sol` compares the library against a second copy of
 *         the ten fields written in that same file. That proves internal consistency and nothing
 *         about `PushAgentWallet`. If both copies were wrong in the same way — a reordered field,
 *         a widened type — every test there would still pass and every request the demo signs
 *         would be rejected on-chain by an opaque signature error.
 *
 *         `_computeOpHash` is `internal` and cannot be called. But the wallet EMITS the hash it
 *         computed, in `MandateActionAuthorized`. Driving a real request through the real engine,
 *         the real validator and the real UCEP, then reading that event, is therefore the only way
 *         to compare the transcription against the actual bytecode — so that is what this does.
 *
 *         NOTHING HERE IS MOCKED THAT SUPPLIES BEHAVIOUR UNDER TEST. The gateway is a recorder and
 *         the PRC20 is an ordinary ERC-20; the engine, validator, UCEP and wallet are the real
 *         contracts, deployed by `BaseTest`. A mocked engine would be an oracle for precisely the
 *         property being asserted.
 */
contract AgentSigningLiveTest is BaseTest {
    MockPRC20 internal pUSDC;
    MockUniversalGateway internal gatewayMock;
    PushAgentWallet internal agw;

    address internal owner = makeAddr("uea");
    address internal agent;
    uint256 internal agentPk;
    address internal relayer = makeAddr("relayer");

    address internal constant FAR_TARGET = address(0xDEAD01);
    address internal constant EXPECTED_CEA = address(0xCEA001);
    bytes4 internal constant FAR_SELECTOR = bytes4(keccak256("stakeFor(address,uint256)"));

    uint256 internal constant STAKE = 50e6;
    uint256 internal constant PC_VALUE = 0.05 ether;

    /// @dev Distinct and non-zero so that transposing op-hash fields 8 and 9 changes the hash.
    ///      Equal values (the demo's own lane 0, sequence 0) would make that mutation invisible.
    uint192 internal constant LANE = 7;
    uint64 internal constant SEQ = 3;

    function setUp() public override {
        super.setUp();

        (agent, agentPk) = makeAddrAndKey("agent");

        pUSDC = new MockPRC20();
        gatewayMock = new MockUniversalGateway();
        vm.etch(GATEWAY, address(gatewayMock).code);

        agw = newWallet(owner);

        pUSDC.mint(address(agw), 1000e6);
        vm.deal(address(agw), 10 ether);
    }

    /// @dev Mirrors the demo mandate: one target, one selector, beneficiary pinned at offset 4.
    function _config() internal view returns (bytes memory) {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: FAR_TARGET, selector: FAR_SELECTOR, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0
        });

        return abi.encode(
            IUCEP.Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 7 days),
                destChainHash: keccak256(abi.encode("eip155", "11155111")),
                expectedCEA: EXPECTED_CEA,
                asset: address(pUSDC),
                maxAmountPerCall: STAKE,
                // Generous: this suite advances a nonce lane with repeated real requests, and the
                // demo's own 60e6 lifetime cap would exhaust partway through. The caps themselves
                // are the gauntlet's subject, not this file's.
                maxAmountTotal: type(uint256).max,
                maxPCPerCall: 1 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    function _calls() internal pure returns (Multicall[] memory calls) {
        calls = new Multicall[](1);
        calls[0] =
            Multicall({ to: FAR_TARGET, value: 0, data: abi.encodeWithSelector(FAR_SELECTOR, EXPECTED_CEA, STAKE) });
    }

    function _executionCalldata() internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            GATEWAY, PC_VALUE, outboundRequest(address(pUSDC), STAKE, 0.01 ether, address(agw), _calls())
        );
    }

    /**
     * @notice The library's op hash must equal the one the wallet actually computed.
     *
     * @dev    `vm.expectEmit` with the hash from `AgentSigning` is the assertion: if the wallet
     *         emits any other value the expectation fails. The request is then driven all the way
     *         through — a signature built on a wrong hash would additionally fail validation, so
     *         this asserts the transcription twice over.
     */
    function test_opHash_equalsTheWalletsOwn() public {
        vm.prank(owner);
        bytes32 permissionId = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _executionCalldata();
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        uint48 expiry = uint48(block.timestamp + 30 minutes);

        // DISTINCT, NON-ZERO values for every field that can carry one. With nonceKey and nonceSeq
        // both left at 0 — the demo's own lane — transposing fields 8 and 9 produces an identical
        // hash and this test cannot see the swap. Mutation-checked: swapping them in the library
        // must fail here.
        uint192 key = LANE;
        uint64 seq = SEQ;

        // The wallet requires nonceSeq to equal its current lane counter, so advance the lane to
        // SEQ first with cheap throwaway requests on the same key.
        _advanceLane(permissionId, mode, key, seq);

        bytes32 expected = AgentSigning.opHash(
            block.chainid, address(agw), address(engine), permissionId, mode, ecd, key, seq, expiry
        );

        bytes memory sig = AgentSigning.signRequest(
            agentPk, block.chainid, address(agw), address(engine), permissionId, mode, ecd, key, seq, expiry
        );

        // If the wallet computes anything but `expected`, this expectation fails.
        vm.expectEmit(true, true, true, true, address(agw));
        emit IPushAgentWallet.MandateActionAuthorized(permissionId, key, seq, expected);

        vm.prank(relayer);
        agw.executeWithSession(address(engine), mode, ecd, sig, key, seq, expiry);
    }

    /// @dev Consume sequences 0..seq-1 on `key` so the next request lands at `seq`. Each is a real
    ///      validated request; the wallet has no other way to advance a lane.
    function _advanceLane(bytes32 permissionId, bytes32 mode, uint192 key, uint64 seq) internal {
        bytes memory ecd = _executionCalldata();
        for (uint64 i; i < seq; ++i) {
            bytes memory s = AgentSigning.signRequest(
                agentPk, block.chainid, address(agw), address(engine), permissionId, mode, ecd, key, i, 0
            );
            vm.prank(relayer);
            agw.executeWithSession(address(engine), mode, ecd, s, key, i, 0);
        }
    }

    /**
     * @notice A signature built on a DELIBERATELY WRONG hash must be rejected.
     *
     * @dev    Without this, the test above could pass against a wallet that ignored the hash
     *         entirely. Signing over a mutated expiry — one field of ten — must break validation.
     */
    function test_opHash_wrongFieldIsRejected() public {
        vm.prank(owner);
        bytes32 permissionId = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _executionCalldata();
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        uint48 expiry = uint48(block.timestamp + 30 minutes);

        // Signed over a different expiry than the one submitted.
        bytes memory sig = AgentSigning.signRequest(
            agentPk, block.chainid, address(agw), address(engine), permissionId, mode, ecd, 0, 0, expiry + 1
        );

        vm.prank(relayer);
        vm.expectRevert();
        agw.executeWithSession(address(engine), mode, ecd, sig, 0, 0, expiry);
    }

    /// @dev The envelope the library builds must be the shape the wallet parses: 98 bytes, USE
    ///      byte first, permission id in bytes 1:33. Asserted through acceptance, not by reading.
    function test_envelope_isAcceptedByTheWallet() public {
        vm.prank(owner);
        bytes32 permissionId = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _executionCalldata();
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());

        bytes memory sig = AgentSigning.signRequest(
            agentPk, block.chainid, address(agw), address(engine), permissionId, mode, ecd, 0, 0, 0
        );
        assertEq(sig.length, 98, "98-byte envelope");

        vm.prank(relayer);
        agw.executeWithSession(address(engine), mode, ecd, sig, 0, 0, 0);

        assertEq(uint256(agw.getNonce(0)), 1, "the wallet consumed the request");
    }
}
