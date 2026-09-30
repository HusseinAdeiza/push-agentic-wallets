// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { MockUEA } from "../mocks/MockUEA.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { StakeDummy } from "../mocks/StakeDummy.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AGWFactory } from "../../src/AGWFactory.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "../../src/libraries/ExecutionLib.sol";
import {
    OwnerIntent,
    OWNER_LANE_FLAG,
    OWNER_INTENT_TYPEHASH,
    Multicall
} from "../../src/libraries/PushWalletTypes.sol";
import { Session, ActionData, PolicyData, PermissionId, ConfigId, SmartSessionMode } from "smartsessions/DataTypes.sol";

// Core — INTERFACES AND MIRRORS ONLY. The implementations are deployed from the core repo's own build
// artifacts with vm.deployCode, so this suite runs the bytecode that ships (see foundry.toml).
import { IAgenticCommerce } from "push-core/agentic-commerce-8183/interfaces/IAgenticCommerce.sol";
import { IMandateBindingHook } from "push-core/agentic-commerce-8183/interfaces/IMandateBindingHook.sol";
import {
    IUniversalMarketplace,
    IUniversalMarketplaceErrors
} from "push-core/agentic-commerce-8183/interfaces/IUniversalMarketplace.sol";
import { ICEAFactory } from "push-core/Interfaces/ICEAFactory.sol";
import { IAGWFactory as CoreFactoryMirror } from "push-core/agentic-commerce-8183/interfaces/external/IAGWFactory.sol";
import {
    OwnerIntent as CoreIntent,
    OWNER_LANE_FLAG as CORE_OWNER_LANE_FLAG,
    Session as CoreSession,
    AllowedCall as CoreAllowedCall,
    UniversalTerms as CoreUniversalTerms,
    NativeTerms as CoreNativeTerms,
    IPushAgentWallet as CoreWalletMirror
} from "push-core/agentic-commerce-8183/interfaces/external/IPushAGW.sol";

interface IHookBinding {
    function mandateOf(uint256 jobId) external view returns (address agw, bytes32 permissionId);
}

interface IMarketplaceAdmin {
    function initialize(address, address, address, address, address) external;
    function setCEADeployment(bytes32, address, address) external;
    function terms() external view returns (address);
}

/**
 * @title  UniversalMarketplace — end to end against the REAL AGW stack.
 * @notice Real SmartSession, URP, PushSessionValidator, PushAgentWallet and AGWFactory (this repo), real
 *         AgenticCommerce, MandateBindingHook, UniversalMarketplace(+Terms) and CEAFactory (the core repo's
 *         shipped artifacts). The owner is a MockUEA that verifies exactly as UEA_EVM does.
 *
 * @dev    Requires `forge build` in lib/push-chain-core-contracts first.
 */
contract MarketplaceE2ETest is BaseTest {
    string internal constant CORE_OUT = "lib/push-chain-core-contracts/out/";
    bytes32 internal constant SEPOLIA_HASH = keccak256("eip155:11155111");
    bytes4 internal constant SWAP = bytes4(keccak256("swap(uint256,address)"));
    uint256 internal constant PRINCIPAL = 500e6;
    uint256 internal constant FEE = 2e6;

    IAgenticCommerce internal kernel;
    address internal hook;
    IUniversalMarketplace internal mkt;
    address internal mktImpl;
    ICEAFactory internal ceaFactory;
    address internal ceaProxyImpl;

    MockERC20 internal pUSDC; // the kernel's payment token, on Push
    address internal destAsset; // the far-chain asset a UNIVERSAL mandate bridges
    StakeDummy internal stake;

    address internal coreAdmin;
    address internal provider;
    address internal evaluator;
    address internal agentAddr;
    uint256 internal agentPk;
    address internal originAddr;
    uint256 internal originPk;
    MockUEA internal uea;
    address internal PROTOCOL;

    uint256 internal universalCard;
    uint256 internal nativeCard;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        coreAdmin = makeAddr("coreAdmin");
        provider = makeAddr("providerUEA");
        evaluator = makeAddr("evaluator");
        PROTOCOL = makeAddr("farProtocol");
        (agentAddr, agentPk) = ecdsaKey("providerAgentKey");
        (originAddr, originPk) = ecdsaKey("userOriginKey");
        uea = new MockUEA(originAddr);

        pUSDC = new MockERC20();
        destAsset = address(new MockPRC20()); // answers SOURCE_CHAIN_NAMESPACE = eip155:11155111
        stake = new StakeDummy(pUSDC);

        _deployCore();
        _registerCards();

        pUSDC.mint(address(uea), 1e15);
        vm.deal(address(uea), 100 ether);
    }

    // ═════════════════════════════ core deployment, from artifacts ═════════════════════════════

    function _artifact(string memory name) internal pure returns (string memory) {
        return string.concat(CORE_OUT, name, ".sol/", name, ".json");
    }

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return deployCode(_artifact("TransparentUpgradeableProxy"), abi.encode(impl, coreAdmin, init));
    }

    function _deployCore() internal {
        kernel = IAgenticCommerce(
            _proxy(
                deployCode(_artifact("AgenticCommerce")),
                abi.encodeWithSignature("initialize(address,address,address)", address(pUSDC), coreAdmin, coreAdmin)
            )
        );
        hook = _proxy(
            deployCode(_artifact("MandateBindingHook")),
            abi.encodeWithSignature("initialize(address,address,address)", address(kernel), FACTORY, address(engine))
        );
        vm.prank(coreAdmin);
        kernel.setHookWhitelist(hook, true);

        ceaProxyImpl = makeAddr("ceaProxyImpl");
        ceaFactory = ICEAFactory(
            _proxy(
                deployCode(_artifact("CEAFactory")),
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,address,address)",
                    coreAdmin,
                    coreAdmin,
                    makeAddr("vault"),
                    ceaProxyImpl,
                    makeAddr("ceaImpl"),
                    makeAddr("destGateway")
                )
            )
        );

        address termsC = deployCode(_artifact("UniversalMarketplaceTerms"));
        mktImpl = deployCode(_artifact("UniversalMarketplace"));
        mkt = IUniversalMarketplace(
            _proxy(
                mktImpl,
                abi.encodeCall(IMarketplaceAdmin.initialize, (FACTORY, address(kernel), hook, termsC, coreAdmin))
            )
        );
        vm.prank(coreAdmin);
        mkt.setCEADeployment(SEPOLIA_HASH, address(ceaFactory), ceaProxyImpl);
    }

    // ═════════════════════════════ cards ═════════════════════════════

    function _card(bytes32 chainHash, uint8 kind) internal view returns (IUniversalMarketplace.AgentCard memory c) {
        c.evaluator = evaluator;
        c.executionKeyHash = keccak256(ecdsaConfig(agentAddr));
        c.chainHash = chainHash;
        c.kind = kind;
        c.feeAmount = FEE;
        c.principalMin = 100e6;
        c.principalMax = 1_000e6;
        c.minDurationSeconds = 1 hours;
        c.maxDurationSeconds = 30 days;
        c.minPcBalance = 1 ether;
        c.cardURI = "ipfs://card";
    }

    function _allowed() internal view returns (IURP.AllowedCall[] memory rules) {
        rules = new IURP.AllowedCall[](1);
        rules[0] = IURP.AllowedCall({
            target: PROTOCOL, selector: SWAP, beneficiaryOffset: 36, hasBeneficiary: true, maxValue: 0
        });
    }

    function _uCardTerms() internal view returns (bytes memory) {
        IURP.AllowedCall[] memory rules = _allowed();
        CoreAllowedCall[] memory mirror = abi.decode(abi.encode(rules), (CoreAllowedCall[]));
        return abi.encode(
            IUniversalMarketplace.UniversalCardTerms({ asset: destAsset, maxPCPerCall: 1 ether, allowedCalls: mirror })
        );
    }

    function _nCardTerms() internal view returns (bytes memory) {
        IUniversalMarketplace.NativeActionTemplate[] memory a = new IUniversalMarketplace.NativeActionTemplate[](2);
        IUniversalMarketplace.PinTemplate[] memory p0 = new IUniversalMarketplace.PinTemplate[](1);
        p0[0] = IUniversalMarketplace.PinTemplate({ offset: 4, mode: 1, expected: bytes32(0) }); // BENEFICIARY
        a[0] = IUniversalMarketplace.NativeActionTemplate({
            target: address(stake),
            selector: StakeDummy.stakeFor.selector,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            amountEnabled: true,
            amountOffset: 36,
            amountBoundsPrincipal: true,
            amountMaxPerCall: 0,
            amountMaxTotal: 0,
            maxCalls: 20,
            pins: p0
        });
        IUniversalMarketplace.PinTemplate[] memory p1 = new IUniversalMarketplace.PinTemplate[](1);
        p1[0] = IUniversalMarketplace.PinTemplate({ offset: 4, mode: 2, expected: bytes32(0) }); // USER_CHOICE
        a[1] = IUniversalMarketplace.NativeActionTemplate({
            target: address(stake),
            selector: StakeDummy.depositFor.selector,
            maxValuePerCall: 1 ether,
            maxValueTotal: 2 ether,
            amountEnabled: false,
            amountOffset: 0,
            amountBoundsPrincipal: false,
            amountMaxPerCall: 0,
            amountMaxTotal: 0,
            maxCalls: 5,
            pins: p1
        });
        return abi.encode(a);
    }

    function _registerCards() internal {
        vm.startPrank(provider);
        universalCard = mkt.registerCard(_card(SEPOLIA_HASH, 0), _uCardTerms());
        nativeCard = mkt.registerCard(_card(keccak256(bytes(nativeChain())), 1), _nCardTerms());
        vm.stopPrank();
    }

    // ═════════════════════════════ sessions (real AGW types) ═════════════════════════════

    function _expiredAt() internal view returns (uint48) {
        return uint48(block.timestamp + 7 days);
    }

    function _uSession(address agw, address expectedCEA) internal view returns (Session memory) {
        return canonicalSession(
            ecdsaConfig(agentAddr),
            universalInitData(
                IURP.Config({
                    initialized: false,
                    validUntil: _expiredAt(),
                    destChainHash: bytes32(0),
                    expectedCEA: expectedCEA,
                    asset: destAsset,
                    maxAmountPerCall: PRINCIPAL,
                    maxAmountTotal: PRINCIPAL,
                    maxPCPerCall: 1 ether,
                    spent: 0,
                    allowedCalls: _allowed()
                })
            )
        );
    }

    function _nativeAction(IURP.NativeConfig memory cfg) internal view returns (ActionData memory) {
        PolicyData[] memory pol = new PolicyData[](1);
        pol[0] = PolicyData({ policy: address(urp), initData: nativeInitData(cfg) });
        return ActionData({ actionTargetSelector: cfg.selector, actionTarget: cfg.target, actionPolicies: pol });
    }

    function _nSession(address agw) internal view returns (Session memory s) {
        IURP.ArgPin[] memory p0 = new IURP.ArgPin[](1);
        p0[0] = IURP.ArgPin({ offset: 4, expected: bytes32(uint256(uint160(agw))) });
        IURP.ArgPin[] memory p1 = new IURP.ArgPin[](1);
        p1[0] = IURP.ArgPin({ offset: 4, expected: bytes32(uint256(uint160(agw))) }); // the user's choice
        IURP.NativeConfig memory c0;
        c0.validUntil = _expiredAt();
        c0.target = address(stake);
        c0.selector = StakeDummy.stakeFor.selector;
        c0.amount = IURP.AmountRule({ enabled: true, offset: 36, maxPerCall: PRINCIPAL, maxTotal: PRINCIPAL });
        c0.maxCalls = 20;
        c0.pins = p0;
        IURP.NativeConfig memory c1;
        c1.validUntil = _expiredAt();
        c1.target = address(stake);
        c1.selector = StakeDummy.depositFor.selector;
        c1.maxValuePerCall = 1 ether;
        c1.maxValueTotal = 2 ether;
        c1.maxCalls = 5;
        c1.pins = p1;
        s = canonicalSession(ecdsaConfig(agentAddr), "");
        s.actions = new ActionData[](2);
        s.actions[0] = _nativeAction(c0);
        s.actions[1] = _nativeAction(c1);
    }

    function _mirror(Session memory s) internal pure returns (CoreSession memory) {
        return abi.decode(abi.encode(s), (CoreSession));
    }

    // ═════════════════════════════ the two signatures ═════════════════════════════

    /// @dev Signature 1: the UEA's payload — exact allowance to the marketplace, PC to the predicted AGW.
    function _phase1(address agw) internal {
        vm.startPrank(originAddr);
        uea.exec(address(pUSDC), 0, abi.encodeCall(MockERC20.approve, (address(mkt), PRINCIPAL + FEE)));
        uea.exec(agw, 2 ether, "");
        vm.stopPrank();
    }

    /// @dev Signature 2: the OwnerIntent, exactly as previewIntent returns it, signed by the origin key.
    function _params(uint256 cardId, bytes memory cardTerms, Session memory s, uint96 index)
        internal
        returns (IUniversalMarketplace.StartJobParams memory p)
    {
        p.cardId = cardId;
        p.principal = PRINCIPAL;
        p.expiredAt = _expiredAt();
        p.cardTerms = cardTerms;
        p.session = _mirror(s);
        p.intent = mkt.previewIntent(
            cardId, address(uea), index, p.expiredAt, PRINCIPAL, p.session, uint48(block.timestamp + 1 hours), 1
        );
        p.sig = signIntent(originPk, _agwIntent(p.intent));
        p.label = "marketplace";
    }

    function _agwIntent(CoreIntent memory i) internal pure returns (OwnerIntent memory) {
        return abi.decode(abi.encode(i), (OwnerIntent));
    }

    function _start(IUniversalMarketplace.StartJobParams memory p)
        internal
        returns (uint256 jobId, address agw, bytes32 pid)
    {
        vm.prank(RELAYER);
        return mkt.startJob(p);
    }

    function _freshUniversal() internal returns (IUniversalMarketplace.StartJobParams memory p, address agw) {
        uint96 idx;
        (agw, idx) = nextWallet(address(uea));
        p = _params(universalCard, _uCardTerms(), _uSession(agw, ceaFactory.computeCEA(agw)), idx);
        _phase1(agw);
    }

    function _configId(address agw, bytes32 pid) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(keccak256(abi.encodePacked(agw, keccak256(abi.encodePacked(pid, actionId)))));
    }

    // ═════════════════════════════ E2E ═════════════════════════════

    function test_E2E_01_universalCard_freshUser() public {
        (IUniversalMarketplace.StartJobParams memory p, address predicted) = _freshUniversal();
        (uint256 jobId, address agw, bytes32 pid) = _start(p);

        assertEq(agw, predicted, "wallet at the predicted address");
        assertEq(factory.ownerOf(agw), address(uea), "owned by the user's UEA");
        assertEq(PushAgentWallet(payable(agw)).owner(), address(uea));

        IURP.Config memory cfg = urp.getConfig(_configId(agw, pid), agw);
        assertEq(cfg.asset, destAsset);
        assertEq(cfg.maxAmountTotal, PRINCIPAL);
        assertEq(cfg.maxPCPerCall, 1 ether);
        assertEq(cfg.validUntil, p.expiredAt);
        assertEq(cfg.expectedCEA, mkt.expectedCEAOf(agw, SEPOLIA_HASH));
        assertEq(cfg.expectedCEA, ceaFactory.computeCEA(agw));
        assertEq(cfg.allowedCalls.length, 1);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(pid), agw));

        IAgenticCommerce.Job memory j = kernel.getJob(jobId);
        assertEq(j.client, agw);
        assertEq(j.provider, provider);
        assertEq(j.hook, hook);
        assertEq(uint8(j.status), uint8(IAgenticCommerce.JobStatus.Open));

        assertEq(pUSDC.balanceOf(agw), PRINCIPAL + FEE);
        assertGe(agw.balance, 1 ether);
        assertEq(PushAgentWallet(payable(agw)).getNonce(OWNER_LANE_FLAG), 1);
        assertEq(PushAgentWallet(payable(agw)).grantNonce(), 1);
    }

    function test_E2E_02_nativeCard_freshUser() public {
        (address agw, uint96 idx) = nextWallet(address(uea));
        IUniversalMarketplace.StartJobParams memory p = _params(nativeCard, _nCardTerms(), _nSession(agw), idx);
        _phase1(agw);
        (uint256 jobId, address got, bytes32 pid) = _start(p);
        assertEq(got, agw);
        assertEq(kernel.getJob(jobId).client, agw);

        bytes32[] memory actionIds = engine.getEnabledActions(agw, PermissionId.wrap(pid));
        assertEq(actionIds.length, 2);
        for (uint256 i; i < 2; ++i) {
            ConfigId cid =
                ConfigId.wrap(keccak256(abi.encodePacked(agw, keccak256(abi.encodePacked(pid, actionIds[i])))));
            IURP.NativeConfig memory n = urp.getNativeConfig(cid, agw);
            assertEq(n.validUntil, p.expiredAt);
            assertEq(n.pins.length, 1);
            assertEq(n.pins[0].expected, bytes32(uint256(uint160(agw))));
        }
    }

    function test_E2E_03_returningUser_existingWallet() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (uint256 job1, address agw,) = _start(p);
        vm.prank(provider);
        kernel.reject(job1, bytes32(0), "");

        IUniversalMarketplace.StartJobParams memory q =
            _params(universalCard, _uCardTerms(), _uSession(agw, ceaFactory.computeCEA(agw)), 0);
        assertEq(q.intent.grantNonce, 1);
        assertEq(q.intent.nonceSeq, 1);
        _phase1(agw);
        (uint256 job2, address again,) = _start(q);
        assertEq(again, agw);
        assertEq(factory.walletCount(address(uea)), 1);
        assertEq(kernel.getJob(job2).client, agw);
    }

    function test_E2E_04_secondStartJob_whileOpen_revertsAGWBusy() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (uint256 job1, address agw,) = _start(p);
        IUniversalMarketplace.StartJobParams memory q =
            _params(universalCard, _uCardTerms(), _uSession(agw, ceaFactory.computeCEA(agw)), 0);
        _phase1(agw);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IUniversalMarketplaceErrors.AGWBusy.selector, agw, job1));
        mkt.startJob(q);
    }

    /// @dev Forward-looking: the binding key the marketplace recorded is what the hook binds at fund.
    function test_E2E_05_afterSetBudget_andFund_hookBindsMandate() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (uint256 jobId, address agw, bytes32 pid) = _start(p);
        vm.prank(provider);
        kernel.setBudget(jobId, FEE, "");

        Execution[] memory b = new Execution[](2);
        b[0] = Execution({
            target: address(pUSDC), value: 0, callData: abi.encodeCall(MockERC20.approve, (address(kernel), FEE))
        });
        b[1] = Execution({
            target: address(kernel),
            value: 0,
            callData: abi.encodeCall(
                IAgenticCommerce.fund, (jobId, FEE, abi.encode(IMarketplaceView(address(mkt)).mandateOfJob(jobId)))
            )
        });
        vm.prank(originAddr);
        uea.exec(
            agw,
            0,
            abi.encodeCall(
                PushAgentWallet.execute, (ModeCode.unwrap(ModeLib.encodeSimpleBatch()), ExecutionLib.encodeBatch(b))
            )
        );

        (address boundAgw, bytes32 boundPid) = IHookBinding(hook).mandateOf(jobId);
        assertEq(boundAgw, agw);
        assertEq(boundPid, pid);
        assertTrue(IMandateBindingHook(hook).isAGWBusy(agw));
        assertEq(uint8(kernel.getJob(jobId).status), uint8(IAgenticCommerce.JobStatus.Funded));
    }

    /// @dev The compiled mandate is live and correct: the provider's key acts inside the card, not outside.
    function test_E2E_06_providerKeyCanExecuteUnderMandate() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (, address agw, bytes32 pid) = _start(p);
        address cea = ceaFactory.computeCEA(agw);
        etchCallRecorder(GATEWAY);

        Multicall[] memory ok = new Multicall[](1);
        ok[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP, uint256(1), cea) });
        _agentRequest(agw, pid, outboundRequest(destAsset, 100e6, 1 ether, agw, ok), 0, "");
        assertEq(callsRecorded(GATEWAY), 1, "inside the allow-list: dispatched");

        Multicall[] memory bad = new Multicall[](1);
        bytes4 other = bytes4(keccak256("drain(address)"));
        bad[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(other, cea) });
        _agentRequest(
            agw,
            pid,
            outboundRequest(destAsset, 1, 1 ether, agw, bad),
            1,
            abi.encodeWithSelector(IURP.CallNotAllowed.selector, PROTOCOL, other)
        );
    }

    function _agentRequest(address agw, bytes32 pid, bytes memory request, uint64 seq, bytes memory urpErr) internal {
        bytes32 mode = ModeCode.unwrap(ModeLib.encodeSimpleSingle());
        bytes memory cd = ExecutionLib.encodeSingle(GATEWAY, 0, request);
        bytes32 opHash = keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
                block.chainid,
                agw,
                address(engine),
                pid,
                mode,
                keccak256(cd),
                uint192(0),
                seq,
                uint48(0)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, opHash);
        bytes memory sig = abi.encodePacked(uint8(SmartSessionMode.USE), pid, abi.encodePacked(r, s, v));
        if (urpErr.length != 0) expectUrpGate(urpErr);
        vm.prank(RELAYER);
        PushAgentWallet(payable(agw)).executeWithSession(address(engine), mode, cd, sig, 0, seq, 0);
    }

    /// @dev The load-bearing invariant, re-proven on the new wallet: with every mandate stopped and the
    ///      engine uninstalled, the plain owner door still moves funds out.
    function test_E2E_07_ownerCanStillUseExecute_afterAllChanges() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (, address agw,) = _start(p);
        PushAgentWallet w = PushAgentWallet(payable(agw));
        vm.startPrank(originAddr);
        uea.exec(agw, 0, abi.encodeCall(PushAgentWallet.stopAll, ()));
        uea.exec(agw, 0, abi.encodeCall(PushAgentWallet.uninstallModule, (1, address(engine), "")));
        uint256 before = pUSDC.balanceOf(address(uea));
        uea.exec(
            agw,
            0,
            abi.encodeCall(
                PushAgentWallet.execute,
                (
                    ModeCode.unwrap(ModeLib.encodeSimpleSingle()),
                    ExecutionLib.encodeSingle(
                        address(pUSDC), 0, abi.encodeCall(MockERC20.transfer, (address(uea), PRINCIPAL))
                    )
                )
            )
        );
        vm.stopPrank();
        assertFalse(w.isModuleInstalled(1, address(engine), ""));
        assertEq(pUSDC.balanceOf(address(uea)) - before, PRINCIPAL);
    }

    /// @dev D2: one Push-side signature for the whole start.
    function test_E2E_08_pushSideSignatureCount_isOne() public {
        uint256 before = intentSignatures;
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        _start(p);
        assertEq(intentSignatures - before, 1);
    }

    function test_E2E_09_intentReplay_afterSuccess_failsEverywhere() public {
        (IUniversalMarketplace.StartJobParams memory p,) = _freshUniversal();
        (, address agw,) = _start(p);
        OwnerIntent memory i = _agwIntent(p.intent);
        (, bytes memory cd) = mkt.buildCreateJobCalldata(p.cardId, p.expiredAt, p.principal);

        vm.startPrank(address(mkt));
        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.IndexMismatch.selector, uint96(1), uint96(0)));
        factory.deployWallet(i, p.sig, "");
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.IntentGrantNonceMismatch.selector, uint64(1), uint64(0))
        );
        PushAgentWallet(payable(agw)).grantMandateWithSig(abi.decode(abi.encode(p.session), (Session)), i, p.sig);
        vm.expectRevert(
            abi.encodeWithSelector(PushWalletErrors.InvalidNonce.selector, OWNER_LANE_FLAG, uint64(1), uint64(0))
        );
        PushAgentWallet(payable(agw)).executeWithSig(bytes32(0), cd, i, p.sig);
        vm.stopPrank();
    }

    function test_E2E_10_attackerExpectedCEA_refusedAtStartJob_notAtURP() public {
        (address agw, uint96 idx) = nextWallet(address(uea));
        address attacker = makeAddr("attackerDestAccount");
        IUniversalMarketplace.StartJobParams memory p =
            _params(universalCard, _uCardTerms(), _uSession(agw, attacker), idx);
        _phase1(agw);
        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalMarketplaceErrors.ExpectedCEAMismatch.selector, ceaFactory.computeCEA(agw), attacker
            )
        );
        mkt.startJob(p);
        assertEq(factory.walletCount(address(uea)), 0, "nothing deployed, nothing moved");
        assertEq(pUSDC.allowance(address(uea), address(mkt)), PRINCIPAL + FEE);
    }

    /// ⚠️ NEVER-DELETE. The intent is usable only inside the marketplace's atomic call.
    function test_E2E_11_frontRunnerCannotConsumeIntentOutsideMarketplace() public {
        (IUniversalMarketplace.StartJobParams memory p, address agw) = _freshUniversal();
        OwnerIntent memory i = _agwIntent(p.intent);
        Session memory s = abi.decode(abi.encode(p.session), (Session));
        (, bytes memory cd) = mkt.buildCreateJobCalldata(p.cardId, p.expiredAt, p.principal);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.ExecutorMismatch.selector, address(mkt), RELAYER));
        factory.deployWallet(i, p.sig, "frontrun");

        // the wallet doors, on a wallet the owner deployed directly
        vm.prank(address(uea));
        factory.deployWallet(i, "", "owner");
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ExecutorMismatch.selector, address(mkt), RELAYER));
        PushAgentWallet(payable(agw)).grantMandateWithSig(s, i, p.sig);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.ExecutorMismatch.selector, address(mkt), RELAYER));
        PushAgentWallet(payable(agw)).executeWithSig(bytes32(0), cd, i, p.sig);

        (uint256 jobId, address got,) = _start(p);
        assertEq(got, agw);
        assertEq(kernel.getJob(jobId).client, agw);
    }

    /// @dev Every core mirror of an AGW type encodes, hashes and selects identically to the real one.
    function test_E2E_12_mirrorTypes_encodeIdentically() public {
        (address agw, uint96 idx) = nextWallet(address(uea));
        Session memory real = _uSession(agw, ceaFactory.computeCEA(agw));
        CoreSession memory mirror = _mirror(real);
        assertEq(abi.encode(mirror), abi.encode(real), "Session");
        assertEq(keccak256(abi.encode(mirror)), keccak256(abi.encode(real)));

        CoreIntent memory ci =
            mkt.previewIntent(universalCard, address(uea), idx, _expiredAt(), PRINCIPAL, mirror, 1, 1);
        assertEq(abi.encode(ci), abi.encode(_agwIntent(ci)), "OwnerIntent");
        assertEq(CORE_OWNER_LANE_FLAG, OWNER_LANE_FLAG);

        (, bytes memory body) = abi.decode(real.actions[0].actionPolicies[0].initData, (string, bytes));
        assertEq(
            abi.encode(abi.decode(body, (CoreUniversalTerms))), abi.encode(abi.decode(body, (IURP.UniversalTerms)))
        );
        Session memory ns = _nSession(agw);
        (, bytes memory nbody) = abi.decode(ns.actions[0].actionPolicies[0].initData, (string, bytes));
        assertEq(abi.encode(abi.decode(nbody, (CoreNativeTerms))), abi.encode(abi.decode(nbody, (IURP.NativeTerms))));

        assertEq(CoreWalletMirror.grantMandateWithSig.selector, PushAgentWallet.grantMandateWithSig.selector);
        assertEq(CoreWalletMirror.executeWithSig.selector, PushAgentWallet.executeWithSig.selector);
        assertEq(CoreWalletMirror.getNonce.selector, PushAgentWallet.getNonce.selector);
        assertEq(CoreWalletMirror.grantNonce.selector, PushAgentWallet.grantNonce.selector);
        assertEq(
            CoreFactoryMirror.deployWallet.selector,
            bytes4(
                keccak256(
                    "deployWallet((address,address,address,uint96,bytes32,bytes32,bytes32,uint192,uint64,uint64,uint48,uint256),bytes,string)"
                )
            )
        );
        assertEq(CoreFactoryMirror.predictWallet.selector, IAGWFactory.predictWallet.selector);
        assertEq(CoreFactoryMirror.walletCount.selector, IAGWFactory.walletCount.selector);
        assertEq(CoreFactoryMirror.ownerOf.selector, IAGWFactory.ownerOf.selector);
        assertEq(CoreFactoryMirror.isWallet.selector, IAGWFactory.isWallet.selector);

        (bytes32 mode, bytes memory cd) = mkt.buildCreateJobCalldata(universalCard, _expiredAt(), PRINCIPAL);
        assertEq(mode, ModeCode.unwrap(ModeLib.encodeSimpleSingle()), "MODE_SINGLE");
        bytes memory call = new bytes(cd.length - 52);
        for (uint256 k; k < call.length; ++k) {
            call[k] = cd[52 + k];
        }
        assertEq(cd, ExecutionLib.encodeSingle(address(kernel), 0, call), "encodeSingle");
        assertEq(
            OWNER_INTENT_TYPEHASH,
            keccak256(
                "OwnerIntent(address owner,address wallet,address executor,uint96 index,bytes32 sessionHash,bytes32 mode,bytes32 execCalldataHash,uint192 nonceKey,uint64 nonceSeq,uint64 grantNonce,uint48 deadline,uint256 signerChainId)"
            )
        );
    }

    /**
     * @dev The core artifacts this suite deploys are FRESH and built with the SHIPPING toolchain.
     *
     *      Comparing the deployed code with the artifact it was deployed from proves nothing — it cannot
     *      fail. What can go wrong is a stale artifact: core's source edited, core not rebuilt, and every
     *      E2E test passing against old bytecode. So, per contract: the source hash solc recorded in the
     *      artifact's metadata must equal the hash of the source on disk now, and the metadata must say
     *      solc 0.8.26, shanghai, optimizer 99 999 runs. The deployed runtime must fit EIP-170.
     */
    function test_E2E_13_coreArtifacts_areFresh_andBuiltWithShippingToolchain() public view {
        _assertFreshShipping("UniversalMarketplace", "src/agentic-commerce-8183/UniversalMarketplace.sol");
        _assertFreshShipping("UniversalMarketplaceTerms", "src/agentic-commerce-8183/UniversalMarketplaceTerms.sol");
        _assertFreshShipping("AgenticCommerce", "src/agentic-commerce-8183/AgenticCommerce.sol");
        _assertFreshShipping("MandateBindingHook", "src/agentic-commerce-8183/hooks/MandateBindingHook.sol");
        _assertFreshShipping("CEAFactory", "src/cea/CEAFactory.sol");
        assertLe(mktImpl.code.length, 24_576, "marketplace exceeds EIP-170");
        assertLe(IMarketplaceAdmin(address(mkt)).terms().code.length, 24_576, "terms exceeds EIP-170");
    }

    /// @dev Every core `src/` file solc compiled into this artifact — the contract, its interfaces, its
    ///      bases — must hash to the file on disk now. An edited interface changes the bytecode without
    ///      touching the top-level source, so checking only the top-level file would pass a stale artifact.
    ///      Files under core's `lib/` (OZ, pinned by core's own submodules) are not re-read.
    function _assertFreshShipping(string memory name, string memory sourcePath) internal view {
        string memory json = vm.readFile(_artifact(name));
        string[] memory sources = vm.parseJsonKeys(json, ".metadata.sources");
        bool sawSelf;
        uint256 checked;
        for (uint256 i; i < sources.length; ++i) {
            if (!_startsWith(sources[i], "src/")) continue;
            bytes32 recorded =
                vm.parseJsonBytes32(json, string.concat(".metadata.sources['", sources[i], "'].keccak256"));
            bytes32 onDisk = keccak256(bytes(vm.readFile(string.concat("lib/push-chain-core-contracts/", sources[i]))));
            assertEq(recorded, onDisk, string.concat(name, ": STALE (", sources[i], ") - run make e2e"));
            if (keccak256(bytes(sources[i])) == keccak256(bytes(sourcePath))) sawSelf = true;
            ++checked;
        }
        assertTrue(sawSelf, string.concat(name, ": artifact does not compile ", sourcePath));
        assertGt(checked, 1, string.concat(name, ": expected the contract and its src/ dependencies"));
        assertEq(vm.parseJsonString(json, ".metadata.settings.evmVersion"), "shanghai", name);
        assertEq(vm.parseJsonUint(json, ".metadata.settings.optimizer.runs"), 99_999, name);
        assertEq(vm.parseJsonString(json, ".metadata.compiler.version"), "0.8.26+commit.8a97fa7a", name);
    }

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(str);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}

/// @dev The marketplace's public mapping getter, which IUniversalMarketplace does not declare.
interface IMarketplaceView {
    function mandateOfJob(uint256 jobId) external view returns (bytes32);
}
