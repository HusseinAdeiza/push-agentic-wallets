// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";

import { AGW } from "../../src/AGW.sol";

import { AGWErrors } from "../../src/libraries/Errors.sol";

import { UniversalRulesPolicy } from "../../src/policies/UniversalRulesPolicy.sol";

import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";

import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

import {
    AmountRule,
    ArgPin,
    ENGINE_FALLBACK_TARGET,
    NativeConfig,
    RulesType,
    VALUE_SELECTOR
} from "../../src/libraries/Types.sol";

import { StakeDummy } from "../mocks/StakeDummy.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

import { SudoPolicy } from "smartsessions/external/policies/SudoPolicy.sol";

import { ISmartSession } from "smartsessions/ISmartSession.sol";

import {
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context,
    PermissionId,
    SmartSessionMode
} from "smartsessions/DataTypes.sol";

import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

/**
 * @title  AGW — the NATIVE agent door, end to end.
 * @notice The §7.1 mandate driven against a real `StakeDummy`: stake, unstake, claim, the payable
 *         value path, the true value-only path, then the gauntlet.
 *
 * @dev    Includes the seven never-delete tests of §8.1. Nothing here is stubbed on the URP side —
 *         the real engine validates, the real policy gates, and the real wallet dispatches.
 */
contract PushAgentWalletNativeDoorTest is BaseTest {
    AGW internal wallet;
    address internal WALLET_OWNER;

    StakeDummy internal stakeDummy;
    MockERC20 internal token;

    address internal agentAddr;
    uint256 internal agentPk;

    bytes32 internal permissionId;

    bytes4 internal constant STAKE_FOR = StakeDummy.stakeFor.selector;
    bytes4 internal constant DEPOSIT_FOR = StakeDummy.depositFor.selector;
    bytes4 internal constant UNSTAKE = StakeDummy.unstake.selector;
    bytes4 internal constant CLAIM = StakeDummy.claim.selector;

    uint16 internal constant BENEFICIARY_OFFSET = 4;
    uint16 internal constant AMOUNT_OFFSET = 36;

    function setUp() public override {
        super.setUp();
        WALLET_OWNER = makeAddr("walletOwner");
        wallet = newWallet(WALLET_OWNER);
        vm.deal(address(wallet), 100 ether);

        (agentAddr, agentPk) = makeAddrAndKey("nativeAgent");

        token = new MockERC20();
        stakeDummy = new StakeDummy(token);

        token.mint(address(wallet), 1_000e6);

        // The wallet approves the protocol through the OWNER door — approvals are the owner's job,
        // not the agent's, unless the mandate explicitly grants a pinned `approve`.
        vm.prank(WALLET_OWNER);
        wallet.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(
                address(token), 0, abi.encodeCall(MockERC20.approve, (address(stakeDummy), type(uint256).max))
            )
        );
    }

    // ───────────────────────────── the §7.1 mandate ─────────────────────────────

    function _pin(address who) internal pure returns (ArgPin[] memory p) {
        p = new ArgPin[](1);
        p[0] = ArgPin({ offset: BENEFICIARY_OFFSET, expected: bytes32(uint256(uint160(who))) });
    }

    function _noPins() internal pure returns (ArgPin[] memory) {
        return new ArgPin[](0);
    }

    function _noAmount() internal pure returns (AmountRule memory) {
        return AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });
    }

    /// @dev Action 1 — `stakeFor`: beneficiary pinned to the wallet, amount metered 50e6/60e6.
    function _stakeConfig() internal view returns (NativeConfig memory c) {
        c = NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: address(stakeDummy),
            selector: STAKE_FOR,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: true, offset: AMOUNT_OFFSET, maxPerCall: 50e6, maxTotal: 60e6 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: _pin(address(wallet))
        });
    }

    /// @dev Action 2 — `unstake()`: a NORMAL selector action, capped at two calls.
    function _unstakeConfig() internal view returns (NativeConfig memory c) {
        c = _stakeConfig();
        c.selector = UNSTAKE;
        c.amount = _noAmount();
        c.maxCalls = 2;
        c.pins = _noPins();
    }

    /// @dev Action 3 — `claim()`: the ascetic Q15 shape.
    function _claimConfig() internal view returns (NativeConfig memory c) {
        c = _stakeConfig();
        c.selector = CLAIM;
        c.amount = _noAmount();
        c.maxCalls = 0;
        c.pins = _noPins();
    }

    /// @dev Action 4 — `depositFor` payable: pin plus native value caps.
    function _depositConfig() internal view returns (NativeConfig memory c) {
        c = _stakeConfig();
        c.selector = DEPOSIT_FOR;
        c.amount = _noAmount();
        c.maxValuePerCall = 5 ether;
        c.maxValueTotal = 20 ether;
    }

    /// @dev Action 5 — the TRUE value-only shape: empty calldata, no pins, no amount rule.
    function _valueOnlyConfig() internal view returns (NativeConfig memory c) {
        c = _stakeConfig();
        c.selector = VALUE_SELECTOR;
        c.amount = _noAmount();
        c.pins = _noPins();
        c.maxValuePerCall = 5 ether;
        c.maxValueTotal = 20 ether;
    }

    /// @dev A fresh `approve` config each call — see the aliasing note in the approve test.
    function _approveConfig() internal view returns (NativeConfig memory c) {
        c = _stakeConfig();
        c.target = address(token);
        c.selector = MockERC20.approve.selector;
        c.amount = AmountRule({ enabled: true, offset: AMOUNT_OFFSET, maxPerCall: 100e6, maxTotal: 100e6 });
    }

    function _action(bytes4 selector, NativeConfig memory cfg) internal view returns (ActionData memory) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(cfg) });
        return ActionData({ actionTargetSelector: selector, actionTarget: address(stakeDummy), actionPolicies: ps });
    }

    function _nativeSession(ActionData[] memory actions) internal view returns (Session memory) {
        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: ecdsaConfig(agentAddr),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    /// @dev The full §7.1 mandate: five actions, one permission id.
    function _grantFullMandate() internal returns (bytes32) {
        ActionData[] memory a = new ActionData[](5);
        a[0] = _action(STAKE_FOR, _stakeConfig());
        a[1] = _action(UNSTAKE, _unstakeConfig());
        a[2] = _action(CLAIM, _claimConfig());
        a[3] = _action(DEPOSIT_FOR, _depositConfig());
        a[4] = _action(VALUE_SELECTOR, _valueOnlyConfig());

        vm.prank(WALLET_OWNER);
        return wallet.grantRules(_nativeSession(a));
    }

    // ───────────────────────────── request plumbing ─────────────────────────────

    function _singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    function _opHash(bytes memory execCd, uint192 key, uint64 seq, bytes32 pid) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("AGW.Op.v3"),
                block.chainid,
                address(wallet),
                address(engine),
                pid,
                _singleMode(),
                keccak256(execCd),
                key,
                seq,
                uint48(0)
            )
        );
    }

    function _sign(bytes memory execCd, uint192 key, uint64 seq, bytes32 pid) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, _opHash(execCd, key, seq, pid));
        return abi.encodePacked(uint8(SmartSessionMode.USE), pid, abi.encodePacked(r, s, v));
    }

    function _submit(bytes memory execCd, uint192 key, uint64 seq, bytes32 pid) internal {
        vm.prank(RELAYER);
        wallet.executeWithSession(address(engine), _singleMode(), execCd, _sign(execCd, key, seq, pid), key, seq, 0);
    }

    function _stakeCd(address beneficiary, uint256 amount) internal view returns (bytes memory) {
        return
            ExecutionLib.encodeSingle(
                address(stakeDummy), 0, abi.encodeCall(StakeDummy.stakeFor, (beneficiary, amount))
            );
    }

    // ═════════════════════════════ the happy path ═════════════════════════════

    /// stake -> unstake -> claim -> depositFor -> bare value transfer, all under ONE mandate.
    function test_native_endToEnd_allFiveActions() public {
        permissionId = _grantFullMandate();
        uint192 lane;

        // 1. stake, beneficiary pinned to the wallet
        _submit(_stakeCd(address(wallet), 40e6), lane, 0, permissionId);
        assertEq(stakeDummy.totalBalance(address(wallet)), 40e6, "staked");

        // 2. unstake — four bytes of selector, no arguments
        _submit(
            ExecutionLib.encodeSingle(address(stakeDummy), 0, abi.encodeCall(StakeDummy.unstake, ())),
            lane,
            1,
            permissionId
        );
        assertEq(stakeDummy.totalBalance(address(wallet)), 0, "unstaked");

        // 3. claim — the ascetic shape
        _submit(
            ExecutionLib.encodeSingle(address(stakeDummy), 0, abi.encodeCall(StakeDummy.claim, ())),
            lane,
            2,
            permissionId
        );

        // 4. depositFor — pin AND native value
        _submit(
            ExecutionLib.encodeSingle(
                address(stakeDummy), 3 ether, abi.encodeCall(StakeDummy.depositFor, (address(wallet)))
            ),
            lane,
            3,
            permissionId
        );
        assertEq(stakeDummy.pcBalance(address(wallet)), 3 ether, "deposited");

        // 5. THE TRUE VALUE-ONLY PATH — empty calldata, so the engine derives VALUE_SELECTOR.
        _submit(ExecutionLib.encodeSingle(address(stakeDummy), 2 ether, ""), lane, 4, permissionId);
        assertEq(stakeDummy.pcBalance(address(wallet)), 3 ether + 2 ether, "bare value transfer landed");
    }

    // ═════════════════════════════ the gauntlet ═════════════════════════════

    /// The pin is what stops the agent staking to itself.
    function test_native_gauntlet_argPinMismatch() public {
        permissionId = _grantFullMandate();
        bytes memory cd = _stakeCd(agentAddr, 10e6);

        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(agentAddr))),
                uint256(0),
                bytes32(uint256(uint160(address(wallet))))
            )
        );
        _submit(cd, 0, 0, permissionId);
    }

    function test_native_gauntlet_amountExceedsPerCallCap() public {
        permissionId = _grantFullMandate();
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.NativeAmountExceedsCap.selector, uint256(51e6), uint256(50e6)
            )
        );
        _submit(_stakeCd(address(wallet), 51e6), 0, 0, permissionId);
    }

    function test_native_gauntlet_lifetimeAmountCap() public {
        permissionId = _grantFullMandate();
        _submit(_stakeCd(address(wallet), 40e6), 0, 0, permissionId);

        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.TotalNativeAmountExceeded.selector, uint256(80e6), uint256(60e6)
            )
        );
        _submit(_stakeCd(address(wallet), 40e6), 0, 1, permissionId);
    }

    function test_native_gauntlet_valueExceedsCap() public {
        permissionId = _grantFullMandate();
        bytes memory cd = ExecutionLib.encodeSingle(
            address(stakeDummy), 6 ether, abi.encodeCall(StakeDummy.depositFor, (address(wallet)))
        );
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)
            )
        );
        _submit(cd, 0, 0, permissionId);
    }

    function test_native_gauntlet_callLimitReached() public {
        permissionId = _grantFullMandate();
        _submit(_stakeCd(address(wallet), 10e6), 0, 0, permissionId);

        bytes memory unstakeCd =
            ExecutionLib.encodeSingle(address(stakeDummy), 0, abi.encodeCall(StakeDummy.unstake, ()));
        _submit(unstakeCd, 0, 1, permissionId);

        // maxCalls == 2 on unstake; the second consumed it, and StakeDummy would revert anyway, so
        // stake again first to keep the failure attributable to the POLICY.
        _submit(_stakeCd(address(wallet), 10e6), 0, 2, permissionId);
        _submit(unstakeCd, 0, 3, permissionId);

        _submit(_stakeCd(address(wallet), 10e6), 0, 4, permissionId);
        expectUrpGate(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CallLimitReached.selector, uint32(2), uint32(2))
        );
        _submit(unstakeCd, 0, 5, permissionId);
    }

    /// A replayed signature dies at the wallet's nonce gate, before the policy ever runs.
    function test_native_gauntlet_replayDiesAtNonce() public {
        permissionId = _grantFullMandate();
        bytes memory cd = _stakeCd(address(wallet), 10e6);
        bytes memory sig = _sign(cd, 0, 0, permissionId);

        vm.prank(RELAYER);
        wallet.executeWithSession(address(engine), _singleMode(), cd, sig, 0, 0, 0);

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.InvalidNonce.selector, uint192(0), uint64(1), uint64(0)));
        wallet.executeWithSession(address(engine), _singleMode(), cd, sig, 0, 0, 0);
    }

    // ═══════════════════ the SDK obligation, made concrete ═══════════════════

    /**
     * A PINNED `approve` is safe; an UNPINNED one is the same hole it always was.
     *
     * The contract cannot tell them apart — both are legal native configs — so this test exists to
     * show that the difference is real and that refusing the unpinned form is an SDK obligation, not
     * a contract guard. It asserts BOTH directions: the pinned config refuses a wrong spender, and
     * the unpinned one waves it through.
     */
    function test_native_pinnedApproveIsSafe_unpinnedIsNot() public {
        address attacker = makeAddr("attacker");
        bytes memory evil =
            ExecutionLib.encodeSingle(address(token), 0, abi.encodeCall(MockERC20.approve, (attacker, 100e6)));

        _pinnedApproveRefuses(attacker, evil);
        _unpinnedApprovePasses(attacker, evil);
    }

    /// @dev Half one: the PINNED mandate refuses an approve to anyone but the pinned spender.
    ///      Split out so neither half carries enough locals to stack-too-deep with the optimizer
    ///      off, which is the configuration `forge coverage` uses.
    function _pinnedApproveRefuses(address attacker, bytes memory evil) internal {
        // BUILT FRESH, NOT COPIED. `NativeConfig memory b = a` aliases the same memory struct, so
        // mutating `b.pins` would also clear `a.pins` and the "pinned" half of this test would
        // silently become a second unpinned one — a test that cannot fail.
        NativeConfig memory pinned = _approveConfig();
        pinned.pins = _pin(address(stakeDummy)); // spender pinned

        bytes32 pid = _grantApprove(wallet, pinned);

        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ArgPinMismatch.selector,
                bytes32(uint256(uint160(attacker))),
                uint256(0),
                bytes32(uint256(uint160(address(stakeDummy))))
            )
        );
        _submit(evil, 0, 0, pid);
    }

    /// @dev Half two: the UNPINNED mandate lets exactly the same call through. This is the SDK
    ///      obligation made concrete — the contract cannot tell the two configs apart.
    function _unpinnedApprovePasses(address attacker, bytes memory evil) internal {
        AGW w2 = newWallet(WALLET_OWNER);
        vm.deal(address(w2), 10 ether);

        NativeConfig memory unpinned = _approveConfig();
        unpinned.pins = _noPins(); // <-- the hole

        bytes32 pid = _grantApprove(w2, unpinned);

        vm.prank(RELAYER);
        w2.executeWithSession(address(engine), _singleMode(), evil, _signFor(w2, evil, 0, 0, pid), 0, 0, 0);

        assertEq(
            token.allowance(address(w2), attacker),
            100e6,
            "AN UNPINNED APPROVE PASSES. This is the SDK's obligation to refuse, not the contract's."
        );
    }

    /// @dev Grant a one-action `approve` mandate on `w` with the given config.
    function _grantApprove(AGW w, NativeConfig memory cfg) internal returns (bytes32) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(cfg) });

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({
            actionTargetSelector: MockERC20.approve.selector, actionTarget: address(token), actionPolicies: ps
        });

        vm.prank(WALLET_OWNER);
        return w.grantRules(_nativeSession(a));
    }

    /// @dev The ten-field op hash and USE-mode envelope for an ARBITRARY wallet, so the second half
    ///      above can sign against `w2` rather than the suite's default wallet.
    function _signFor(AGW w, bytes memory ecd, uint192 key, uint64 seq, bytes32 pid)
        internal
        view
        returns (bytes memory)
    {
        bytes32 h = keccak256(
            abi.encode(
                keccak256("AGW.Op.v3"),
                block.chainid,
                address(w),
                address(engine),
                pid,
                _singleMode(),
                keccak256(ecd),
                key,
                seq,
                uint48(0)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, h);
        return abi.encodePacked(uint8(SmartSessionMode.USE), pid, abi.encodePacked(r, s, v));
    }

    // ══════════════════════════ never-delete tests ══════════════════════════

    /// ⚠️ NEVER-DELETE. A native action naming the wallet is refused at GRANT time.
    function test_GrantRefusesSelfTarget() public {
        NativeConfig memory c = _claimConfig();
        c.target = address(wallet);

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({
            actionTargetSelector: AGW.grantRules.selector, actionTarget: address(wallet), actionPolicies: ps
        });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenActionTarget.selector, address(wallet)));
        wallet.grantRules(_nativeSession(a));
    }

    /**
     * ⚠️ NEVER-DELETE. THE THREE-LAYER SELF-TARGET TEST.
     *
     * (1) `grantRules` refuses the wallet as a target — the honest path is closed.
     * (2) The owner door can bypass that entirely by calling `enableSessions` on the engine
     *     directly, with a permissive `SudoPolicy`. That path is legitimate and exists today.
     * (3) The engine validates the request and PASSES — Sudo permits everything.
     * (4) `_gateAndDispatch`'s guard catches it anyway.
     *
     * Remove the guard and step (4) becomes `_execute(wallet, 0, grantRules(...))` arriving with
     * `msg.sender == address(this)`, passing `onlyOwnerOrSelf` — the agent granting itself a mandate
     * of its own design.
     */
    function test_DispatchRefusesSelfTarget() public {
        // (1) the honest path is closed
        test_GrantRefusesSelfTarget();

        // (2) bypass it through the owner door with SudoPolicy
        SudoPolicy sudo = new SudoPolicy();
        bytes32 pid = _ownerDoorEnable(address(wallet), AGW.grantRules.selector, address(sudo));

        // (3)+(4) the engine passes; the wallet's guard fires
        bytes memory cd = ExecutionLib.encodeSingle(
            address(wallet), 0, abi.encodeCall(AGW.grantRules, (_nativeSession(new ActionData[](1))))
        );

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenDispatchTarget.selector, address(wallet)));
        wallet.executeWithSession(address(engine), _singleMode(), cd, _sign(cd, 0, 0, pid), 0, 0, 0);
    }

    /**
     * ⚠️ NEVER-DELETE. THE ENGINE-TARGET TEST, reached through the engine's OWN sentinel.
     *
     * Naming the engine directly is impossible — `ConfigLib.sol:139-143` refuses `address(this)` at
     * enable time — and a request targeting the engine with no sentinel policy dies inside
     * `_validate` at `PolicyLib.sol:207`, before the guard runs. So the only way to reach the guard
     * is the fallback sentinel: action `(address(1), 0x00000002)`, which the engine does NOT refuse
     * at enable and which routes any engine-targeted request to `FALLBACK_ACTIONID_SMARTSESSION_CALL`.
     *
     * Remove the guard and the wallet calls its own engine with agent-controlled calldata, under a
     * fallback the owner enabled by mistake.
     */
    function test_DispatchRefusesEngineTarget() public {
        // (1) grantRules refuses the sentinel by name
        NativeConfig memory c = _claimConfig();
        c.target = ENGINE_FALLBACK_TARGET;

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({
            actionTargetSelector: bytes4(0x00000002), actionTarget: ENGINE_FALLBACK_TARGET, actionPolicies: ps
        });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenActionTarget.selector, ENGINE_FALLBACK_TARGET));
        wallet.grantRules(_nativeSession(a));

        // (2) the owner door enables it anyway, with Sudo
        SudoPolicy sudo = new SudoPolicy();
        bytes32 pid = _ownerDoorEnable(ENGINE_FALLBACK_TARGET, bytes4(0x00000002), address(sudo));

        // (3)+(4) the engine routes to the sentinel, finds Sudo, passes; the guard fires
        bytes memory cd = ExecutionLib.encodeSingle(
            address(engine), 0, abi.encodeCall(ISmartSession.isInitialized, (address(wallet)))
        );

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenDispatchTarget.selector, address(engine)));
        wallet.executeWithSession(address(engine), _singleMode(), cd, _sign(cd, 0, 0, pid), 0, 0, 0);
    }

    /// ⚠️ NEVER-DELETE. A gateway action declared NATIVE is refused, naming the index and target.
    function test_GatewayTargetRefusedAsNative() public {
        NativeConfig memory c = _claimConfig();

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](2);
        a[0] = _action(CLAIM, _claimConfig());
        a[1] = ActionData({ actionTargetSelector: SEND_OUTBOUND_SELECTOR, actionTarget: GATEWAY, actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(AGWErrors.RulesTypeMismatch.selector, RulesType.NATIVE, uint256(1), GATEWAY)
        );
        wallet.grantRules(_nativeSession(a));
    }

    /**
     * ⚠️ NEVER-DELETE. And the mirror: a non-gateway action under a FOREIGN chain.
     *
     * The property is unchanged — "a universal mandate can never contain a non-gateway action" — but
     * since the mode became derived there is no argument to force it with. The chain does that work
     * now: a Sepolia envelope on a Push-side target derives UNIVERSAL, and the target check refuses
     * it. That is a strictly better test, because it is the shape an SDK would actually produce by
     * mistake, rather than one only reachable by passing the wrong enum.
     */
    function test_NonGatewayTargetRefusedAsUniversal() public {
        // A Push-side target, but the envelope declares Sepolia -> derives UNIVERSAL.
        //
        // The BODY is still a native config, and that is deliberate: the wallet reads the chain and
        // nothing else, so an inconsistent body must not change its answer. URP would reject this
        // body at init — but the wallet refuses the session first, which is the ordering under test.
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] =
            PolicyData({ policy: address(urp), initData: envelope(CHAIN_SEPOLIA, abi.encode(_terms(_claimConfig()))) });

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: CLAIM, actionTarget: address(stakeDummy), actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AGWErrors.RulesTypeMismatch.selector, RulesType.UNIVERSAL, uint256(0), address(stakeDummy)
            )
        );
        wallet.grantRules(_nativeSession(a));
    }

    /// ⚠️ NEVER-DELETE. The engine's wildcard action, refused by target AND by selector.
    function test_GrantRefusesFallbackAction() public {
        // (address(1), 0x00000001) -> the TARGET is refused first
        NativeConfig memory c = _claimConfig();
        c.target = ENGINE_FALLBACK_TARGET;

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({
            actionTargetSelector: bytes4(0x00000001), actionTarget: ENGINE_FALLBACK_TARGET, actionPolicies: ps
        });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenActionTarget.selector, ENGINE_FALLBACK_TARGET));
        wallet.grantRules(_nativeSession(a));

        // A legitimate target with a fallback SELECTOR is refused on the selector.
        _expectForbiddenSelector(bytes4(0x00000001));
        _expectForbiddenSelector(bytes4(0x00000002));
    }

    function _expectForbiddenSelector(bytes4 sel) internal {
        NativeConfig memory c = _claimConfig();
        c.selector = sel;

        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: sel, actionTarget: address(stakeDummy), actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.ForbiddenActionSelector.selector, sel));
        wallet.grantRules(_nativeSession(a));
    }

    /**
     * ⚠️ NEVER-DELETE. W-29's native counterpart: the self-target defence holds with EIGHT actions.
     *
     * Layer (c) of the four-layer argument — the engine's `NoPoliciesSet`, because the wallet is
     * never a configured action — is the one that could in principle weaken as the action count
     * grows. It does not: layer (a) guarantees the wallet is never grantable, however many actions a
     * mandate holds. Asserted here against a maximal-width native mandate.
     */
    function test_W29_Native_SelfTargetRefusedWithEightActions() public {
        ActionData[] memory a = new ActionData[](8);
        for (uint256 i; i < 8; ++i) {
            NativeConfig memory c = _claimConfig();
            c.selector = bytes4(uint32(0x22000000 + i));
            PolicyData[] memory ps = new PolicyData[](1);
            ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(c) });
            a[i] =
                ActionData({ actionTargetSelector: c.selector, actionTarget: address(stakeDummy), actionPolicies: ps });
        }

        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantRules(_nativeSession(a));

        // Eight actions configured, and NONE of them is the wallet — so a self-targeted request
        // finds no matching action and the engine refuses it before the guard is even needed.
        bytes memory cd = ExecutionLib.encodeSingle(address(wallet), 0, abi.encodeCall(AGW.revokeAllRules, ()));

        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.NoPoliciesSet.selector, PermissionId.wrap(pid)));
        wallet.executeWithSession(address(engine), _singleMode(), cd, _sign(cd, 0, 0, pid), 0, 0, 0);
    }

    // ───────────────────── the owner-door bypass helper ─────────────────────

    /**
     * @dev Enable a session on the engine DIRECTLY through the owner door, bypassing `grantRules`
     *      and its forbidden-target list entirely.
     *
     *      This path is legitimate and exists today: the owner can call anything, including the
     *      engine. It is precisely what the dispatch guard is the last defence against, so the
     *      never-delete tests must be able to reach it.
     */
    function _ownerDoorEnable(address target, bytes4 selector, address policy) internal returns (bytes32) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: policy, initData: "" });

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: ps });

        Session[] memory sessions = new Session[](1);
        sessions[0] = _nativeSession(a);
        sessions[0].salt = keccak256(abi.encodePacked("ownerDoorBypass", target, selector));

        vm.prank(WALLET_OWNER);
        wallet.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(address(engine), 0, abi.encodeCall(ISmartSession.enableSessions, (sessions)))
        );

        return PermissionId.unwrap(_permissionIdOf(sessions[0]));
    }

    function _permissionIdOf(Session memory s) internal pure returns (PermissionId) {
        return PermissionId.wrap(keccak256(abi.encode(s.sessionValidator, s.sessionValidatorInitData, s.salt)));
    }
}
