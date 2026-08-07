// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy, AllowedCall, Config } from "../../src/policies/ACPActionPolicy.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";
import {
    Session,
    PolicyData,
    ActionData,
    ERC7739Data,
    ERC7739Context,
    PermissionId,
    ActionId,
    ConfigId,
    SmartSessionMode
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { TimeFramePolicy } from "smartsessions/external/policies/TimeFramePolicy.sol";
import { ValueLimitPolicy } from "smartsessions/external/policies/ValueLimitPolicy.sol";

import { MockUniversalGatewayPC, MockUSV } from "../mocks/Mocks.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @notice Shared fixture for every v2 mandate-lifecycle suite.
 *
 * @dev Centralises the NORMATIVE §C.5 session template so the guard tests, the guardian
 *      tests and the multi-mandate tests all build sessions the same way. If the template
 *      changes, it changes in exactly one place.
 */
abstract contract MandateFixture is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;
    PushAgentWallet internal wallet;

    SmartSession internal smartSession;
    PushSessionValidator internal sessionValidator;
    ACPActionPolicy internal acp;
    TimeFramePolicy internal timeFrame;
    ValueLimitPolicy internal valueLimit;
    MockUniversalGatewayPC internal gateway;

    address internal constant USV_ADDR = 0xEC00000000000000000000000000000000000001;

    address internal ownerUEA = address(0xB0B);
    address internal guardian = address(0x6DA);
    address internal attacker = address(0xBAD);

    address internal expectedCEA = address(0xCEA);
    address internal asset = address(0xA55E7);
    address internal aavePool = address(0xAAAE);
    address internal usdc = address(0x115DC);

    uint48 internal constant VALID_UNTIL = 2_000_000_000;
    uint256 internal constant VALUE_LIMIT = 100 ether;
    uint256 internal constant MAX_PER_CALL = 1000e6;

    uint256 internal agentPk = 0xA11CE;
    address internal agentKey;

    bytes32 internal mandateA = keccak256("mandate-A");
    bytes32 internal mandateB = keccak256("mandate-B");

    function _deployStack() internal {
        agentKey = vm.addr(agentPk);

        // v2 order (Step 15): engine and policies BEFORE the wallet implementation.
        smartSession = new SmartSession();
        sessionValidator = new PushSessionValidator();
        gateway = new MockUniversalGatewayPC();
        acp = new ACPActionPolicy(address(gateway));
        timeFrame = new TimeFramePolicy();
        valueLimit = new ValueLimitPolicy();

        impl = new PushAgentWallet(
            address(smartSession), address(gateway), address(acp), address(timeFrame), address(valueLimit)
        );
        factory = new AgentWalletFactory(address(impl));

        MockUSV usv = new MockUSV();
        vm.etch(USV_ADDR, address(usv).code);

        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(guardian)));
    }

    function _installSmartSession() internal {
        if (!wallet.isModuleInstalled(1, address(smartSession), "")) {
            vm.prank(ownerUEA);
            wallet.installModule(1, address(smartSession), "");
        }
    }

    // ── config builders ───────────────────────────────────────────────

    /// @dev Aave supply. `expectedArg == address(0)` is the R9-ext CEA sentinel.
    function _supplyEntry() internal view returns (AllowedCall memory) {
        return AllowedCall({
            target: aavePool,
            selector: IAavePool.supply.selector,
            beneficiaryOffset: 68,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0)
        });
    }

    /// @dev CV-1-compliant approve entry: spender pinned to the protocol at offset 4.
    function _approveEntry() internal view returns (AllowedCall memory) {
        return AllowedCall({
            target: usdc,
            selector: IERC20Approve.approve.selector,
            beneficiaryOffset: 4,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: aavePool
        });
    }

    function _acpConfig(uint256 total) internal view returns (bytes memory) {
        return abi.encode(_acpConfigStruct(total));
    }

    /// @dev Built as a named local rather than inline in `abi.encode`: the inline form
    ///      pushed the ABI encoder over Yul's stack limit under `via_ir`.
    function _acpConfigStruct(uint256 total) internal view returns (Config memory cfg) {
        AllowedCall[] memory allowed = new AllowedCall[](2);
        allowed[0] = _supplyEntry();
        allowed[1] = _approveEntry();

        cfg.initialized = false;
        cfg.destChainHash = keccak256("eip155:1");
        cfg.expectedCEA = expectedCEA;
        cfg.asset = asset;
        cfg.maxAmountPerCall = MAX_PER_CALL;
        cfg.maxAmountTotal = total;
        cfg.maxPCPerCall = type(uint256).max;
        cfg.spent = 0;
        cfg.allowedCalls = allowed;
    }

    // ── session builders ──────────────────────────────────────────────

    /// @dev Knobs for building a session. Struct rather than positional parameters: the
    ///      flat form pushed `_sessionFull` over Yul's stack limit under via_ir.
    struct SessionSpec {
        bytes32 salt;
        address key;
        uint256 total;
        uint48 validUntil;
        uint256 vLimit;
        bool withACP;
        bool withValueLimit;
        address actionTarget;
    }

    /// @dev The NORMATIVE §C.5 template. Every deviation below is a negative test.
    function _session(bytes32 salt, address key, uint256 total) internal view returns (Session memory) {
        return _sessionFull(_spec(salt, key, total));
    }

    function _spec(bytes32 salt, address key, uint256 total) internal view returns (SessionSpec memory) {
        return SessionSpec({
            salt: salt,
            key: key,
            total: total,
            validUntil: VALID_UNTIL,
            vLimit: VALUE_LIMIT,
            withACP: true,
            withValueLimit: true,
            actionTarget: address(gateway)
        });
    }

    function _sessionFull(SessionSpec memory spec) internal view returns (Session memory s) {
        ActionData[] memory actions = new ActionData[](1);
        actions[0] = ActionData({
            actionTargetSelector: acp.SEND_OUTBOUND_SELECTOR(),
            actionTarget: spec.actionTarget,
            actionPolicies: _actionPolicies(spec)
        });

        s = Session({
            sessionValidator: ISessionValidator(address(sessionValidator)),
            sessionValidatorInitData: abi.encode(uint8(0), abi.encodePacked(spec.key)),
            salt: spec.salt,
            userOpPolicies: _timeFramePolicies(spec.validUntil, 12),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: true
        });
    }

    function _actionPolicies(SessionSpec memory spec) internal view returns (PolicyData[] memory p) {
        uint256 n = (spec.withACP ? 1 : 0) + (spec.withValueLimit ? 1 : 0);

        // W-3 shape: an action carrying only TimeFramePolicy satisfies minPolicies == 1
        // upstream while ACP never runs.
        if (n == 0) {
            p = new PolicyData[](1);
            p[0] = PolicyData({ policy: address(timeFrame), initData: abi.encodePacked(spec.validUntil, uint48(0)) });
            return p;
        }

        p = new PolicyData[](n);
        uint256 i;
        if (spec.withACP) p[i++] = PolicyData({ policy: address(acp), initData: _acpConfig(spec.total) });
        if (spec.withValueLimit) {
            p[i] = PolicyData({ policy: address(valueLimit), initData: abi.encode(spec.vLimit) });
        }
    }

    /// @param initLen Length of the TimeFrame initData blob; 12 is well-formed.
    function _timeFramePolicies(uint48 validUntil, uint256 initLen) internal view returns (PolicyData[] memory p) {
        p = new PolicyData[](1);
        bytes memory raw = abi.encodePacked(validUntil, uint48(0));
        if (initLen != 12) {
            bytes memory truncated = new bytes(initLen);
            for (uint256 i; i < initLen && i < raw.length; ++i) {
                truncated[i] = raw[i];
            }
            raw = truncated;
        }
        p[0] = PolicyData({ policy: address(timeFrame), initData: raw });
    }

    // ── grant paths ───────────────────────────────────────────────────

    function _grant(Session memory s) internal returns (bytes32 pid) {
        _installSmartSession();
        vm.prank(ownerUEA);
        pid = wallet.grantMandate(s);
    }

    /// @dev DELIBERATE guard bypass (S-14 forbids this in production). Used only where a
    ///      test must enable a malformed session that `grantMandate` would reject.
    function _grantRaw(Session memory s) internal returns (PermissionId pid) {
        Session[] memory arr = new Session[](1);
        arr[0] = s;
        _installSmartSession();
        vm.prank(ownerUEA);
        bytes memory ret =
            wallet.callValidator(address(smartSession), abi.encodeCall(ISmartSession.enableSessions, (arr)));
        pid = abi.decode(ret, (PermissionId[]))[0];
    }

    // ── id derivation (mirrors IdLib) ─────────────────────────────────

    function _acpConfigId(bytes32 pid) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(address(gateway), acp.SEND_OUTBOUND_SELECTOR()));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(pid, actionId));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), actionPolicyId)));
    }

    /// @dev `UserOpPolicyId` is the PermissionId itself, unhashed (`IdLib.sol:9-11`),
    ///      then `toConfigId` prefixes the account.
    function _userOpConfigId(bytes32 pid) internal view returns (ConfigId) {
        return ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), pid)));
    }

    // ── outbound op builders ──────────────────────────────────────────

    function _outboundCalldata(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        return abi.encodeWithSelector(acp.SEND_OUTBOUND_SELECTOR(), _request(beneficiary, amount));
    }

    function _request(address beneficiary, uint256 amount)
        internal
        view
        returns (UniversalOutboundTxRequest memory req)
    {
        req.recipient = "";
        req.token = asset;
        req.amount = amount;
        req.gasLimit = 0;
        req.gasPrice = 0;
        req.maxPCForGas = 0;
        req.payload = _payload(beneficiary, amount);
        req.revertRecipient = address(wallet);
    }

    function _payload(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 0, abi.encodeCall(IAavePool.supply, (usdc, amount, beneficiary, 0)));
        return abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls));
    }

    function _execCalldata(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(address(gateway), 0, _outboundCalldata(beneficiary, amount));
    }

    function _execCalldataWithValue(address beneficiary, uint256 amount, uint256 pcValue)
        internal
        view
        returns (bytes memory)
    {
        return ExecutionLib.encodeSingle(address(gateway), pcValue, _outboundCalldata(beneficiary, amount));
    }

    function _opHash(ModeCode mode, bytes memory execCd, uint192 key, uint64 seq) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v1"),
                block.chainid,
                address(wallet),
                address(smartSession),
                mode,
                keccak256(execCd),
                key,
                seq
            )
        );
    }

    function _sign(uint256 pk, bytes32 pid, bytes32 opHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, opHash);
        return abi.encodePacked(SmartSessionMode.USE, pid, abi.encodePacked(r, s, v));
    }

    /// @dev Drives one session-path outbound end to end.
    function _executeSession(bytes32 pid, uint256 pk, address beneficiary, uint256 amount, uint64 seq) internal {
        _executeSessionWithValue(pid, pk, beneficiary, amount, seq, 0);
    }

    function _executeSessionWithValue(
        bytes32 pid,
        uint256 pk,
        address beneficiary,
        uint256 amount,
        uint64 seq,
        uint256 pcValue
    ) internal {
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldataWithValue(beneficiary, amount, pcValue);
        uint192 key = uint192(uint256(pid));
        bytes memory sig = _sign(pk, pid, _opHash(mode, execCd, key, seq));
        wallet.executeWithSession(address(smartSession), mode, execCd, sig, key, seq);
    }

    /// @dev Non-reverting variant for tests that need to assert an op FAILS without
    ///      pinning the exact upstream revert shape.
    function _tryExecuteSession(bytes32 pid, uint256 pk, address beneficiary, uint256 amount, uint64 seq)
        internal
        returns (bool ok, bytes memory ret)
    {
        ModeCode mode = ModeLib.encodeSimpleSingle();
        bytes memory execCd = _execCalldataWithValue(beneficiary, amount, 0);
        uint192 key = uint192(uint256(pid));
        bytes memory sig = _sign(pk, pid, _opHash(mode, execCd, key, seq));
        (ok, ret) = address(wallet)
            .call(
                abi.encodeCall(PushAgentWallet.executeWithSession, (address(smartSession), mode, execCd, sig, key, seq))
            );
    }
}
