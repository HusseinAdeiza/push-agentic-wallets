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
    address internal attacker = address(0xBAD);

    ConfigId internal cfgId = ConfigId.wrap(keccak256("cfg"));

    uint256 internal constant MAX_AMOUNT = 1000e6;

    function setUp() public {
        policy = new ACPActionPolicy(gateway);
        _initConfig();
    }

    // ── config helpers ────────────────────────────────────────────────

    function _defaultAllowedCalls() internal view returns (AllowedCall[] memory calls) {
        calls = new AllowedCall[](3);
        // Aave v3 supply(address,uint256,address,uint16) — onBehalfOf at offset 68.
        // expectedArg == address(0) is the R9-ext sentinel for "the wallet's own CEA".
        calls[0] = AllowedCall({
            target: aavePool,
            selector: IAaveV3Pool.supply.selector,
            beneficiaryOffset: 68,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0)
        });
        // Morpho Blue supply(MarketParams,uint256,uint256,address,bytes) — onBehalf at 228
        calls[1] = AllowedCall({
            target: morpho,
            selector: IMorphoBlue.supply.selector,
            beneficiaryOffset: 228,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0)
        });
        // ERC-20 approve(address,uint256) — spender at offset 4, PINNED to the protocol.
        // CV-1 makes this shape MANDATORY: the pre-v2.3 config
        // (hasBeneficiary = false, offset 0) is now unrepresentable, because an unpinned
        // spender let a compromised key hand the CEA's balance to an attacker (A-15).
        calls[2] = AllowedCall({
            target: usdc,
            selector: IERC20Like.approve.selector,
            beneficiaryOffset: 4,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: aavePool
        });
    }

    function _initConfig() internal {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
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
        one[0] = AllowedCall({
            target: aavePool,
            selector: IAaveV3Pool.supply.selector,
            beneficiaryOffset: 68,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0)
        });

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:8453"),
            expectedCEA: address(0xBEEF),
            asset: address(0xFEED),
            maxAmountPerCall: 1,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
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
            uint256 maxTotal,, // maxPCPerCall — asserted by the R12 tests, not here
            uint256 spentSoFar,
            AllowedCall[] memory allowed
        ) = policy.getConfig(cfgId, smartSession, account);

        assertTrue(initialized);
        assertEq(destChainHash, keccak256("eip155:8453"));
        assertEq(cea, address(0xBEEF));
        assertEq(a, address(0xFEED));
        assertEq(maxAmt, 1);
        assertEq(maxTotal, type(uint256).max, "cumulative ceiling must be stored");
        assertEq(spentSoFar, 0, "spent must reset on overwrite");
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

    // ── P-15 — R11: per-call native value ceiling ─────────────────────

    /// R11 — an entry whose value exceeds its allowlisted maxValue is rejected.
    /// v1 entries all carry maxValue = 0, so ANY native value is refused.
    function test_P15_R11_innerValueAboveAllowanceReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 5 ether, _aaveSupply(expectedCEA));

        bytes memory d = _encode(calls);
        vm.expectRevert(
            abi.encodeWithSelector(ACPActionPolicy.InnerValueExceedsAllowance.selector, uint256(0), 5 ether, uint256(0))
        );
        _call(d);
    }

    /// R11 — zero value against a maxValue of zero is fine (the v1 shape).
    function test_P15b_zeroInnerValuePasses() public {
        assertEq(_check(_validCalls()), 0);
    }

    /// R11 — the ceiling is PER ENTRY, so the offending index is reported.
    function test_P15c_secondEntryValueReported() public {
        Multicall[] memory calls = new Multicall[](2);
        calls[0] = Multicall(usdc, 0, abi.encodeCall(IERC20Like.approve, (aavePool, 100e6)));
        calls[1] = Multicall(aavePool, 1 ether, _aaveSupply(expectedCEA));

        bytes memory d = _encode(calls);
        vm.expectRevert(
            abi.encodeWithSelector(ACPActionPolicy.InnerValueExceedsAllowance.selector, uint256(1), 1 ether, uint256(0))
        );
        _call(d);
    }

    /// R11 — a payable target configured with a non-zero maxValue is permitted up
    /// to that ceiling. This is the CEA-attestation-callback shape.
    function test_P15d_valueWithinConfiguredAllowancePasses() public {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: aavePool,
            selector: IAaveV3Pool.supply.selector,
            beneficiaryOffset: 68,
            hasBeneficiary: true,
            maxValue: 2 ether,
            expectedArg: address(0)
        });

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: allowed
        });
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(aavePool, 2 ether, _aaveSupply(expectedCEA));
        assertEq(_check(calls), 0, "value at the ceiling is allowed");

        Multicall[] memory over = new Multicall[](1);
        over[0] = Multicall(aavePool, 2 ether + 1, _aaveSupply(expectedCEA));
        bytes memory d = _encode(over);
        vm.expectRevert(
            abi.encodeWithSelector(
                ACPActionPolicy.InnerValueExceedsAllowance.selector, uint256(0), 2 ether + 1, 2 ether
            )
        );
        _call(d);
    }

    // ── P-21 … P-23 — C-2: cumulative spend cap ───────────────────────

    /// Re-configure with an explicit cumulative ceiling.
    function _initWithTotal(uint256 perCall, uint256 total) internal {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: perCall,
            maxAmountTotal: total,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: _defaultAllowedCalls()
        });
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    function _spend(uint256 amount) internal view returns (bytes memory) {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = amount;
        return _data(req);
    }

    /**
     * P-21 / C-2 — N calls each within maxAmountPerCall but collectively over
     * maxAmountTotal: the call that crosses the line reverts.
     *
     * Before this fix R5 was a PER-CALL ceiling only, so a compromised session key
     * could drain the wallet in repeated in-cap calls.
     */
    function test_P21_C2_cumulativeCapBlocksRepeatedInCapCalls() public {
        _initWithTotal(100e6, 250e6);

        _call(_spend(100e6)); // 100 total
        _call(_spend(100e6)); // 200 total

        // Third call is individually legal but takes the total to 300 > 250.
        bytes memory d = _spend(100e6);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.TotalSpendCapExceeded.selector, 300e6, 250e6));
        _call(d);
    }

    /// P-22 — spending exactly to the ceiling succeeds; the next call reverts.
    function test_P22_C2_exactCeilingThenReject() public {
        _initWithTotal(100e6, 200e6);

        _call(_spend(100e6));
        _call(_spend(100e6)); // exactly at the cap

        (,,,,,,, uint256 spentSoFar,) = policy.getConfig(cfgId, smartSession, account);
        assertEq(spentSoFar, 200e6, "spent must track exactly");

        bytes memory d = _spend(1);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.TotalSpendCapExceeded.selector, 200e6 + 1, 200e6));
        _call(d);
    }

    /// P-23 — re-initialization RESETS spent (a fresh grant by the owner).
    function test_P23_C2_reinitializationResetsSpent() public {
        _initWithTotal(100e6, 200e6);
        _call(_spend(100e6));

        (,,,,,,, uint256 before,) = policy.getConfig(cfgId, smartSession, account);
        assertEq(before, 100e6);

        _initWithTotal(100e6, 200e6); // fresh grant

        (,,,,,,, uint256 afterReset,) = policy.getConfig(cfgId, smartSession, account);
        assertEq(afterReset, 0, "spent must reset on re-initialization");

        // Full budget is available again.
        _call(_spend(100e6));
        _call(_spend(100e6));
    }

    /// P-23b — a supplied non-zero `spent` in initData is ignored, never trusted.
    function test_P23b_C2_suppliedSpentIsIgnored() public {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: 100e6,
            maxAmountTotal: 200e6,
            maxPCPerCall: type(uint256).max,
            spent: 199e6, // attacker-ish value
            allowedCalls: _defaultAllowedCalls()
        });
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);

        (,,,,,,, uint256 spentSoFar,) = policy.getConfig(cfgId, smartSession, account);
        assertEq(spentSoFar, 0, "supplied spent must be ignored");
    }

    /// P-24 — the per-call ceiling still applies independently of the total.
    function test_P24_perCallCeilingStillEnforced() public {
        _initWithTotal(50e6, 1000e6);

        bytes memory d = _spend(51e6);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.AmountExceedsCap.selector, 51e6, 50e6));
        _call(d);
    }

    // ── P-25 … P-27 — R12/R13: Push Chain native value ────────────────

    /// Config with an explicit PC ceiling on the outer gateway call.
    function _initWithPCCap(uint256 pcCap) internal {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: pcCap,
            spent: 0,
            allowedCalls: _defaultAllowedCalls()
        });
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    /// P-25 / R12 — forwarding more Push Chain PC than the ceiling is rejected.
    function test_P25_R12_pcValueAboveCapReverts() public {
        _initWithPCCap(1 ether);

        bytes memory d = _data(_request(_multicallPayload(_validCalls())));
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.PCValueExceedsCap.selector, 2 ether, 1 ether));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 2 ether, d);
    }

    /// P-26 / R12 — value exactly at the ceiling passes.
    function test_P26_R12_pcValueAtCapPasses() public {
        _initWithPCCap(1 ether);

        bytes memory d = _data(_request(_multicallPayload(_validCalls())));
        vm.prank(smartSession);
        assertEq(policy.checkAction(cfgId, account, gateway, 1 ether, d), 0);
    }

    /**
     * P-27 — THE ATTACK, demonstrated blocked.
     *
     * A compromised session key could drain the wallet's PC balance with repeated
     * outbounds carrying `req.amount = 0`:
     *   - amount 0 makes the gateway infer TX_TYPE.GAS_AND_PAYLOAD and SKIP
     *     `_burnPRC20`, so `spent` never grows and the cumulative cap is blind;
     *   - every inner entry has value 0, so `AllowedCall.maxValue` passes;
     *   - the outer `value` carries the whole PC balance, and the gateway takes
     *     `protocolFee` from it unconditionally.
     *
     * R13 rejects the shape outright; R12 caps the outflow for the shapes that remain.
     */
    function test_P27_zeroAmountDrainBlocked() public {
        _initWithPCCap(1 ether);

        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = 0; // the drain shape

        bytes memory d = _data(req);
        vm.expectRevert(ACPActionPolicy.ZeroAmountNotPermitted.selector);
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 1 ether, d);
    }

    /// P-27b — even were the amount non-zero, R12 bounds the per-call PC outflow, so
    /// the drain cannot be scaled up through the value field either.
    function test_P27b_pcOutflowBoundedIndependentlyOfAmount() public {
        _initWithPCCap(0.1 ether);

        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = 1; // minimal, so the amount caps barely move

        bytes memory d = _data(req);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.PCValueExceedsCap.selector, 5 ether, 0.1 ether));
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 5 ether, d);
    }

    /// 2.2 — no state is written when a later check fails: `spent` is untouched.
    function test_P28_spentUnchangedWhenLaterCheckFails() public {
        _initWithTotal(100e6, 1000e6);

        // Passes the amount checks, fails R10 (wrong revertRecipient).
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.amount = 50e6;
        req.revertRecipient = address(0xBAD);

        bytes memory d = _data(req);
        vm.expectRevert();
        vm.prank(smartSession);
        policy.checkAction(cfgId, account, gateway, 0, d);

        (,,,,,,, uint256 spentSoFar,) = policy.getConfig(cfgId, smartSession, account);
        assertEq(spentSoFar, 0, "effects must not land before all checks pass");
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
        allowed[0] = AllowedCall({
            target: aavePool,
            selector: IAaveV3Pool.supply.selector,
            beneficiaryOffset: 60_000,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0)
        });

        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
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

    // ══════════════════════════════════════════════════════════════════
    //  v2 STEP 14 — beneficiary-offset HARD GATE (T-64 / T-65)
    // ══════════════════════════════════════════════════════════════════

    /**
     * T-64 — every shipping `AllowedCall` entry, encoded with the protocol's REAL ABI,
     * must extract the planted address at its configured offset.
     *
     * RULE: no `allowedCalls` entry ships without both T-64 and T-65 coverage. A wrong
     * offset does not fail loudly — it reads the wrong 32-byte word and can silently pass
     * on an attacker-controlled address. Verify offsets against DEPLOYED ABIs, never
     * against documentation.
     *
     * Reference offsets: Aave v3 / Spark `supply` -> 68. Morpho Blue `supply` -> 228.
     * ERC-20 `approve` -> 4.
     */
    function test_T64_everyShippingOffsetExtractsThePlantedAddress() public view {
        address planted = address(0xBEEF99);

        // ERC-20 approve(address spender, uint256) -> spender is arg 0 -> offset 4.
        assertEq(
            _extractVia(abi.encodeCall(IERC20Like.approve, (planted, 1e6)), 4), planted, "approve spender at offset 4"
        );

        // Aave v3 / Spark supply -> onBehalfOf at 4 + 32 + 32 = 68.
        assertEq(
            _extractVia(abi.encodeCall(IAaveV3Pool.supply, (usdc, 1e6, planted, 0)), 68),
            planted,
            "aave onBehalfOf at offset 68"
        );

        // Morpho Blue supply -> onBehalf at 4 + 160 + 32 + 32 = 228.
        MarketParams memory mp = MarketParams(usdc, address(0x2), address(0x3), address(0x4), 86e16);
        assertEq(
            _extractVia(abi.encodeCall(IMorphoBlue.supply, (mp, 1e6, 0, planted, "")), 228),
            planted,
            "morpho onBehalf at offset 228"
        );
    }

    /**
     * T-65 — NEGATIVE CONTROL. Without this, T-64 can pass vacuously.
     *
     * For each entry a deliberately WRONG offset must NOT return the planted address. This
     * is what proves the offsets are load-bearing rather than coincidental — e.g. if a
     * struct were all-zero, several offsets would agree by accident.
     */
    function test_T65_wrongOffsetsDoNotReturnThePlantedAddress() public view {
        address planted = address(0xBEEF99);

        // approve: the amount word (36) is not the spender.
        assertTrue(_extractVia(abi.encodeCall(IERC20Like.approve, (planted, 1e6)), 36) != planted);

        // aave: 4 is the asset, 36 the amount, 100 the referralCode word.
        bytes memory aave = abi.encodeCall(IAaveV3Pool.supply, (usdc, 1e6, planted, 0));
        assertTrue(_extractVia(aave, 4) != planted, "offset 4 is the asset");
        assertTrue(_extractVia(aave, 36) != planted, "offset 36 is the amount");
        assertTrue(_extractVia(aave, 100) != planted, "offset 100 is referralCode");

        // morpho: 196 is `shares`, 164 is `assets`; neither is onBehalf.
        MarketParams memory mp = MarketParams(usdc, address(0x2), address(0x3), address(0x4), 86e16);
        bytes memory morphoCd = abi.encodeCall(IMorphoBlue.supply, (mp, 1e6, 0, planted, ""));
        assertTrue(_extractVia(morphoCd, 164) != planted, "offset 164 is assets");
        assertTrue(_extractVia(morphoCd, 196) != planted, "offset 196 is shares");
    }

    /// @dev Mirrors `_extractBeneficiary` exactly: read the 32-byte word at `offset`, take
    ///      the low 20 bytes.
    function _extractVia(bytes memory cd, uint256 offset) internal pure returns (address) {
        bytes32 word;
        assembly {
            word := mload(add(add(cd, 0x20), offset))
        }
        return address(uint160(uint256(word)));
    }

    // ── P-20 — mixed batch ────────────────────────────────────────────

    function test_P20_oneValidOneInvalidEntryReverts() public {
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

    // ══════════════════════════════════════════════════════════════════
    //  v2 STEP 8 — R7 extension: the CEA is a forbidden inner target
    // ══════════════════════════════════════════════════════════════════

    /**
     * T-42 — A-03 / P-5. The inner CEA self-call IS the exit mechanism.
     *
     * An inner entry targeting the CEA executes with `msg.sender == CEA`, which SATISFIES
     * `CEA.sendUniversalTxToUEA`'s own self-call check (CEA.sol:114), and
     * `CEA._handleMulticall` explicitly permits value-0 self-calls (CEA.sol:196). So
     * without this rule a compromised key could bridge value out of the CEA with an
     * agent-chosen `revertRecipient`. Sessions are ENTRY-ONLY in v2.0; exits are
     * owner-path.
     */
    function test_T42_innerCEATargetIsForbidden() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(
            expectedCEA,
            0,
            abi.encodeWithSignature(
                "sendUniversalTxToUEA(address,uint256,bytes,address)", usdc, 100e6, bytes(""), address(0xBAD)
            )
        );
        bytes memory d = _encode(calls);

        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, expectedCEA));
        _call(d);
    }

    /**
     * T-43 — the rule is STRUCTURAL, not allowlist-dependent.
     *
     * Even with (expectedCEA, sendUniversalTxToUEA) explicitly allowlisted, R7 rejects it.
     * That matters because allowlist omission is one SDK bug away, whereas a structural
     * rule cannot be configured off (F-02).
     */
    function test_T43_ceaTargetRejectedEvenWhenAllowlisted() public {
        bytes4 sel = bytes4(keccak256("sendUniversalTxToUEA(address,uint256,bytes,address)"));

        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: expectedCEA,
            selector: sel,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: 0,
            expectedArg: address(0)
        });
        _reinit(allowed);

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(expectedCEA, 0, abi.encodeWithSelector(sel, usdc, 100e6, bytes(""), address(0xBAD)));
        bytes memory d = _encode(calls);

        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, expectedCEA));
        _call(d);
    }

    /// @dev T-44 — the three pre-existing R7 members still revert. A-04 has three
    ///      independent defences and none may be dropped as "redundant".
    function test_T44_preExistingForbiddenTargetsStillRevert() public {
        address[3] memory forbidden = [account, address(policy), gateway];
        for (uint256 i; i < forbidden.length; ++i) {
            Multicall[] memory calls = new Multicall[](1);
            calls[0] = Multicall(forbidden[i], 0, abi.encodeCall(IERC20Like.approve, (aavePool, 1)));
            bytes memory d = _encode(calls);
            vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.ForbiddenInnerTarget.selector, forbidden[i]));
            _call(d);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  v2 STEP 9 — R9-ext (expectedArg) + CV-1. Closes A-15.
    // ══════════════════════════════════════════════════════════════════

    /// @dev T-45 — the attack. An approve whose spender is not the pinned protocol is
    ///      rejected, so `approve(attacker, max)` cannot ride along inside a valid bridge.
    function test_T45_approveToAttackerReverts() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(usdc, 0, abi.encodeCall(IERC20Like.approve, (attacker, type(uint256).max)));
        bytes memory d = _encode(calls);

        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.BeneficiaryMismatch.selector, aavePool, attacker));
        _call(d);
    }

    /// @dev T-46 — the legitimate approve passes.
    function test_T46_approveToPinnedProtocolPasses() public {
        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall(usdc, 0, abi.encodeCall(IERC20Like.approve, (aavePool, 100e6)));
        assertEq(_check(calls), 0);
    }

    /**
     * T-47 — BACKWARD COMPATIBILITY of the sentinel.
     *
     * `expectedArg == address(0)` must still mean "the wallet's own CEA", so every
     * deposit-style entry keeps its original semantics. Both directions asserted.
     */
    function test_T47_zeroExpectedArgStillMeansCEA() public {
        // Pass: beneficiary is the CEA.
        Multicall[] memory good = new Multicall[](1);
        good[0] = Multicall(aavePool, 0, _aaveSupply(expectedCEA));
        assertEq(_check(good), 0);

        // Fail: beneficiary is anyone else.
        Multicall[] memory bad = new Multicall[](1);
        bad[0] = Multicall(aavePool, 0, _aaveSupply(attacker));
        bytes memory d = _encode(bad);
        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.BeneficiaryMismatch.selector, expectedCEA, attacker));
        _call(d);
    }

    /**
     * T-48 — THE DOOR IS LOCKED (CV-1, F-29). NEVER DELETE.
     *
     * A-15 (unpinned approve -> attacker drains the CEA via transferFrom) has no
     * exploit-demo test because CV-1 makes the vulnerable config UNCONSTRUCTIBLE: the
     * guard lives in `ACPActionPolicy.initializeWithMultiplexer`, so it fires on
     * `grantMandate`, `reconfigureMandate`, AND the `callValidator(enableSessions)` escape
     * hatch alike. This revert test IS the demonstration — it proves the door is locked.
     *
     * Do NOT add a mock ACP without CV-1 to "show the attack"; that would test a contract
     * we do not ship.
     */
    function test_CV1_unpinnedApprovalEntryReverts() public {
        bytes4 approveSel = IERC20Like.approve.selector;
        bytes4 increaseSel = bytes4(keccak256("increaseAllowance(address,uint256)"));

        // hasBeneficiary = false — the pre-v2.3 shape that left the spender unchecked.
        _expectUnpinned(usdc, approveSel, 0, false, aavePool);
        // Wrong offset — would read the wrong 32-byte word.
        _expectUnpinned(usdc, approveSel, 36, true, aavePool);
        // expectedArg == 0 — the CEA sentinel is meaningless for a spender; the CEA
        // approving itself is not the pin we need.
        _expectUnpinned(usdc, approveSel, 4, true, address(0));
        // increaseAllowance is covered identically.
        _expectUnpinned(usdc, increaseSel, 0, false, aavePool);
        _expectUnpinned(usdc, increaseSel, 4, true, address(0));
    }

    /**
     * CV-2 — a config committing a ZERO `expectedCEA` is rejected at grant time.
     *
     * WHY THIS MATTERS. `AllowedCall.expectedArg == address(0)` is the R9-ext sentinel for
     * "the wallet's own CEA", so every deposit-style entry resolves its pin through
     * `cfg.expectedCEA`. A zero `expectedCEA` collapses that sentinel: R9-ext would compare
     * the extracted beneficiary against address(0), and an inner `supply(onBehalf = 0)`
     * would sail through the beneficiary check.
     *
     * The SDK is obliged to commit a correct CEA (S-8), but P-7 says anything the SDK could
     * silently get wrong is validated on-chain. Same reasoning as CV-1.
     */
    function test_CV2_zeroExpectedCEAReverts() public {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: aavePool,
            selector: IAaveV3Pool.supply.selector,
            beneficiaryOffset: 68,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: address(0) // the CEA sentinel
        });
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: address(0), // the defect
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: allowed
        });
        bytes memory initData = abi.encode(cfg);

        vm.expectRevert(ACPActionPolicy.ZeroExpectedCEA.selector);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    /// @dev CV-2 fires on an EMPTY allowlist too: the check precedes the copy loop, so a
    ///      config cannot slip through by carrying no entries.
    function test_CV2_zeroExpectedCEARejectedEvenWithEmptyAllowlist() public {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: address(0),
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: new AllowedCall[](0)
        });
        bytes memory initData = abi.encode(cfg);

        vm.expectRevert(ACPActionPolicy.ZeroExpectedCEA.selector);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    /// @dev The compliant shape is accepted, so CV-1 is not simply rejecting everything.
    function test_CV1_pinnedApprovalEntryAccepted() public {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: usdc,
            selector: IERC20Like.approve.selector,
            beneficiaryOffset: 4,
            hasBeneficiary: true,
            maxValue: 0,
            expectedArg: aavePool
        });
        _reinit(allowed); // must not revert
    }

    /// @dev T-67 — drift protection. A hardcoded magic value in a security check must
    ///      always carry a test that recomputes it from the signature.
    function test_T67_approvalSelectorsMatchSignatures() public pure {
        assertEq(bytes4(0x095ea7b3), bytes4(keccak256("approve(address,uint256)")), "approve");
        assertEq(bytes4(0x39509351), bytes4(keccak256("increaseAllowance(address,uint256)")), "increaseAllowance");
    }

    // ══════════════════════════════════════════════════════════════════
    //  v2 STEP 10 — R14 + the attribution event
    // ══════════════════════════════════════════════════════════════════

    /**
     * T-49 — R14. A non-empty `req.recipient` is rejected.
     *
     * This is a FAIL-CLOSED backstop for R6 (P-4): if the multicall prefix check were ever
     * bypassed, `CEA._handleSingleCall` would receive recipient == address(0) with a
     * non-empty payload and revert `InvalidRecipient()` (CEA.sol:237) rather than execute
     * `recipient.call{value: msg.value}(payload)` — direct theft (A-02).
     */
    function test_T49_nonEmptyRecipientReverts() public {
        UniversalOutboundTxRequest memory req = _request(_multicallPayload(_validCalls()));
        req.recipient = abi.encodePacked(attacker);
        bytes memory d = _data(req);

        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.NonEmptyRecipient.selector, uint256(20)));
        _call(d);
    }

    function test_T50_emptyRecipientPasses() public {
        assertEq(_check(_validCalls()), 0);
    }

    /**
     * T-51 — F-11 attribution. The event names the config that authorized the action, and
     * the ConfigId must match the value an indexer recomputes off-chain.
     */
    function test_T51_emitsMandateActionAuthorized() public {
        Multicall[] memory calls = _validCalls();
        bytes memory payload = _multicallPayload(calls);
        bytes memory d = _data(_request(payload));

        vm.expectEmit(true, true, false, true);
        emit ACPActionPolicy.MandateActionAuthorized(cfgId, account, keccak256(payload), 100e6);
        _call(d);
    }

    // ── v2 helpers ────────────────────────────────────────────────────

    function _reinit(AllowedCall[] memory allowed) internal {
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: allowed
        });
        bytes memory initData = abi.encode(cfg);
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }

    function _expectUnpinned(address target, bytes4 selector, uint16 offset, bool hasBeneficiary, address expectedArg)
        internal
    {
        AllowedCall[] memory allowed = new AllowedCall[](1);
        allowed[0] = AllowedCall({
            target: target,
            selector: selector,
            beneficiaryOffset: offset,
            hasBeneficiary: hasBeneficiary,
            maxValue: 0,
            expectedArg: expectedArg
        });
        Config memory cfg = Config({
            initialized: false,
            destChainHash: keccak256("eip155:1"),
            expectedCEA: expectedCEA,
            asset: asset,
            maxAmountPerCall: MAX_AMOUNT,
            maxAmountTotal: type(uint256).max,
            maxPCPerCall: type(uint256).max,
            spent: 0,
            allowedCalls: allowed
        });
        bytes memory initData = abi.encode(cfg);

        vm.expectRevert(abi.encodeWithSelector(ACPActionPolicy.UnpinnedApprovalEntry.selector, target, selector));
        vm.prank(smartSession);
        policy.initializeWithMultiplexer(account, cfgId, initData);
    }
}

/// @dev Independent restatement of the gateway ABI, to cross-check the selector.
interface IUniversalGatewayPCRef {
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable;
}
