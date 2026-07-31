// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy, AllowedCall, Config } from "../../src/policies/ACPActionPolicy.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import {
    Session, PolicyData, ActionData, ERC7739Data, ERC7739Context, PermissionId, SmartSessionMode
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { TimeFramePolicy } from "smartsessions/external/policies/TimeFramePolicy.sol";

import { MockUniversalGatewayPC, MockUSV } from "../mocks/Mocks.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @notice PRD §11.5 — integration tests I-01 … I-11.
contract FullFlowTest is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;
    PushAgentWallet internal wallet;

    SmartSession internal smartSession;
    PushSessionValidator internal sessionValidator;
    ACPActionPolicy internal acp;
    TimeFramePolicy internal timeFrame;

    MockUniversalGatewayPC internal gateway;

    address internal constant USV_ADDR = 0xEC00000000000000000000000000000000000001;

    address internal ownerUEA = address(0xB0B);
    address internal provider = address(0x9209);
    address internal expectedCEA = address(0xCEA);
    address internal asset = address(0xA55E7);
    address internal aavePool = address(0xAAAE);
    address internal usdc = address(0x115DC);

    uint256 internal provKeyPk = 0xA11CE;
    address internal provKey;

    bytes32 internal mandateId = keccak256("mandate-1");
    uint256 internal constant MAX_AMOUNT = 1000e6;

    function setUp() public {
        provKey = vm.addr(provKeyPk);

        impl = new PushAgentWallet();
        factory = new AgentWalletFactory(address(impl));
        smartSession = new SmartSession();
        sessionValidator = new PushSessionValidator();
        gateway = new MockUniversalGatewayPC();
        acp = new ACPActionPolicy(address(gateway));
        timeFrame = new TimeFramePolicy();

        MockUSV usv = new MockUSV();
        vm.etch(USV_ADDR, address(usv).code);

        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(mandateId)));
    }

    // ── helpers ───────────────────────────────────────────────────────

    function _acpConfig() internal view returns (bytes memory) {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall(aavePool, IAaveV3Pool.supply.selector, 68, true);

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            allowedCalls: allowed
        });
        return abi.encode(cfg);
    }

    /// Builds a session granting `provKey` the right to call the gateway,
    /// gated by ACPActionPolicy (and optionally TimeFramePolicy).
    function _session(uint8 scheme, bytes memory key, uint48 validUntil)
        internal
        view
        returns (Session memory s)
    {
        PolicyData[] memory actionPolicies = new PolicyData[](validUntil == 0 ? 1 : 2);
        actionPolicies[0] = PolicyData({ policy: address(acp), initData: _acpConfig() });
        if (validUntil != 0) {
            actionPolicies[1] =
                PolicyData({ policy: address(timeFrame), initData: abi.encodePacked(validUntil, uint48(0)) });
        }

        ActionData[] memory actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: bytes4(0x77b86bec), // sendUniversalTxOutbound
            actionTarget: address(gateway),
            actionPolicies: actionPolicies
        });

        s = Session({
            sessionValidator: ISessionValidator(address(sessionValidator)),
            sessionValidatorInitData: abi.encode(scheme, key),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0),
                erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: true
        });
    }

    function _grantSession(Session memory s) internal returns (PermissionId permissionId) {
        Session[] memory sessions = new Session[](1);
        sessions[0] = s;

        vm.prank(ownerUEA);
        wallet.installModule(1, address(smartSession), "");

        bytes memory ret;
        bytes memory callData = abi.encodeCall(ISmartSession.enableSessions, (sessions));
        vm.prank(ownerUEA);
        ret = wallet.callValidator(address(smartSession), callData);

        PermissionId[] memory ids = abi.decode(ret, (PermissionId[]));
        permissionId = ids[0];
    }

    function _outboundCalldata(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 0, abi.encodeCall(IAaveV3Pool.supply, (usdc, amount, beneficiary, 0)));

        UniversalOutboundTxRequest memory req = UniversalOutboundTxRequest({
            recipient: "",
            token: asset,
            amount: amount,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls)),
            revertRecipient: address(wallet)
        });
        return abi.encodeWithSelector(bytes4(0x77b86bec), req);
    }

    function _execCalldata(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(gateway), 0, _outboundCalldata(beneficiary, amount));
    }

    function _opHash(ModeCode mode, bytes memory execCalldata, uint192 key, uint64 seq)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v1"),
                block.chainid,
                address(wallet),
                address(smartSession),
                ModeCode.unwrap(mode),
                keccak256(execCalldata),
                key,
                seq
            )
        );
    }

    function _sign(PermissionId permissionId, bytes32 opHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(provKeyPk, opHash);
        return abi.encodePacked(SmartSessionMode.USE, permissionId, abi.encodePacked(r, s, v));
    }

    // ── I-01 … I-03 — factory ─────────────────────────────────────────

    function test_I01_deploysAtPredictedAddress() public {
        bytes32 m = keccak256("m2");
        address predicted = factory.computeAgentWallet(ownerUEA, m);

        vm.prank(ownerUEA);
        address actual = factory.deployAgentWallet(m);

        assertEq(actual, predicted, "counterfactual address must be correct");
        assertEq(PushAgentWallet(payable(actual)).owner(), ownerUEA);
        assertTrue(factory.isDeployed(ownerUEA, m));
        assertEq(factory.walletOf(ownerUEA, m), actual);
    }

    function test_I02_duplicateMandateReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentWalletFactory.WalletAlreadyDeployed.selector, ownerUEA, mandateId, address(wallet)
            )
        );
        vm.prank(ownerUEA);
        factory.deployAgentWallet(mandateId);
    }

    function test_I03_differentMandateYieldsDifferentWallet() public {
        vm.prank(ownerUEA);
        address second = factory.deployAgentWallet(keccak256("other"));
        assertTrue(second != address(wallet), "blast-radius containment");
        assertEq(PushAgentWallet(payable(second)).owner(), ownerUEA);
    }

    function test_I03b_sameMandateDifferentOwnersAreDistinct() public {
        address alice = address(0xA11CE0);
        vm.prank(alice);
        address aliceWallet = factory.deployAgentWallet(mandateId);
        assertTrue(aliceWallet != address(wallet));
        assertEq(PushAgentWallet(payable(aliceWallet)).owner(), alice);
    }

    // ── I-04 — grant ──────────────────────────────────────────────────

    function test_I04_fullGrantSessionReadable() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        assertTrue(wallet.isModuleInstalled(1, address(smartSession), ""));
        assertTrue(smartSession.isPermissionEnabled(pid, address(wallet)), "session must be enabled");
    }

    // ── I-05 — the full happy path ────────────────────────────────────

    function test_I05_happyPathEcdsaSessionKey() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));

        // The provider submits and pays gas (D-16).
        vm.prank(provider);
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 1, "gateway must have been called");
        assertEq(gateway.lastSender(), address(wallet), "msg.sender at the gateway must be the wallet");
        assertEq(gateway.lastToken(), asset);
        assertEq(gateway.lastAmount(), 100e6);
        assertEq(gateway.lastRevertRecipient(), address(wallet));
    }

    /// A-05 end-to-end: the provider cannot redirect the beneficiary to itself.
    function test_I05b_A05_beneficiaryRedirectionBlockedEndToEnd() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(provider, 100e6); // provider as beneficiary
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));

        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 0, "no outbound may occur");
    }

    /// A-06 end-to-end: the provider cannot exceed the mandate amount.
    function test_I05c_A06_amountAboveMandateBlocked() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, MAX_AMOUNT + 1);
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));

        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 0);
    }

    function test_I05d_wrongSignerRejected() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, _opHash(mode, execCd, 0, 0));
        bytes memory sig = abi.encodePacked(SmartSessionMode.USE, pid, abi.encodePacked(r, s, v));

        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 0);
    }

    // ── I-06 — Ed25519 session key ────────────────────────────────────

    function test_I06_happyPathEd25519SessionKey() public {
        bytes32 pubKey = keccak256("solana-agent-pubkey");
        PermissionId pid = _grantSession(_session(1, abi.encodePacked(pubKey), 0));

        // Mocked USV accepts the signature.
        vm.store(USV_ADDR, bytes32(uint256(0)), bytes32(uint256(1)));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);
        bytes memory sig = abi.encodePacked(SmartSessionMode.USE, pid, new bytes(64));

        vm.prank(provider);
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 1, "Solana-keyed agent must operate the EVM account");
        assertEq(gateway.lastSender(), address(wallet));
    }

    function test_I06b_ed25519RejectedWhenUsvSaysNo() public {
        bytes32 pubKey = keccak256("solana-agent-pubkey");
        PermissionId pid = _grantSession(_session(1, abi.encodePacked(pubKey), 0));

        vm.store(USV_ADDR, bytes32(uint256(0)), bytes32(uint256(0))); // reject

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);
        bytes memory sig = abi.encodePacked(SmartSessionMode.USE, pid, new bytes(64));

        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);

        assertEq(gateway.callCount(), 0);
    }

    // ── I-07 — expiry ─────────────────────────────────────────────────

    function test_I07_sessionExpiry() public {
        vm.warp(1_000_000);
        uint48 validUntil = uint48(1_000_100);
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), validUntil));

        ModeCode mode = ModeLib.encodeSimpleSingle();

        // Before expiry: works.
        bytes memory execCd = _execCalldata(expectedCEA, 10e6);
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));
        vm.prank(provider);
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);
        assertEq(gateway.callCount(), 1);

        // After expiry: rejected.
        vm.warp(1_000_101);
        bytes memory execCd2 = _execCalldata(expectedCEA, 10e6);
        bytes memory sig2 = _sign(pid, _opHash(mode, execCd2, 0, 1));
        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd2, sig2, 0, 1);

        assertEq(gateway.callCount(), 1, "no further outbound after expiry");
    }

    // ── I-09 / I-10 — revocation ──────────────────────────────────────

    function test_I09_ownerRevokesSession() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        bytes memory removeCall = abi.encodeCall(ISmartSession.removeSession, (pid));
        vm.prank(ownerUEA);
        wallet.callValidator(address(smartSession), removeCall);

        assertFalse(smartSession.isPermissionEnabled(pid, address(wallet)));

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));

        vm.prank(provider);
        vm.expectRevert();
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);
        assertEq(gateway.callCount(), 0);
    }

    function test_I10_emergencyRevokeAllThenSessionFails() public {
        PermissionId pid = _grantSession(_session(0, abi.encodePacked(provKey), 0));

        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);

        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldata(expectedCEA, 100e6);
        bytes memory sig = _sign(pid, _opHash(mode, execCd, 0, 0));

        vm.prank(provider);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.ValidatorNotInstalled.selector, address(smartSession))
        );
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, 0, 0);
    }

    // ── I-11 — owner authority is unconditional (C4) ──────────────────

    function test_I11_ownerRetainsExecutePowerRegardlessOfSessionState() public {
        _grantSession(_session(0, abi.encodePacked(provKey), 0));

        // Owner can still drive the account directly.
        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleSingle(), _execCalldata(expectedCEA, 1e6));
        assertEq(gateway.callCount(), 1);

        // ... and after revoking everything.
        address[] memory vs = new address[](1);
        vs[0] = address(smartSession);
        vm.prank(ownerUEA);
        wallet.emergencyRevokeAll(vs);

        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleSingle(), _execCalldata(expectedCEA, 1e6));
        assertEq(gateway.callCount(), 2);
    }

    /// The owner is not constrained by ACPActionPolicy — policies bind sessions only.
    function test_I11b_ownerNotBoundByActionPolicy() public {
        _grantSession(_session(0, abi.encodePacked(provKey), 0));

        vm.prank(ownerUEA);
        wallet.execute(ModeLib.encodeSimpleSingle(), _execCalldata(provider, MAX_AMOUNT + 1));
        assertEq(gateway.callCount(), 1, "owner is the root authority (C4)");
    }
}
