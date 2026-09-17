// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { MandateType, SEND_OUTBOUND_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

import { StakeDummy } from "../mocks/StakeDummy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockPRC20Source } from "../mocks/MockPRC20Source.sol";

import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context, ConfigId } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

/**
 * @title  PushAgentWallet — the mode is DERIVED from the chain, by nobody.
 *
 * @notice The change this suite exists for: `grantMandate` takes one argument. No owner, SDK, script
 *         or test states whether a mandate is universal or native. Each action's policy envelope
 *         carries a CAIP-2 chain string, the wallet derives the mode from it, and URP independently
 *         derives the same mode from the same bytes.
 *
 *         WHAT THAT BUYS, and why it is not merely tidier: before this, the mode was supplied TWICE
 *         — once as a `grantMandate` argument, once as a byte inside `initData` — and nothing
 *         compared them at grant. A disagreement produced a mandate that looked granted, emitted an
 *         event describing itself wrongly, and died at first use. There is now no second author to
 *         disagree with.
 *
 * @dev    ORDERING IS THE SUBJECT OF SEVERAL OF THESE TESTS, not an incidental detail. The wallet
 *         must prove a policy is URP's before it decodes that policy's data, and must count actions
 *         before it reads action zero. Both are asserted directly, because both are the kind of
 *         thing a later refactor reorders without noticing.
 */
contract PushAgentWalletChainDerivationTest is BaseTest {
    PushAgentWallet internal wallet;
    address internal WALLET_OWNER;

    StakeDummy internal stakeDummy;
    MockERC20 internal token;
    address internal PRC20;

    address internal CEA;
    address internal PROTOCOL;

    bytes4 internal constant STAKE = bytes4(keccak256("stake(uint256)"));
    bytes4 internal constant SWAP = bytes4(keccak256("swap(address,uint256)"));

    function setUp() public override {
        super.setUp();
        WALLET_OWNER = makeAddr("walletOwner");
        wallet = newWallet(WALLET_OWNER);
        token = new MockERC20();
        stakeDummy = new StakeDummy(token);
        PRC20 = address(new MockPRC20Source(CHAIN_SEPOLIA));
        CEA = makeAddr("cea");
        PROTOCOL = makeAddr("protocol");
    }

    // ───────────────────────────────── builders ─────────────────────────────────

    function _nativeCfg(address target, bytes4 selector) internal view returns (IURP.NativeConfig memory c) {
        c.validUntil = uint48(block.timestamp + 30 days);
        c.target = target;
        c.selector = selector;
        c.maxValuePerCall = 1 ether;
        c.maxValueTotal = 10 ether;
        c.maxCalls = 100;
    }

    function _universalCfg() internal view returns (IURP.Config memory cfg) {
        IURP.AllowedCall[] memory calls = new IURP.AllowedCall[](1);
        calls[0] = IURP.AllowedCall({
            target: PROTOCOL, selector: SWAP, beneficiaryOffset: 4, hasBeneficiary: true, maxValue: 0
        });
        cfg.validUntil = uint48(block.timestamp + 30 days);
        cfg.expectedCEA = CEA;
        cfg.asset = PRC20;
        cfg.maxAmountPerCall = 100e6;
        cfg.maxAmountTotal = 1000e6;
        cfg.maxPCPerCall = 5 ether;
        cfg.allowedCalls = calls;
    }

    /// @dev An action carrying an explicitly-chosen chain — the point of control for this suite.
    function _actionOn(string memory chain, address target, bytes4 selector, bytes memory body)
        internal
        view
        returns (ActionData memory)
    {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: envelope(chain, body) });
        return ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: ps });
    }

    function _nativeAction(string memory chain, bytes4 selector) internal view returns (ActionData memory) {
        return _actionOn(
            chain, address(stakeDummy), selector, abi.encode(_terms(_nativeCfg(address(stakeDummy), selector)))
        );
    }

    function _universalAction(string memory chain) internal view returns (ActionData memory) {
        return _actionOn(chain, GATEWAY, SEND_OUTBOUND_SELECTOR, abi.encode(_terms(_universalCfg())));
    }

    function _session(ActionData[] memory actions) internal view returns (Session memory) {
        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: ecdsaConfig(AGENT),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    function _one(ActionData memory a) internal pure returns (ActionData[] memory out) {
        out = new ActionData[](1);
        out[0] = a;
    }

    // ═══════════════ the wallet and URP agree, without agreeing by construction ═══════════════

    /**
     * THE CENTRAL PROPERTY. Two contracts derive one mode from one envelope and reach the same
     * answer — for both kinds of mandate.
     *
     * The event is read from logs rather than `expectEmit` so the DERIVED values can be compared
     * against what URP independently recorded. If either side ever stopped deriving and started
     * trusting the other, one of these four assertions would break.
     */
    function test_Grant_walletAndUrpAgreeOnMode_native() public {
        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantMandate(_session(_one(_nativeAction(nativeChain(), STAKE))));

        (MandateType evMode, bytes32 evChain, string memory evChainStr) = _readGrantEvent(vm.getRecordedLogs(), pid);
        assertEq(uint8(evMode), uint8(MandateType.NATIVE), "wallet derived NATIVE");
        assertEq(evChain, keccak256(bytes(nativeChain())), "and recorded this chain");
        assertEq(evChainStr, nativeChain(), "and carried the string for humans");

        IURP.ModeSlot memory slot = urp.getMode(_configId(pid, address(stakeDummy), STAKE), address(wallet));
        assertTrue(slot.initialized, "URP wrote a config");
        assertEq(uint8(slot.mode), uint8(evMode), "URP derived the SAME mode, independently");
        assertEq(slot.chainHash, evChain, "and the same chain");
    }

    function test_Grant_walletAndUrpAgreeOnMode_universal() public {
        vm.recordLogs();
        vm.prank(WALLET_OWNER);
        bytes32 pid = wallet.grantMandate(_session(_one(_universalAction(CHAIN_SEPOLIA))));

        (MandateType evMode, bytes32 evChain,) = _readGrantEvent(vm.getRecordedLogs(), pid);
        assertEq(uint8(evMode), uint8(MandateType.UNIVERSAL), "wallet derived UNIVERSAL");
        assertEq(evChain, keccak256(bytes(CHAIN_SEPOLIA)), "Sepolia");

        IURP.ModeSlot memory slot = urp.getMode(_configId(pid, GATEWAY, SEND_OUTBOUND_SELECTOR), address(wallet));
        assertTrue(slot.initialized, "URP wrote a config");
        assertEq(uint8(slot.mode), uint8(evMode), "URP derived the SAME mode, independently");
        assertEq(slot.chainHash, evChain, "and the same chain");
    }

    // ═══════════════════════════ one mandate, one chain ═══════════════════════════

    /**
     * Every action must name the same chain. This is what makes a mixed mandate UNREPRESENTABLE
     * rather than merely forbidden — with one chain per mandate there is one mode per mandate, so
     * the old "mixed mandates are refused" rule becomes a consequence instead of a check.
     */
    function test_Grant_inconsistentChainRefused() public {
        ActionData[] memory a = new ActionData[](3);
        a[0] = _nativeAction(nativeChain(), STAKE);
        a[1] = _nativeAction(nativeChain(), bytes4(0x11111111));
        a[2] = _nativeAction(CHAIN_SEPOLIA, bytes4(0x22222222)); // the odd one out

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.InconsistentChain.selector, uint256(2)));
        wallet.grantMandate(_session(a));
    }

    /// The index is reported, because with up to eight actions "one of them was wrong" is not usable.
    function test_Grant_inconsistentChainNamesTheAction() public {
        ActionData[] memory a = new ActionData[](2);
        a[0] = _nativeAction(nativeChain(), STAKE);
        a[1] = _nativeAction("eip155:137", bytes4(0x11111111));

        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.InconsistentChain.selector, uint256(1)));
        wallet.grantMandate(_session(a));
    }

    // ════════════════════════════ the chain/target lock ════════════════════════════

    /// This chain + a gateway target is a contradiction: a gateway call is not a Push-side call.
    function test_Grant_pushChainOnGatewayTarget() public {
        ActionData memory a =
            _actionOn(nativeChain(), GATEWAY, SEND_OUTBOUND_SELECTOR, abi.encode(_terms(_universalCfg())));

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushWalletErrors.MandateTypeMismatch.selector, MandateType.NATIVE, uint256(0), GATEWAY
            )
        );
        wallet.grantMandate(_session(_one(a)));
    }

    /// And the mirror: a foreign chain on a Push-side target.
    function test_Grant_foreignChainOnNativeTarget() public {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushWalletErrors.MandateTypeMismatch.selector, MandateType.UNIVERSAL, uint256(0), address(stakeDummy)
            )
        );
        wallet.grantMandate(_session(_one(_nativeAction(CHAIN_SEPOLIA, STAKE))));
    }

    /**
     * A near-miss Push string derives UNIVERSAL and is refused — with a TYPE error, not a chain one.
     *
     * The diagnostic points at the target when the fault is the string, and that is a deliberate
     * trade: the hash comparison is the entire rule, and a string parser in the wallet would be a
     * second rulebook and a heuristic. The SDK prechecks in the wallet's own order so a human sees
     * the real cause; the contract stays simple and fails closed.
     */
    function test_Grant_caseVariantPushStringDerivesUniversal() public {
        string memory shouty = "EIP155:42101";
        vm.chainId(42_101);

        vm.prank(WALLET_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                PushWalletErrors.MandateTypeMismatch.selector, MandateType.UNIVERSAL, uint256(0), address(stakeDummy)
            )
        );
        wallet.grantMandate(_session(_one(_nativeAction(shouty, STAKE))));
    }

    /// With more than one action, the universal `n != 1` rule answers FIRST. Ordering, asserted.
    function test_Grant_foreignChainMultiAction_isShapeNotTypeError() public {
        ActionData[] memory a = new ActionData[](2);
        a[0] = _nativeAction(CHAIN_SEPOLIA, STAKE);
        a[1] = _nativeAction(CHAIN_SEPOLIA, bytes4(0x11111111));

        vm.prank(WALLET_OWNER);
        vm.expectRevert(PushWalletErrors.MalformedSessionShape.selector);
        wallet.grantMandate(_session(a));
    }

    // ═════════════════════════════ the empty chain ═════════════════════════════

    function test_Grant_emptyChainRefused() public {
        ActionData memory a =
            _actionOn("", address(stakeDummy), STAKE, abi.encode(_terms(_nativeCfg(address(stakeDummy), STAKE))));

        vm.prank(WALLET_OWNER);
        vm.expectRevert(PushWalletErrors.EmptyChain.selector);
        wallet.grantMandate(_session(_one(a)));
    }

    // ═══════════════════════════════ ordering ═══════════════════════════════

    /**
     * ⚠️ MUTATION TEST FOR THE COUNT-BEFORE-DECODE ORDER. With zero actions there is no envelope, no
     * chain and therefore no mode — so the count must answer before the derivation does. Move the
     * `n == 0` check below the decode and this reverts with an array-bounds panic instead.
     */
    function test_Grant_zeroActionsRefusedBeforeDecode() public {
        vm.prank(WALLET_OWNER);
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.TooManyActions.selector, uint256(0)));
        wallet.grantMandate(_session(new ActionData[](0)));
    }

    /**
     * ⚠️ MUTATION TEST FOR THE SHAPE-BEFORE-DECODE ORDER, and the reason decision 82's exception is
     * SAFE rather than merely small.
     *
     * The wallet decodes one field of a policy's `initData`. It may only do so once it has proven
     * that policy is URP's — otherwise it would be interpreting an arbitrary third party's bytes as
     * a chain string. Here the policy is a stranger and the `initData` is deliberate nonsense: the
     * shape check must refuse it BEFORE the decoder ever sees it.
     *
     * Move the decode ahead of `_requirePolicyShape` and this fails with an unnamed decode revert
     * instead of the named shape error.
     */
    function test_Grant_nonUrpPolicyRefusedBeforeDecode() public {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: makeAddr("someone-elses-policy"), initData: hex"deadbeef" });

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: STAKE, actionTarget: address(stakeDummy), actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(PushWalletErrors.MalformedSessionShape.selector);
        wallet.grantMandate(_session(a));
    }

    /// Two policies on one action is a shape violation too, and also precedes any decode.
    function test_Grant_twoPoliciesRefusedBeforeDecode() public {
        PolicyData[] memory ps = new PolicyData[](2);
        ps[0] = PolicyData({
            policy: address(urp),
            initData: envelope(nativeChain(), abi.encode(_terms(_nativeCfg(address(stakeDummy), STAKE))))
        });
        ps[1] = ps[0];

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({ actionTargetSelector: STAKE, actionTarget: address(stakeDummy), actionPolicies: ps });

        vm.prank(WALLET_OWNER);
        vm.expectRevert(PushWalletErrors.MalformedSessionShape.selector);
        wallet.grantMandate(_session(a));
    }

    // ═══════════════════════════════ helpers ═══════════════════════════════

    /// @dev `configId = keccak(account, keccak(permissionId, keccak(target, selector)))`.
    function _configId(bytes32 pid, address target, bytes4 selector) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(target, selector));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(pid, actionId));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(wallet), actionPolicyId)));
    }

    function _readGrantEvent(Vm.Log[] memory logs, bytes32 pid)
        internal
        view
        returns (MandateType mode, bytes32 chainHash, string memory chain)
    {
        bytes32 sig = keccak256("MandateGranted(bytes32,uint8,bytes32,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(wallet) && logs[i].topics[0] == sig && logs[i].topics[1] == pid) {
                chainHash = logs[i].topics[2];
                (uint8 m, string memory c) = abi.decode(logs[i].data, (uint8, string));
                return (MandateType(m), chainHash, c);
            }
        }
        revert("MandateGranted not emitted");
    }
}
