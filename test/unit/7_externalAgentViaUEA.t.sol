// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { AGW } from "../../src/AGW.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { AGWErrors } from "../../src/libraries/Errors.sol";
import { AllowedCall, Config, Multicall } from "../../src/libraries/Types.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { MockUEA } from "../mocks/MockUEA.sol";

/**
 * @notice An external key acts as an agent only through its UEA.
 *
 * @dev    The agent is a Push address. A key from another chain (EVM, Solana, anything) is not one; its
 *         UEA is, and the UEA verifies that key before it ever calls the wallet. So the rules set names
 *         the UEA, the UEA is the sender the wallet checks, and the origin key calling the wallet
 *         directly is refused like any other stranger. `MockUEA` stands in for `UEA_EVM` with the same
 *         "only the origin key may drive me" rule; it decides no outcome under test.
 */
contract ExternalAgentViaUEATest is BaseTest {
    AGW internal wallet;
    address internal walletOwner;
    address internal cea;
    address internal protocol;
    address internal asset;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));

    function setUp() public override {
        super.setUp();
        walletOwner = makeAddr("walletOwner");
        cea = makeAddr("destinationAccount");
        protocol = makeAddr("farChainProtocol");
        asset = address(new MockPRC20());

        vm.warp(1_000_000_000);
        wallet = newWallet(walletOwner);
        vm.deal(address(wallet), 10 ether);
    }

    function _urpInitData() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: protocol, selector: SWAP_SELECTOR, beneficiaryOffset: 36, hasBeneficiary: true, maxValue: 0
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 30 days),
                expectedCEA: cea,
                maxGasPerCall: 1 ether,
                assets: oneAsset(asset, 100 ether, 1000 ether),
                allowedCalls: rules
            })
        );
    }

    function _ecd() internal view returns (bytes memory) {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: protocol, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), cea) });
        return
            ExecutionLib.encodeSingle(GATEWAY, 0, outboundRequest(asset, 1 ether, 0.01 ether, address(wallet), calls));
    }

    function test_UEAAgent_actsThroughItsUEA() public {
        (address originKey,) = ecdsaKey("externalOriginKey");
        MockUEA ua = new MockUEA(originKey);

        vm.prank(walletOwner);
        bytes32 pid = wallet.grantRules(canonicalSession(agentConfig(address(ua)), _urpInitData()));
        assertEq(wallet.agentOf(pid), address(ua), "the rules set names the UEA");

        etchCallRecorder(GATEWAY);
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        bytes memory ecd = _ecd();

        vm.expectEmit(true, true, false, true, address(wallet));
        emit IAGW.RulesActionAuthorized(pid, address(ua), keccak256(ecd));
        vm.prank(originKey);
        ua.exec(address(wallet), 0, abi.encodeCall(AGW.executeAsAgent, (pid, mode, ecd)));
        assertEq(callsRecorded(GATEWAY), 1, "the UEA's action dispatched");

        // The external key itself is not the agent: it acts only through its UEA.
        vm.prank(originKey);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid, originKey));
        wallet.executeAsAgent(pid, mode, ecd);
    }
}
