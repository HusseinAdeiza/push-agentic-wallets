// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";

import { AllowedCall, Config, RulesType } from "../../src/libraries/Types.sol";

import { MockUniversalGateway, MockPRC20 } from "../mocks/MockUniversalGateway.sol";

import { AGW } from "../../src/AGW.sol";

import { AGWErrors } from "../../src/libraries/Errors.sol";

import { UniversalRulesPolicy } from "../../src/policies/UniversalRulesPolicy.sol";

import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

import { Multicall } from "../../src/libraries/Types.sol";

import {
    Session,
    PermissionId,
    ConfigId,
    SmartSessionMode,
    ValidationData,
    ActionData,
    PolicyData,
    ERC7739Context
} from "smartsessions/DataTypes.sol";

import { ISmartSession } from "smartsessions/ISmartSession.sol";

import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { IModule as IERC7579Module } from "erc7579/interfaces/IERC7579Module.sol";

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { EnableSession, ChainDigest } from "smartsessions/DataTypes.sol";

import { LibZip } from "solady/utils/LibZip.sol";

/**
 * @notice The S-suite — the deployment spec's §6 acceptance tests.
 *
 * @dev    These are the ENGINE-FACING properties: things that are true about how v3 wires
 *         SmartSession, rather than about any one contract. Several pair with a wallet test and
 *         neither is redundant — the pairing is stated in each docblock so neither is deleted.
 *
 * @dev    ZERO selector-less `vm.expectRevert()` in this file.
 */
contract EngineTest is BaseTest {
    MockUniversalGateway internal gateway;
    MockPRC20 internal pUSDC;

    AGW internal wallet;
    address internal WALLET_OWNER;

    address internal CEA;
    address internal PROTOCOL;

    bytes4 internal constant SUPPLY_SELECTOR = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    uint16 internal constant BENEFICIARY_OFFSET = 68;
    uint256 internal constant CAP = 100e6;

    address internal agentAddr;

    function setUp() public override {
        super.setUp();

        vm.etch(GATEWAY, type(MockUniversalGateway).runtimeCode);
        gateway = MockUniversalGateway(payable(GATEWAY));
        pUSDC = new MockPRC20();

        WALLET_OWNER = makeAddr("engineOwner");
        CEA = makeAddr("cea");
        PROTOCOL = makeAddr("protocol");
        agentAddr = makeAddr("engineAgent");

        vm.warp(1_700_000_000);

        wallet = newWallet(WALLET_OWNER);
        pUSDC.mint(address(wallet), CAP);
        vm.deal(address(wallet), 1 ether);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _urpConfig() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SUPPLY_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0
        });
        return universalInitData(
            Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 30 days),
                destChainHash: keccak256("eip155:1"),
                expectedCEA: CEA,
                asset: address(pUSDC),
                maxAmountPerCall: CAP,
                maxAmountTotal: CAP,
                maxPCPerCall: 1 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    function _calls(address beneficiary) internal view returns (Multicall[] memory c) {
        c = new Multicall[](1);
        c[0] = Multicall({
            to: PROTOCOL,
            value: 0,
            data: abi.encodeWithSelector(SUPPLY_SELECTOR, address(pUSDC), CAP, beneficiary, uint16(0))
        });
    }

    function _ecd(uint256 amount, address beneficiary) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            GATEWAY, 0, outboundRequest(address(pUSDC), amount, 0.01 ether, address(wallet), _calls(beneficiary))
        );
    }

    function _mode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    /// @dev The agent itself calls the agent door.
    function _act(address agent, bytes32 pid, bytes memory ecd) internal {
        vm.prank(agent);
        wallet.executeAsAgent(pid, _mode(), ecd);
    }

    function _grant(address agent) internal returns (bytes32) {
        vm.prank(WALLET_OWNER);
        return wallet.grantRules(canonicalSession(agentConfig(agent), _urpConfig()));
    }

    // ═══════════════════════════════════ S-01 ═══════════════════════════════════

    /**
     * S-01 ⚠️ NEVER-DELETE — ENABLE MODE IS STRUCTURALLY DEAD ON v3 WALLETS.
     *
     * ENABLE mode is a SECOND grant path: a session created inside a request, authorised by the
     * account's ERC-1271 signature. It would bypass the wallet's salt injection entirely — the one
     * thing that makes a regranted mandate a NEW mandate. It locks itself, because
     * `SmartSession.sol:154` requires `isValidSignature` to return the magic value and every v3
     * wallet returns `0xffffffff` permanently.
     *
     * BOTH modes are tested. `SmartSessionModeLib.sol:11-13` defines `isEnableMode()` as
     * `ENABLE || UNSAFE_ENABLE`, so they route through the same gate — and it is the one whose name
     * invites worry that an earlier draft left unpinned.
     *
     * PAIRING WITH W-28 (`test_W28_AgentDoor_AlwaysBuildsUseMode`), stated so neither is deleted as
     * redundant: W-28 proves the WALLET always builds a USE-mode operation — the agent door takes no
     * signature input, so no caller can choose an enable mode. S-01 proves that IF an enable-mode
     * operation reached the engine anyway, the 1271 gate would refuse it. Two independent layers,
     * two tests. This one deliberately BYPASSES the wallet by calling the engine directly as it.
     */
    function test_S01_EnableMode_DeadOnV3Wallets() public {
        _grant(agentAddr);

        // The wallet's own 1271 is permanently invalid — the fact the whole property rests on.
        assertEq(wallet.isValidSignature(bytes32(0), ""), bytes4(0xffffffff), "v3 wallets never sign as 1271");

        PackedUserOperation memory op;
        op.sender = address(wallet);
        op.callData = abi.encodeWithSelector(AGW.execute.selector, _mode(), _ecd(CAP, CEA));
        op.paymasterAndData = "";

        SmartSessionMode[2] memory modes = [SmartSessionMode.ENABLE, SmartSessionMode.UNSAFE_ENABLE];

        for (uint256 i; i < modes.length; ++i) {
            // A well-formed ENABLE-mode signature body. The engine derives the permission id from
            // the session data rather than reading bytes [1:33] — which is why the wallet never lets
            // a caller choose the mode (W-28).
            op.signature = abi.encodePacked(uint8(modes[i]), _enableBody(modes[i]));

            // Called AS THE WALLET, so the engine's `userOp.sender == msg.sender` check passes and
            // the request reaches the enable path.
            vm.prank(address(wallet));
            (bool ok, bytes memory ret) = address(engine)
                .call(abi.encodeWithSelector(ISmartSession.validateUserOp.selector, op, bytes32(uint256(1))));
            assertFalse(ok, "the ENABLE path is refused - the salt-bypassing grant cannot open");

            // AND IT IS REFUSED AT THE 1271 GATE SPECIFICALLY. Naming the error is the whole point:
            // a bare "it reverted" passed twice during development while the request was actually
            // dying earlier — first on a decode failure (empty returndata), then on HashMismatch.
            // Only `InvalidEnableSignature` proves the request reached SmartSession.sol:154 and was
            // turned away by the wallet's permanently-invalid isValidSignature.
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 0x20))
            }
            assertEq(sel, ISmartSession.InvalidEnableSignature.selector, "refused at the ERC-1271 gate");
        }
    }

    /**
     * @dev A GENUINELY WELL-FORMED EnableSession body, FastLZ-compressed exactly as the engine's own
     *      `EncodeLib.encodeEnable` does (`EncodeLib.sol:51`, `decodeEnable:54-60`).
     *
     *      This matters. An earlier version passed hand-rolled bytes; the engine failed to DECODE
     *      them and reverted with empty returndata, so the test passed without ever reaching the
     *      1271 gate it exists to prove. Compressing a real struct is what makes the refusal below
     *      the ENABLE-path refusal rather than a malformed-input refusal.
     */
    function _enableBody(SmartSessionMode mode) internal view returns (bytes memory) {
        Session memory toEnable = canonicalSession(agentConfig(agentAddr), _urpConfig());
        toEnable.salt = bytes32(uint256(0x5001));

        // The REAL digest for this session, from the engine itself. A zero digest fails the
        // hash check (`HashMismatch`) BEFORE the 1271 gate — measured — so the test would pass
        // without proving anything about ERC-1271.
        bytes32 digest = engine.getSessionDigest(engine.getPermissionId(toEnable), address(wallet), toEnable, mode);

        EnableSession memory enableData = EnableSession({
            chainDigestIndex: 0,
            hashesAndChainIds: new ChainDigest[](1),
            sessionToEnable: toEnable,
            permissionEnableSig: new bytes(65)
        });
        enableData.hashesAndChainIds[0] = ChainDigest({ chainId: uint64(block.chainid), sessionDigest: digest });

        return LibZip.flzCompress(abi.encode(enableData, new bytes(65)));
    }

    // ═══════════════════════════════════ S-02 ═══════════════════════════════════

    /**
     * S-02 — the canonical shape, one deviation per WIRING RULE.
     *
     * This is the deployment spec's view of wallet test W-24: W-24 enumerates every field, S-02
     * asks whether each of the five wiring rules is actually enforced. Both exist because the rules
     * are doctrine in one document and code in another.
     */
    function test_S02_CanonicalShape_Enforced() public {
        // the canonical session grants
        bytes32 pid = _grant(agentAddr);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), address(wallet)), "canonical grants");

        // RULE 2 — nothing in the zero-floor policy class
        Session memory s1 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        s1.userOpPolicies = new PolicyData[](1);
        s1.userOpPolicies[0] = PolicyData({ policy: address(urp), initData: "" });
        _expectShape(s1);

        // RULE 1 — no wildcard/fallback action: exactly one action
        Session memory s2 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        ActionData[] memory two = new ActionData[](2);
        two[0] = s2.actions[0];
        two[1] = s2.actions[0];
        s2.actions = two;
        _expectShape(s2);

        // RULE 4 — URP is the SOLE action policy (the fail-closed anchor)
        Session memory s3 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        s3.actions[0].actionPolicies = new PolicyData[](0);
        _expectShape(s3);

        // Only its ADDRESS matters — the shape check rejects a non-canonical policy without
        // calling it, so this needs no proxy and no initialisation.
        UniversalRulesPolicy other = new UniversalRulesPolicy();
        _expectShape(sessionWithPolicy(address(other), agentConfig(agentAddr), _urpConfig()));

        // RULE 5 — the paymaster flag is always false
        Session memory s4 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        s4.permitERC4337Paymaster = true;
        _expectShape(s4);

        // the 7739 path stays walled
        Session memory s5 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        s5.erc7739Policies.allowedERC7739Content = new ERC7739Context[](1);
        _expectShape(s5);

        // and the validator is pinned
        Session memory s6 = canonicalSession(agentConfig(agentAddr), _urpConfig());
        s6.sessionValidator = ISessionValidator(makeAddr("notOurValidator"));
        _expectShape(s6);
    }

    function _expectShape(Session memory s) internal {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(AGWErrors.MalformedSessionShape.selector);
        wallet.grantRules(s);
    }

    // ═══════════════════════════════════ S-03 ═══════════════════════════════════

    /**
     * S-03 — THE SESSION VALIDATOR IS CONSULTED LAST, and policies therefore observe calldata the
     * engine has not yet authenticated.
     *
     * The ordering regression guard for constraint H21, pinned on the engine itself by calling it
     * directly as the wallet, with an operation whose signature field names a NON-agent sender:
     *   (a) with a policy-violating payload, the POLICY error surfaces — the gauntlet ran before the
     *       validator was asked about the sender;
     *   (b) with a valid payload, the engine returns a failed verdict (authorizer `address(1)`) — the
     *       validator ran last and refused the sender.
     *
     * In production the wallet's own pre-check (`CallerIsNotAgent`) means a non-agent never reaches
     * the engine, so (b) is unreachable through the wallet. This test pins the engine's ordering
     * anyway, because URP's safety argument — no external calls, effects last, revert on every
     * failure — still rests on policies running before authentication completes.
     */
    function test_S03_SignatureVerifiedLast() public {
        bytes32 pid = _grant(agentAddr);
        address stranger = makeAddr("notTheAgent");

        // (a) A payload that violates URP gate 15 (beneficiary is the agent, not the CEA).
        PackedUserOperation memory op = _opFrom(stranger, pid, _ecd(CAP, agentAddr));
        vm.prank(address(wallet));
        expectUrpGate(abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, CEA, agentAddr));
        engine.validateUserOp(op, bytes32(uint256(1)));

        // (b) CONTROL: with a VALID payload, the non-agent sender is what fails — so the policy error
        // above really was the policy, not an artefact of the sender being wrong.
        op = _opFrom(stranger, pid, _ecd(CAP, CEA));
        vm.prank(address(wallet));
        uint256 vd = ValidationData.unwrap(engine.validateUserOp(op, bytes32(uint256(1))));
        // forge-lint: disable-next-line(unsafe-typecast)
        address authorizer = address(uint160(vd)); // ERC-4337 packing: the low 160 bits are the authorizer
        assertEq(authorizer, address(1), "the validator refused the non-agent sender, last");
    }

    /// @dev The operation the wallet builds, with `sender` written into the signature field — here
    ///      deliberately a non-agent, which the wallet itself would never write.
    function _opFrom(address sender, bytes32 pid, bytes memory ecd)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(wallet);
        op.callData = abi.encodeWithSelector(AGW.execute.selector, _mode(), ecd);
        op.paymasterAndData = "";
        op.signature = abi.encodePacked(SmartSessionMode.USE, pid, sender);
    }

    // ═══════════════════════════════════ S-04 ═══════════════════════════════════

    /**
     * S-04 — THE ENGINE'S FLOORS. A session stripped of URP validates NOTHING.
     *
     * This is the fail-closed anchor of the whole design: the engine requires a minimum of one
     * action policy (`SmartSession.sol:285,299,334`), and URP is the only one v3 ever attaches.
     * Strip it and every request dies — rather than passing unchecked.
     */
    function test_S04_EngineFloors() public {
        // The wallet's shape check refuses a zero-policy grant outright...
        Session memory stripped = canonicalSession(agentConfig(agentAddr), _urpConfig());
        stripped.actions[0].actionPolicies = new PolicyData[](0);
        _expectShape(stripped);

        // ...and even if such a session were enabled DIRECTLY on the engine, bypassing the wallet,
        // it validates nothing: the floor refuses it.
        Session[] memory arr = new Session[](1);
        arr[0] = stripped;
        arr[0].salt = bytes32(uint256(0xF100));

        vm.prank(address(wallet));
        bytes32 pid = PermissionId.unwrap(engine.enableSessions(arr)[0]);

        bytes memory ecd = _ecd(CAP, CEA);
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(pid)));
        _act(agentAddr, pid, ecd);

        // enableSessions with an EMPTY array reverts.
        Session[] memory empty = new Session[](0);
        vm.prank(address(wallet));
        vm.expectRevert(ISmartSession.InvalidData.selector);
        engine.enableSessions(empty);
    }

    // ═══════════════════════════════════ S-07 ═══════════════════════════════════

    /**
     * S-07 — THE OWNER DOOR REACHES `onUninstall` DIRECTLY, AND NOTHING DESYNCS.
     *
     * `SmartSessionBase.onUninstall` is `external` and msg.sender-scoped: it loops `removeSession`
     * over the caller's own sessions. The owner door is unconstrained (CORE RULE 9), so an owner
     * CAN call it through `execute` — that is `revokeAllRules` minus the wallet's `RulesRevoked` events.
     *
     * The spec claims this causes no desync that matters. Until this test that was ASSERTED rather
     * than SHOWN. What makes it true: neither `enableSessions` nor `validateUserOp` has an
     * install precondition, so a subsequent `grantRules` works unchanged.
     */
    function test_S07_OwnerDoor_DirectOnUninstall_NoDesync() public {
        _grant(agentAddr);
        _grant(makeAddr("secondSigner"));
        assertEq(engine.getPermissionIDs(address(wallet)).length, 2, "two mandates live");

        // The owner calls engine.onUninstall("") THROUGH execute.
        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        wallet.execute(
            _mode(), ExecutionLib.encodeSingle(address(engine), 0, abi.encodeCall(IERC7579Module.onUninstall, ("")))
        );

        // every session gone
        assertEq(engine.getPermissionIDs(address(wallet)).length, 0, "all sessions removed");

        // and NO wallet-side RulesRevoked events — it bypassed the wrapper
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                !(logs[i].emitter == address(wallet) && logs[i].topics[0] == keccak256("RulesRevoked(bytes32)")),
                "no RulesRevoked - the wrapper was bypassed"
            );
        }

        // A SUBSEQUENT GRANT SUCCEEDS and validates a request END TO END. This is the half that
        // proves there is no desync: the engine has no install precondition on either path.
        bytes32 pid = _grant(agentAddr);
        _act(agentAddr, pid, _ecd(CAP, CEA));

        assertEq(gateway.callCount(), 1, "a full request validated and dispatched after the direct uninstall");
    }

    // ═══════════════════════════════════ S-08 ═══════════════════════════════════

    /**
     * S-08 — THREE RULES SETS, ONE WALLET, FULLY INDEPENDENT.
     *
     * `permissionId = keccak256(sessionValidator, initData, salt)` — the agent configuration is an
     * INPUT to the rules set's identity, so two rules sets naming different agents are different
     * rules sets BY ARITHMETIC. There is no wallet-level agent slot and no way to reassign an agent
     * inside a rules set: a different agent is a different rules set (P3-D1).
     */
    function test_S08_MultiAgent_Independence() public {
        address[3] memory agents = [makeAddr("agentAlpha"), makeAddr("agentBravo"), makeAddr("agentCharlie")];
        bytes32[3] memory pids;

        for (uint256 i; i < 3; ++i) {
            pids[i] = _grant(agents[i]);
        }

        // pairwise distinct
        assertTrue(pids[0] != pids[1] && pids[1] != pids[2] && pids[0] != pids[2], "three distinct ids");
        assertEq(engine.getPermissionIDs(address(wallet)).length, 3, "three live rules sets");

        // each acts INDEPENDENTLY, under its own id
        for (uint256 i; i < 3; ++i) {
            _act(agents[i], pids[i], _ecd(0, CEA)); // amount 0 so the shared cap is not consumed
        }
        assertEq(gateway.callCount(), 3, "all three dispatched");

        // ONE AGENT CANNOT ACT UNDER ANOTHER'S RULES SET — the agents are not interchangeable.
        bytes memory ecd = _ecd(0, CEA);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pids[0], agents[1]));
        _act(agents[1], pids[0], ecd);

        // REVOKING ONE LEAVES THE OTHERS LIVE
        vm.prank(WALLET_OWNER);
        wallet.revokeRules(pids[1]);

        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pids[1]), address(wallet)), "bravo revoked");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pids[0]), address(wallet)), "alpha still live");
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pids[2]), address(wallet)), "charlie still live");
        assertEq(engine.getPermissionIDs(address(wallet)).length, 2, "two remain");

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pids[1], agents[1]));
        _act(agents[1], pids[1], ecd);

        // and alpha and charlie still act after bravo's revocation
        _act(agents[0], pids[0], ecd);
        _act(agents[2], pids[2], ecd);
        assertEq(gateway.callCount(), 5, "alpha and charlie unaffected by bravo's revocation");
    }
}
