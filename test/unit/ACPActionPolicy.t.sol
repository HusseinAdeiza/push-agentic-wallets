// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ACPActionPolicy, AllowedCall, Config } from "../../src/policies/ACPActionPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

/// @dev Reference ABIs used to derive and verify beneficiary offsets (P-18, P-19).
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IMorphoBlue {
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256, uint256);
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice PRD §11.4 — unit tests P-01 … P-20.
contract ACPActionPolicyTest is Test {
    ACPActionPolicy internal policy;

    address internal gateway = address(0x6A7E);
    address internal smartSession = address(0x5E55); // the multiplexer
    address internal account = address(0xA6E7);
    address internal expectedCEA = address(0xCEA);
    address internal asset = address(0xA55E7);

    address internal aavePool = address(0xAAAE);
    address internal morpho = address(0x0817);
    address internal usdc = address(0x115DC);

    ConfigId internal cfgId = ConfigId.wrap(keccak256("cfg"));

    uint256 internal constant MAX_AMOUNT = 1000e6;

    function setUp() public {
        policy = new ACPActionPolicy(gateway);
        _initConfig();
    }

    // ── config helpers ────────────────────────────────────────────────

    function _defaultAllowedCalls() internal view returns (AllowedCall[] memory calls) {
        calls = new AllowedCall[](3);
        // Aave v3 supply(address,uint256,address,uint16) — onBehalfOf at offset 68
        calls[0] = AllowedCall(aavePool, IAaveV3Pool.supply.selector, 68, true);
        // Morpho Blue supply(MarketParams,uint256,uint256,address,bytes) — onBehalf at 228
        calls[1] = AllowedCall(morpho, IMorphoBlue.supply.selector, 228, true);
        // ERC-20 approve — no beneficiary
        calls[2] = AllowedCall(usdc, IERC20Like.approve.selector, 0, false);
    }

    function _initConfig() internal {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            allowedCalls: _defaultAllowedCalls()
        });
        // Encode BEFORE pranking: argument evaluation makes calls of its own, which
        // would consume the one-shot prank before it reaches the policy.
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    function _multicallPayload(Multicall[] memory calls) internal pure returns (bytes memory) {
        return abi.encodePacked(MULTICALL_SELECTOR, abi.encode(calls));
    }

    function _request(bytes memory payload) internal view returns (UniversalOutboundTxRequest memory) {
        return UniversalOutboundTxRequest({
            recipient: "",
            token: asset,
            amount: 100e6,
            gasLimit: 0,
            gasPrice: 0,
            maxPCForGas: 0,
            payload: payload,
            revertRecipient: account
        });
    }

    function _data(UniversalOutboundTxRequest memory req) internal view returns (bytes memory) {
        return abi.encodePacked(policy.SEND_OUTBOUND_SELECTOR(), abi.encode(req));
    }

    function _aaveSupply(address onBehalfOf) internal view returns (bytes memory) {
        return abi.encodeCall(IAaveV3Pool.supply, (usdc, 100e6, onBehalfOf, 0));
    }

    function _morphoSupply(address onBehalf) internal view returns (bytes memory) {
        MarketParams memory mp = MarketParams(usdc, address(0x1), address(0x2), address(0x3), 86e16);
        return abi.encodeCall(IMorphoBlue.supply, (mp, 100e6, 0, onBehalf, ""));
    }

    function _validCalls() internal view returns (Multicall[] memory calls) {
        calls = new Multicall[](2);
        calls[0] = Multicall(usdc, 0, abi.encodeCall(IERC20Like.approve, (aavePool, 100e6)));
        calls[1] = Multicall(aavePool, 0, _aaveSupply(expectedCEA));
    }

    /// @dev Encode first, then call. Callers that expect a revert MUST place
    ///      vm.expectRevert between _encode(...) and _call(...), because building
    ///      the calldata itself performs calls that would consume the cheatcode.
    function _encode(Multicall[] memory calls) internal view returns (bytes memory) {
        return _data(_request(_multicallPayload(calls)));
    }

    function _call(bytes memory d) internal returns (uint256) {
        vm.prank(smartSession);
        return policy.checkAction(cfgId, account, gateway, 0, d);
    }

    function _check(Multicall[] memory calls) internal returns (uint256) {
        return _call(_encode(calls));
    }

    // ── P-01 / P-02 ───────────────────────────────────────────────────

    function test_P01_uninitializedConfigReverts() public {
        ConfigId other = ConfigId.wrap(keccak256("nope"));
        bytes memory d = _data(_request(_multicallPayload(_validCalls())));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.NotInitialized.selector, other, smartSession, account));
        vm.prank(smartSession);
        policy.checkAction(other, account, gateway, 0, d);
    }

    function test_P01b_differentMultiplexerIsIsolated() public {
        bytes memory d = _data(_request(_multicallPayload(_validCalls())));
        vm.expectRevert(
            abi.encodeWithSelector(ACPActionPolicy.NotInitialized.selector, cfgId, address(0xDEAD), account)
        );
        vm.prank(address(0xDEAD));
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    function test_P02_initializeOverwritesExistingConfig() public {
        AllowedCall[] memory one = new AllowedCall[](1);
        one[0] = AllowedCall(aavePool, IAaveV3Pool.supply.selector, 68, true);

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:8453"),
            expectedCEA: address(0xBEEF),
            asset: address(0xFEED),
            maxAmountPerCall: 1,
            allowedCalls: one
        });
        bytes memory initData2 = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData2);

        (
            bool initialized,
            bytes32 destChainHash,
            address cea,
            address a,
            uint256 maxAmt,
            AllowedCall[] memory allowed
        ) = policy.getConfig(cfgId, smartSession, account);

        assertTrue(initialized);
        assertEq(destChainHash, keccak256("eip155:8453"));
        assertEq(cea, address(0xBEEF));
        assertEq(a, address(0xFEED));
        assertEq(maxAmt, 1);
        assertEq(allowed.length, 1, "allowlist must be replaced, not appended");
    }

    // ── P-03 … P-06 — outer request checks ────────────────────────────

    function test_P03_R2_wrongTargetReverts() public {
        bytes memory d = _data(_request(_multicallPayload(_validCalls())));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.InvalidTarget.selector, address(0xBAD)));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, address(0xBAD), 0, d);
    }

    function test_P04_R3_wrongSelectorReverts() public {
        bytes memory bad = abi.encodePacked(bytes4(0xdeadbeef), abi.encode(_request(_multicallPayload(_validCalls()))));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.InvalidSelector.selector, bytes4(0xdeadbeef)));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, bad);
    }

    function test_P04b_shortCalldataReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.InvalidSelector.selector, bytes4(0)));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, hex"11");
    }

    function test_P05_R4_wrongAssetReverts() public {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.token = address(0xBAD);
        bytes memory d = _data(req);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.AssetMismatch.selector, asset, address(0xBAD)));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    function test_P06_R5_amountOverCapReverts() public {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = MAX_AMOUNT + 1;
        bytes memory d = _data(req);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.AmountExceedsCap.selector, MAX_AMOUNT + 1, MAX_AMOUNT));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    function test_P06b_amountExactlyAtCapPasses() public {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = MAX_AMOUNT;
        bytes memory d = _data(req);
        vm.prank(smartSession);
        assertEq(policy.checkAction(cfgId, account, gateway, 0, d), 0);
    }

    // ── P-07 — R6 ─────────────────────────────────────────────────────

    function test_P07_R6_payloadNotMulticallReverts() public {
        bytes memory notMulticall = abi.encodePacked(bytes4(0x12345678), abi.encode(_validCalls()));
        bytes memory d = _data(_request(notMulticall));
        vm.expectRevert(ACPActionPolicy.PayloadNotMulticall.selector);
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    function test_P07b_shortPayloadReverts() public {
        bytes memory d = _data(_request(hex"1122"));
        vm.expectRevert(ACPActionPolicy.PayloadNotMulticall.selector);
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    // ── P-08 … P-10 — R7 forbidden inner targets ──────────────────────

    /// P-08 / A-04 — a session key must not be able to call back into the wallet.
    function test_P08_A04_innerTargetAccountReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(
            account, 0, abi.encodeWithSignature("installModule(uint256,address,bytes)", 1, address(0xBAD), "")
        );

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, account));
        _call(d);
    }

    function test_P09_R7_innerTargetPolicyReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(address(policy), 0, abi.encodeCall(IERC20Like.approve, (aavePool, 1)));

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, address(policy)));
        _call(d);
    }

    function test_P10_R7_innerTargetGatewayReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(gateway, 0, abi.encodeCall(IERC20Like.approve, (aavePool, 1)));

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, gateway));
        _call(d);
    }

    // ── P-11 — R8 ─────────────────────────────────────────────────────

    function test_P11_R8_unlistedTargetReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(address(0x4055), 0, _aaveSupply(expectedCEA));

        bytes memory d = _encode(calls);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACPActionPolicy.CallNotAllowed.selector, address(0x4055), IAaveV3Pool.supply.selector
            )
        );
        _call(d);
    }

    function test_P11b_R8_unlistedSelectorReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] =
            Multicall(aavePool, 0, abi.encodeWithSignature("withdraw(address,uint256,address)", usdc, 1, expectedCEA));

        bytes memory d = _encode(calls);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACPActionPolicy.CallNotAllowed.selector,
                aavePool,
                bytes4(keccak256("withdraw(address,uint256,address)"))
            )
        );
        _call(d);
    }

    // ── P-12 / P-13 — R9 beneficiary ──────────────────────────────────

    /// P-12 / A-05 — the provider cannot redirect the deposit beneficiary.
    function test_P12_A05_beneficiaryMismatchReverts() public {
        address attacker = address(0xA77ACc);
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 0, _aaveSupply(attacker));

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.BeneficiaryMismatch.selector, expectedCEA, attacker));
        _call(d);
    }

    function test_P13_beneficiaryMatchPasses() public {
        assertEq(_check(_validCalls()), 0);
    }

    function test_P13b_morphoBeneficiaryMatchPasses() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(morpho, 0, _morphoSupply(expectedCEA));
        assertEq(_check(calls), 0);
    }

    function test_P13c_morphoBeneficiaryMismatchReverts() public {
        address attacker = address(0xA77ACc);
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(morpho, 0, _morphoSupply(attacker));

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.BeneficiaryMismatch.selector, expectedCEA, attacker));
        _call(d);
    }

    // ── P-14 — R10 ────────────────────────────────────────────────────

    function test_P14_R10_wrongRevertRecipientReverts() public {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.revertRecipient = address(0xBAD);
        bytes memory d = _data(req);
        vm.expectRevert(
            abi.encodeWithSelector(ACPActionPolicy.InvalidRevertRecipient.selector, account, address(0xBAD))
        );
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);
    }

    // ── P-15 — R11 ────────────────────────────────────────────────────

    function test_P15_R11_valueOverspendReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 5 ether, _aaveSupply(expectedCEA));

        bytes memory d = _data(_request(_multicallPayload(calls)));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ValueOverspend.selector, 5 ether, 1 ether));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 1 ether, d);
    }

    function test_P15b_valueWithinBudgetPasses() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 1 ether, _aaveSupply(expectedCEA));

        bytes memory d = _data(_request(_multicallPayload(calls)));
        vm.prank(smartSession);
        assertEq(policy.checkAction(cfgId, account, gateway, 2 ether, d), 0);
    }

    function test_P15c_summedValueAcrossEntriesEnforced() public {
        Multicall[] memory calls = new Multicall[](2);
        calls[0] = Multicall(aavePool, 1 ether, _aaveSupply(expectedCEA));
        calls[1] = Multicall(usdc, 1 ether, abi.encodeCall(IERC20Like.approve, (aavePool, 1)));

        bytes memory d = _data(_request(_multicallPayload(calls)));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ValueOverspend.selector, 2 ether, 1.5 ether));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 1.5 ether, d);
    }

    // ── P-16 / P-17 — malformed inner calldata ────────────────────────

    function test_P16_shortInnerCalldataReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 0, hex"1122");

        bytes memory d = _encode(calls);
        vm.expectRevert(ACPActionPolicy.MalformedInnerCalldata.selector);
        _call(d);
    }

    /// P-17 / A-12 — the offset must be bounds-checked before reading memory.
    function test_P17_A12_beneficiaryOffsetOutOfBoundsReverts() public {
        // Allowlist an entry whose offset points past the end of a short blob.
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall(aavePool, IAaveV3Pool.supply.selector, 60_000, true);

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            allowedCalls: allowed
        });
        bytes memory initData3 = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData3);

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 0, _aaveSupply(expectedCEA));

        bytes memory d = _encode(calls);
        vm.expectRevert(ACPActionPolicy.MalformedInnerCalldata.selector);
        _call(d);
    }

    // ── P-18 / P-19 — the offset table itself ─────────────────────────

    /**
     * P-18 — Aave v3 / Spark.
     * supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
     * onBehalfOf is arg 2 → offset = 4 + 32 + 32 = 68.
     */
    function test_P18_aaveOffset68ExtractsOnBehalfOf() public pure {
        address onBehalfOf = address(0xBEEF00);
        bytes memory cd = abi.encodeCall(IAaveV3Pool.supply, (address(0xA55E7), 123e6, onBehalfOf, 7));

        bytes32 word;
        assembly {
            word := mload(add(add(cd, 0x20), 68))
        }
        assertEq(address(uint160(uint256(word))), onBehalfOf, "offset 68 must extract onBehalfOf");
    }

    /**
     * P-19 — Morpho Blue.
     * supply(MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data)
     * MarketParams is 5 static fields inline = 160 bytes.
     * onBehalf is arg 3 → offset = 4 + 160 + 32 + 32 = 228.
     */
    function test_P19_morphoOffset228ExtractsOnBehalf() public pure {
        address onBehalf = address(0xBEEF01);
        MarketParams memory mp = MarketParams(address(0x1), address(0x2), address(0x3), address(0x4), 86e16);
        bytes memory cd = abi.encodeCall(IMorphoBlue.supply, (mp, 123e6, 0, onBehalf, hex"aabb"));

        bytes32 word;
        assembly {
            word := mload(add(add(cd, 0x20), 228))
        }
        assertEq(address(uint160(uint256(word))), onBehalf, "offset 228 must extract onBehalf");
    }

    // ── P-20 — mixed batch ────────────────────────────────────────────

    function test_P20_oneValidOneInvalidEntryReverts() public {
        address attacker = address(0xA77ACc);
        Multicall[] memory calls = new Multicall[](3);
        calls[0] = Multicall(usdc, 0, abi.encodeCall(IERC20Like.approve, (aavePool, 100e6)));
        calls[1] = Multicall(aavePool, 0, _aaveSupply(expectedCEA)); // valid
        calls[2] = Multicall(aavePool, 0, _aaveSupply(attacker)); // invalid

        bytes memory d = _encode(calls);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.BeneficiaryMismatch.selector, expectedCEA, attacker));
        _call(d);
    }

    function test_emptyMulticallPasses() public {
        Multicall[] memory calls = new Multicall[](0);
        assertEq(_check(calls), 0);
    }

    // ── interface / constants ─────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(policy.supportsInterface(type(IActionPolicy).interfaceId));
        assertTrue(policy.supportsInterface(type(IPolicy).interfaceId));
        assertTrue(policy.supportsInterface(type(IERC165).interfaceId));
        assertFalse(policy.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// MUST match the value used by the deployed CEA — a mismatch makes the CEA
    /// silently take the single-call branch (PRD §9.3).
    function test_multicallSelectorMatchesPushChain() public view {
        assertEq(policy.MULTICALL_SELECTOR(), bytes4(keccak256("UEA_MULTICALL")));
        assertEq(policy.MULTICALL_SELECTOR(), MULTICALL_SELECTOR);
        assertEq(policy.MULTICALL_SELECTOR(), bytes4(0x2cc2842d));
    }

    /// MUST match the real UniversalGatewayPC ABI.
    function test_sendOutboundSelectorMatchesGateway() public view {
        assertEq(policy.SEND_OUTBOUND_SELECTOR(), bytes4(0x77b86bec));
        assertEq(
            policy.SEND_OUTBOUND_SELECTOR(),
            IUniversalGatewayPCRef.sendUniversalTxOutbound.selector,
            "must match the struct-shaped ABI"
        );
    }

    function test_gatewayImmutable() public view {
        assertEq(policy.UNIVERSAL_GATEWAY_PC(), gateway);
    }
}

/// @dev Independent restatement of the gateway ABI, to cross-check the selector.
interface IUniversalGatewayPCRef {
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable;
}
