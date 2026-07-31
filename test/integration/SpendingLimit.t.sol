// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import {
    Session,
    PolicyData,
    ActionData,
    ERC7739Data,
    ERC7739Context,
    PermissionId,
    SmartSessionMode
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { ERC20SpendingLimitPolicy } from "smartsessions/external/policies/ERC20SpendingLimitPolicy.sol";

/// @dev Minimal ERC-20 for the spend-cap test.
contract TestToken {
    string public name = "Test";
    string public symbol = "TST";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/**
 * @notice PRD §11.5 I-08 / §12 A-06 — the ADOPTED ERC20SpendingLimitPolicy, in isolation.
 *
 * ⚠ SCOPE — THIS DOES NOT COVER THE OUTBOUND FLOW.
 *
 * These tests bind the action to `(token, transfer)`. In the real flow the wallet
 * never calls the token: it calls `UniversalGatewayPC.sendUniversalTxOutbound`, and
 * the gateway burns the PRC20 internally. An ERC20SpendingLimitPolicy attached to
 * `(gateway, sendUniversalTxOutbound)` would try to decode `transfer(address,uint256)`
 * arguments out of an outbound request and read garbage — the two policies can never
 * both fire on the same action.
 *
 * The cumulative cap for the real flow is enforced by `ACPActionPolicy` R5b
 * (`maxAmountTotal` / `spent`), covered by P-21…P-24 and I-12. Do not read this file
 * as coverage for that.
 */
contract SpendingLimitTest is Test {
    PushAgentWallet internal wallet;
    AgentWalletFactory internal factory;
    SmartSession internal smartSession;
    PushSessionValidator internal sessionValidator;
    ERC20SpendingLimitPolicy internal spendPolicy;
    TestToken internal token;

    address internal ownerUEA = address(0xB0B);
    address internal provider = address(0x9209);
    address internal recipient = address(0xDE57);

    uint256 internal provKeyPk = 0xA11CE;
    address internal provKey;

    uint256 internal constant SPEND_CAP = 100e6;

    function setUp() public {
        provKey = vm.addr(provKeyPk);

        PushAgentWallet impl = new PushAgentWallet();
        factory = new AgentWalletFactory(address(impl));
        smartSession = new SmartSession();
        sessionValidator = new PushSessionValidator();
        spendPolicy = new ERC20SpendingLimitPolicy();
        token = new TestToken();

        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(keccak256("spend"))));
        token.mint(address(wallet), 1000e6);
    }

    function _grant() internal returns (PermissionId pid) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory limits = new uint256[](1);
        limits[0] = SPEND_CAP;

        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({ policy: address(spendPolicy), initData: abi.encode(tokens, limits) });

        ActionData[] memory actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: TestToken.transfer.selector,
            actionTarget: address(token),
            actionPolicies: actionPolicies
        });

        Session memory s = Session({
            sessionValidator: ISessionValidator(address(sessionValidator)),
            sessionValidatorInitData: abi.encode(uint8(0), abi.encodePacked(provKey)),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: true
        });

        Session[] memory sessions = new Session[](1);
        sessions[0] = s;

        vm.prank(ownerUEA);
        wallet.installModule(1, address(smartSession), "");

        bytes memory callData = abi.encodeCall(ISmartSession.enableSessions, (sessions));
        vm.prank(ownerUEA);
        bytes memory ret = wallet.callValidator(address(smartSession), callData);
        pid = abi.decode(ret, (PermissionId[]))[0];
    }

    function _transferCalldata(uint256 amount) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(token), 0, abi.encodeCall(TestToken.transfer, (recipient, amount)));
    }

    function _sign(PermissionId pid, ModeCode mode, bytes memory execCd, uint192 key, uint64 seq)
        internal
        view
        returns (bytes memory)
    {
        bytes32 opHash = keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v1"),
                block.chainid,
                address(wallet),
                address(smartSession),
                ModeCode.unwrap(mode),
                keccak256(execCd),
                key,
                seq
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(provKeyPk, opHash);
        return abi.encodePacked(SmartSessionMode.USE, pid, abi.encodePacked(r, s, v));
    }

    /// I-08 / A-06 — two calls totalling more than the cap: the second fails.
    function test_I08_A06_cumulativeSpendCapEnforced() public {
        PermissionId pid = _grant();
        ModeCode mode = ModeLib.encodeSimpleSingle();

        // First transfer of 60 — within the 100 cap.
        bytes memory cd1 = _transferCalldata(60e6);
        vm.prank(provider);
        wallet.executeWithSession(address(smartSession), mode, cd1, _sign(pid, mode, cd1, 0, 0), 0, 0);
        assertEq(token.balanceOf(recipient), 60e6, "first transfer must succeed");

        // Second transfer of 60 — cumulative 120 exceeds the cap.
        bytes memory cd2 = _transferCalldata(60e6);
        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, cd2, _sign(pid, mode, cd2, 0, 1), 0, 1);

        assertEq(token.balanceOf(recipient), 60e6, "cumulative cap must block the second");
    }

    function test_I08b_spendUpToExactCapSucceeds() public {
        PermissionId pid = _grant();
        ModeCode mode = ModeLib.encodeSimpleSingle();

        bytes memory cd = _transferCalldata(SPEND_CAP);
        vm.prank(provider);
        wallet.executeWithSession(address(smartSession), mode, cd, _sign(pid, mode, cd, 0, 0), 0, 0);
        assertEq(token.balanceOf(recipient), SPEND_CAP);

        // Anything further is refused.
        bytes memory cd2 = _transferCalldata(1);
        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, cd2, _sign(pid, mode, cd2, 0, 1), 0, 1);
    }

    /// The owner is never bound by the session's spend cap (C4).
    function test_I08c_ownerUnaffectedBySpendCap() public {
        _grant();
        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleSingle(), _transferCalldata(500e6));
        assertEq(token.balanceOf(recipient), 500e6);
    }
}
