// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../../test/Base.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { IPushAgentWallet } from "../../src/interfaces/IPushAgentWallet.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentSigning } from "../lib/AgentSigning.sol";
import { Requests } from "../lib/Requests.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";
import { MockUniversalGateway } from "../../test/mocks/MockUniversalGateway.sol";

contract MockPRC20b is ERC20 {
    constructor() ERC20("USDC.eth", "USDC.eth") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title  AgentRequestLiveTest
 * @notice Pins the two things Act 2 reads back off-chain, against the REAL wallet.
 *
 * @dev    WHY THIS EXISTS. `20_Stake` asserts that the op hash the wallet emitted equals the one it
 *         signed. That assertion is only worth anything if the event is decoded correctly — and a
 *         wrong decode fails in the WORST direction: it compares the wrong word, mismatches every
 *         time, and looks like a signing bug rather than a reading bug.
 *
 *         `MandateActionAuthorized(bytes32 indexed, uint192 indexed, uint64, bytes32)` puts TWO
 *         non-indexed fields in `data`. Decoding a lone `bytes32` reads `nonceSeq`. An earlier
 *         version of `20_Stake` did exactly that; this test is what would have caught it.
 *
 *         Everything here runs against the real engine, validator, UCEP and wallet from `BaseTest`.
 */
contract AgentRequestLiveTest is BaseTest {
    MockPRC20b internal pUSDC;
    PushAgentWallet internal agw;

    address internal owner = makeAddr("uea");
    address internal agent;
    uint256 internal agentPk;
    address internal relayer = makeAddr("relayer");

    address internal constant FAR_TARGET = address(0xDEAD02);
    address internal constant EXPECTED_CEA = address(0xCEA002);
    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));

    uint256 internal constant AMOUNT = 50e6;
    uint256 internal constant PC_VALUE = 0.05 ether;

    function setUp() public override {
        super.setUp();
        (agent, agentPk) = makeAddrAndKey("agent");

        pUSDC = new MockPRC20b();
        MockUniversalGateway g = new MockUniversalGateway();
        vm.etch(GATEWAY, address(g).code);

        agw = newWallet(owner);
        pUSDC.mint(address(agw), 1000e6);
        vm.deal(address(agw), 10 ether);
    }

    function _config() internal view returns (bytes memory) {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: FAR_TARGET, selector: STAKE_FOR, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0
        });

        return abi.encode(
            IUCEP.Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 7 days),
                destChainHash: keccak256(abi.encode("eip155", "11155111")),
                expectedCEA: EXPECTED_CEA,
                asset: address(pUSDC),
                maxAmountPerCall: AMOUNT,
                maxAmountTotal: type(uint256).max,
                maxPCPerCall: 1 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    function _exec() internal view returns (bytes memory) {
        Multicall[] memory calls =
            Requests.singleCall(FAR_TARGET, abi.encodeWithSelector(STAKE_FOR, EXPECTED_CEA, AMOUNT));
        return Requests.execution(
            GATEWAY, PC_VALUE, Requests.outbound(address(pUSDC), AMOUNT, 0.01 ether, address(agw), calls)
        );
    }

    /**
     * @notice THE DECODE. Reads `MandateActionAuthorized` exactly as `20_Stake` does and asserts
     *         the recovered op hash equals the one signed.
     */
    function test_opHashIsRecoverableFromTheEvent() public {
        vm.prank(owner);
        bytes32 pid = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _exec();
        bytes32 mode = Requests.singleMode();
        uint48 expiry = uint48(block.timestamp + 30 minutes);

        bytes32 expected =
            AgentSigning.opHash(block.chainid, address(agw), address(engine), pid, mode, ecd, 0, 0, expiry);
        bytes memory sig = AgentSigning.signRequest(
            agentPk, block.chainid, address(agw), address(engine), pid, mode, ecd, 0, 0, expiry
        );

        vm.recordLogs();
        vm.prank(relayer);
        agw.executeWithSession(address(engine), mode, ecd, sig, 0, 0, expiry);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPushAgentWallet.MandateActionAuthorized.selector) {
                // The decode under test: TWO non-indexed fields, `nonceSeq` then `opHash`.
                (uint64 seq, bytes32 emitted) = abi.decode(logs[i].data, (uint64, bytes32));
                assertEq(seq, 0, "nonceSeq is the FIRST non-indexed field");
                assertEq(emitted, expected, "opHash is the SECOND; decoding one word reads the nonce");
                found = true;
            }
        }
        assertTrue(found, "the wallet must emit MandateActionAuthorized");
    }

    /// @dev The indexed fields live in topics, not data — which is why `data` holds only two words.
    function test_indexedFieldsAreInTopics() public {
        vm.prank(owner);
        bytes32 pid = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _exec();
        bytes32 mode = Requests.singleMode();
        bytes memory sig =
            AgentSigning.signRequest(agentPk, block.chainid, address(agw), address(engine), pid, mode, ecd, 0, 0, 0);

        vm.recordLogs();
        vm.prank(relayer);
        agw.executeWithSession(address(engine), mode, ecd, sig, 0, 0, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPushAgentWallet.MandateActionAuthorized.selector) {
                assertEq(logs[i].topics.length, 3, "signature + two indexed fields");
                assertEq(logs[i].topics[1], pid, "permissionId is indexed");
                assertEq(uint256(logs[i].topics[2]), 0, "nonceKey is indexed");
                assertEq(logs[i].data.length, 64, "exactly two non-indexed words");
                return;
            }
        }
        revert("event not found");
    }

    /// @dev `Requests.outbound` must produce bytes UCEP accepts. If the struct mirror or the
    ///      multicall prefix were wrong, the request would die at a gate rather than execute — so a
    ///      successful run is itself the assertion that the encoding is right.
    function test_requestsLibraryProducesAnAcceptedOutbound() public {
        vm.prank(owner);
        bytes32 pid = agw.grantMandate(canonicalSession(ecdsaConfig(agent), _config()));

        bytes memory ecd = _exec();
        bytes32 mode = Requests.singleMode();
        bytes memory sig =
            AgentSigning.signRequest(agentPk, block.chainid, address(agw), address(engine), pid, mode, ecd, 0, 0, 0);

        vm.prank(relayer);
        agw.executeWithSession(address(engine), mode, ecd, sig, 0, 0, 0);

        assertEq(uint256(agw.getNonce(0)), 1, "the request was accepted and the lane advanced");
    }
}
