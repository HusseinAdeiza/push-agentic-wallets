// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { UniversalRulesPolicy } from "../../src/policies/UniversalRulesPolicy.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { PushChainLib } from "../../src/libraries/PushChainLib.sol";
import { AGW } from "../../src/AGW.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import {
    AllowedCall,
    AllowedProgram,
    AssetCap,
    AmountRule,
    ArgPin,
    Config,
    ModeSlot,
    NativeConfig,
    RulesType,
    SvmAccountPin,
    SvmConfig,
    SvmDataPin,
    SvmDataPinMode,
    SvmTerms,
    VmFamily
} from "../../src/libraries/Types.sol";
import { ConfigId, Session } from "smartsessions/DataTypes.sol";
import { IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { MockPRC20Source } from "../mocks/MockPRC20Source.sol";

/// @dev Exposes URP's internal program-id constants to the base58 witness test. Adds nothing to
///      URP's own selector set, which stays pinned exactly.
contract URPExposed is UniversalRulesPolicy {
    function systemProgram() external pure returns (bytes32) {
        return SYSTEM_PROGRAM;
    }

    function splTokenProgram() external pure returns (bytes32) {
        return SPL_TOKEN_PROGRAM;
    }

    function token2022Program() external pure returns (bytes32) {
        return TOKEN_2022_PROGRAM;
    }

    function stakeProgram() external pure returns (bytes32) {
        return STAKE_PROGRAM;
    }

    function bpfLoaderUpgradeable() external pure returns (bytes32) {
        return BPF_LOADER_UPGRADEABLE;
    }

    function addressLookupTable() external pure returns (bytes32) {
        return ADDRESS_LOOKUP_TABLE;
    }
}

/// @dev `PushChainLib` is `internal`; this is the thinnest possible external surface for it.
contract PushChainLibHarness {
    function deriveVm(string memory chain) external pure returns (VmFamily) {
        return PushChainLib.deriveVm(chain);
    }
}

/**
 * @notice URP — the third rulebook: `solana:*` universal mandates.
 *
 * The example rule throughout is a Jupiter `sharedAccountsRoute` from a pUSDC mandate into WETH,
 * because it is the shape that motivated every gate: one CPI, the CEA as signer, value carried in
 * accounts the program reads BY POSITION, and Borsh scalars that sit at stable offsets only from the
 * END of the instruction data. Every negative test names the gate that fired.
 *
 * Direct calls to `checkAction` carry the full revert data; the engine-driven tests at the end use
 * `expectUrpGate`, which truncates exactly as SmartSession does.
 */
contract URPSvmTest is BaseTest {
    // ───────────────────────────── fixtures ─────────────────────────────

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0x50FA)));
    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    address internal ACCOUNT;
    address internal ASSET;

    // Solana keys are arbitrary 32-byte values here; only equality matters to URP.
    bytes32 internal CEA = keccak256("push_identity pda for ACCOUNT");
    bytes32 internal ATA_IN = keccak256("ata(CEA, USDC)");
    bytes32 internal ATA_OUT = keccak256("ata(CEA, WETH)");
    bytes32 internal MINT_IN = keccak256("USDC mint");
    bytes32 internal MINT_OUT = keccak256("WETH mint");
    bytes32 internal GATEWAY_PROG = keccak256("push svm gateway program");
    bytes32 internal PROG = keccak256("aggregator program");
    bytes32 internal PROG2 = keccak256("some other program");
    bytes32 internal TOKEN_PROG_ACC = keccak256("token program (as an account)");
    bytes32 internal PROGRAM_AUTHORITY = keccak256("aggregator program authority");
    bytes32 internal PROG_SRC = keccak256("program source token account");
    bytes32 internal PROG_DST = keccak256("program destination token account");
    bytes32 internal ATTACKER = keccak256("attacker account");

    /// @dev Anchor discriminators — `sha256("global:<name>")[..8]` — as LITERALS. `sha256` is a
    ///      precompile call at runtime, and a precompile call inside an argument expression consumes
    ///      a pending `vm.prank`. `test_fixture_discriminatorsAreTheAnchorTags` pins the literals.
    bytes8 internal constant ROUTE = 0xc1209b3341d69c81; // shared_accounts_route
    bytes8 internal constant OTHER_IX = 0x96564774a75d0e68; // route_with_token_ledger
    bytes8 internal constant SELF_WITHDRAW = 0x75e0217b968181a2; // send_universal_tx_to_uea

    // Jupiter's trailing Borsh scalars, addressed from the END of ix_data (see SvmDataPin):
    //   platform_fee_bps u8 at -1 · slippage_bps u16 at -3 · quoted_out u64 at -11 · in_amount u64 at -19
    uint16 internal constant OFF_FEE = 1;
    uint16 internal constant OFF_SLIPPAGE = 3;
    uint16 internal constant OFF_QUOTED_OUT = 11;
    uint16 internal constant OFF_IN_AMOUNT = 19;

    uint256 internal constant MAX_PER_CALL = 100_000_000; // 100 USDC, 6 decimals
    uint256 internal constant MAX_TOTAL = 1_000_000_000;
    uint256 internal constant MAX_PC = 5 ether;

    URPExposed internal exposed;
    PushChainLibHarness internal lib;

    function setUp() public override {
        super.setUp();
        ACCOUNT = makeAddr("agentWallet");
        MockPRC20 asset = new MockPRC20();
        asset.setSourceChainNamespace(CHAIN_SOLANA_DEVNET);
        ASSET = address(asset);
        exposed = new URPExposed();
        lib = new PushChainLibHarness();
        vm.warp(1_000_000_000);
    }

    // ───────────────────────────── term builders ─────────────────────────────

    function _routeRule() internal pure returns (AllowedProgram memory) {
        return AllowedProgram({
            program: bytes32(0), discriminator: ROUTE, discriminatorLen: 8, dataless: false, maxAccounts: 0
        });
    }

    function _rules() internal view returns (AllowedProgram[] memory r) {
        r = new AllowedProgram[](1);
        r[0] = _routeRule();
        r[0].program = PROG;
    }

    /// @dev The compiler's output for the example rule: authority, source, destination and the fee
    ///      account pinned — every position through which value can leave or arrive.
    function _pins() internal view returns (SvmAccountPin[] memory p) {
        p = new SvmAccountPin[](4);
        p[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        p[1] = SvmAccountPin({ ruleIndex: 0, accountIndex: 3, expected: ATA_IN });
        p[2] = SvmAccountPin({ ruleIndex: 0, accountIndex: 6, expected: ATA_OUT });
        p[3] = SvmAccountPin({ ruleIndex: 0, accountIndex: 9, expected: ATA_OUT });
    }

    function _dataPin(
        SvmDataPinMode mode,
        uint16 offset,
        uint16 offsetB,
        uint8 len,
        bytes32 expected,
        uint64 num,
        uint64 den
    ) internal pure returns (SvmDataPin memory) {
        return SvmDataPin({
            ruleIndex: 0,
            fromEnd: true,
            offset: offset,
            offsetB: offsetB,
            len: len,
            mode: mode,
            expected: expected,
            num: num,
            den: den
        });
    }

    /// @dev fee == 0 · slippage <= 50 bps · quoted_out × 100 >= in_amount × 95.
    function _dataPins() internal pure returns (SvmDataPin[] memory d) {
        d = new SvmDataPin[](3);
        d[0] = _dataPin(SvmDataPinMode.EQ, OFF_FEE, 0, 1, bytes32(0), 0, 0);
        d[1] = _dataPin(SvmDataPinMode.LTE_LE, OFF_SLIPPAGE, 0, 2, bytes32(uint256(50)), 0, 0);
        d[2] = _dataPin(SvmDataPinMode.RATIO_GTE_LE, OFF_QUOTED_OUT, OFF_IN_AMOUNT, 8, bytes32(0), 95, 100);
    }

    function _ceaAccounts() internal view returns (bytes32[] memory c) {
        c = new bytes32[](3);
        c[0] = CEA;
        c[1] = ATA_IN;
        c[2] = ATA_OUT;
    }

    function _terms() internal view returns (SvmTerms memory t) {
        t = SvmTerms({
            validUntil: VALID_UNTIL,
            expectedCEA: CEA,
            gatewayProgram: GATEWAY_PROG,
            assets: oneCap(ASSET, MAX_PER_CALL, MAX_TOTAL),
            maxGasPerCall: MAX_PC,
            ceaAccounts: _ceaAccounts(),
            programs: _rules(),
            pins: _pins(),
            dataPins: _dataPins()
        });
    }

    function _init(SvmTerms memory t) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, svmInitData(CHAIN_SOLANA_DEVNET, t));
    }

    function _initDefault() internal {
        _init(_terms());
    }

    // ───────────────────────────── request builders ─────────────────────────────

    /// @dev The ten accounts of `sharedAccountsRoute` in IDL order; index 9 is the fee account.
    function _accounts() internal view returns (bytes32[] memory a, bool[] memory w) {
        a = new bytes32[](10);
        w = new bool[](10);
        a[0] = TOKEN_PROG_ACC;
        a[1] = PROGRAM_AUTHORITY;
        a[2] = CEA;
        w[2] = true;
        a[3] = ATA_IN;
        w[3] = true;
        a[4] = PROG_SRC;
        w[4] = true;
        a[5] = PROG_DST;
        w[5] = true;
        a[6] = ATA_OUT;
        w[6] = true;
        a[7] = MINT_IN;
        a[8] = MINT_OUT;
        a[9] = ATA_OUT;
        w[9] = true;
    }

    /// @dev `shared_accounts_route(id, route_plan, in_amount, quoted_out_amount, slippage_bps,
    ///      platform_fee_bps)` — a one-step route plan so the trailing scalars sit where the pins
    ///      expect them. `id` and the plan are agent-chosen bytes URP never reads.
    function _ixData(uint64 inAmount, uint64 quotedOut, uint16 slippageBps, uint8 feeBps)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory routePlan = abi.encodePacked(le(1, 4), uint8(3), uint8(100), uint8(0), uint8(1));
        return
            abi.encodePacked(ROUTE, uint8(7), routePlan, le(inAmount, 8), le(quotedOut, 8), le(slippageBps, 2), feeBps);
    }

    /// @dev A swap that satisfies every pin: 50 USDC in, 49 USDC-equivalent quoted out, 30 bps, no fee.
    function _goodIx() internal pure returns (bytes memory) {
        return _ixData(50_000_000, 49_000_000, 30, 0);
    }

    function _payload(bytes memory ixData) internal view returns (bytes memory) {
        (bytes32[] memory a, bool[] memory w) = _accounts();
        return svmExecutePayload(a, w, ixData, 2, PROG);
    }

    function _request(uint256 amount, bytes memory payload) internal view returns (bytes memory) {
        return svmOutboundRequest(ASSET, amount, 1 ether, ACCOUNT, abi.encodePacked(PROG), payload);
    }

    function _good(uint256 amount) internal view returns (bytes memory) {
        return _request(amount, _payload(_goodIx()));
    }

    function _check(uint256 value, bytes memory data) internal returns (uint256) {
        vm.prank(address(engine));
        return urp.checkAction(CID, ACCOUNT, GATEWAY, value, data);
    }

    /// @dev Prank, THEN arm the revert, THEN call — the order Foundry requires. A `vm.prank` after
    ///      `vm.expectRevert` is itself "the next call" and the expectation misfires.
    function _checkReverts(bytes memory err, uint256 value, bytes memory data) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.checkAction(CID, ACCOUNT, GATEWAY, value, data);
    }

    function _initReverts(bytes memory err, SvmTerms memory t) internal {
        vm.prank(address(engine));
        vm.expectRevert(err);
        urp.initializeWithMultiplexer(ACCOUNT, CID, svmInitData(CHAIN_SOLANA_DEVNET, t));
    }

    function _spent() internal view returns (uint256) {
        return urp.getSvmConfig(CID, ACCOUNT).assets[0].spent;
    }

    // ───────────────────────────── multi-asset (SVM) ─────────────────────────────

    /// @dev The default rules set plus a second Solana-devnet PRC20 (e.g. USDT.sol), 10/20 capped.
    function _twoSvmAssets() internal returns (SvmTerms memory t, address second) {
        second = address(new MockPRC20Source(CHAIN_SOLANA_DEVNET));
        t = _terms();
        AssetCap[] memory a = new AssetCap[](2);
        a[0] = t.assets[0];
        a[1] = AssetCap({ token: second, maxPerCall: 10_000_000, maxTotal: 20_000_000 });
        t.assets = a;
    }

    function _goodWith(address token, uint256 amount) internal view returns (bytes memory) {
        return svmOutboundRequest(token, amount, 1 ether, ACCOUNT, abi.encodePacked(PROG), _payload(_goodIx()));
    }

    function test_svm_MA_twoAssetsMeteredOnTheirOwnCounters() public {
        (SvmTerms memory t, address second) = _twoSvmAssets();
        _init(t);

        _check(0, _goodWith(ASSET, 50_000_000));
        _check(0, _goodWith(second, 7_000_000));

        SvmConfig memory got = urp.getSvmConfig(CID, ACCOUNT);
        assertEq(got.assets[0].spent, 50_000_000, "first asset metered alone");
        assertEq(got.assets[1].spent, 7_000_000, "second asset metered alone");

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.AmountExceedsCap.selector, uint256(11_000_000), uint256(10_000_000)
            ),
            0,
            _goodWith(second, 11_000_000)
        );
    }

    /// ⚠️ NEVER-DELETE. The SVM half of the chain-escape guard: an unlisted token routes elsewhere even
    /// at amount 0, so gate S5 refuses it before anything else.
    function test_svm_MA_unlistedTokenRefusedEvenAtZeroAmount() public {
        _initDefault();
        address evmToken = address(new MockPRC20Source("eip155:11155111"));
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AssetNotAllowed.selector, evmToken),
            0,
            _goodWith(evmToken, 0)
        );
    }

    function test_svm_MA_emptyListRefusedAndEveryTokenChainChecked() public {
        SvmTerms memory t = _terms();
        t.assets = new AssetCap[](0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AssetListOutOfRange.selector, uint256(0)), t);

        (t,) = _twoSvmAssets();
        address evmToken = address(new MockPRC20Source("eip155:11155111"));
        t.assets[1].token = evmToken;
        _initReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ChainMismatch.selector,
                keccak256(bytes(CHAIN_SOLANA_DEVNET)),
                keccak256(bytes("eip155:11155111"))
            ),
            t
        );
    }

    /**
     * The documented Solana limit: one rule per (program, instruction), so one pinned key per position.
     * The route rule pins its input (index 3) to the USDC account, so the second asset's token account,
     * even when listed, can never be that instruction's input:
     * - put at the pinned input position, it fails the account pin (S17);
     * - passed anywhere unpinned, it fails the value-holding check (S18).
     */
    function test_svm_MA_oneInputPinPerInstruction() public {
        (SvmTerms memory t, address second) = _twoSvmAssets();
        bytes32 ataSecond = keccak256("ata(CEA, second asset)");
        bytes32[] memory listed = new bytes32[](4);
        listed[0] = CEA;
        listed[1] = ATA_IN;
        listed[2] = ATA_OUT;
        listed[3] = ataSecond;
        t.ceaAccounts = listed;
        _init(t);

        (bytes32[] memory a, bool[] memory w) = _accounts();
        a[3] = ataSecond;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmAccountPinMismatch.selector, uint256(1), uint8(3), ATA_IN, ataSecond
            ),
            0,
            svmOutboundRequest(
                second, 1_000_000, 1 ether, ACCOUNT, abi.encodePacked(PROG), svmExecutePayload(a, w, _goodIx(), 2, PROG)
            )
        );

        (bytes32[] memory a10, bool[] memory w10) = _accounts();
        bytes32[] memory a11 = new bytes32[](11);
        bool[] memory w11 = new bool[](11);
        for (uint256 i; i < 10; ++i) {
            a11[i] = a10[i];
            w11[i] = w10[i];
        }
        a11[10] = ataSecond;
        w11[10] = true;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex.selector, uint256(10), ataSecond
            ),
            0,
            svmOutboundRequest(
                    second,
                    1_000_000,
                    1 ether,
                    ACCOUNT,
                    abi.encodePacked(PROG),
                    svmExecutePayload(a11, w11, _goodIx(), 2, PROG)
                )
        );
    }

    /// @dev S18 cost of one more listed value-holding account, on the default 10-account request,
    ///      budget = measured +10%. Two budgets because the run mode decides warmth (see the multi-asset
    ///      suite's MA18): plain runs see slots init just wrote as warm; `--isolate` / `--gas-report`
    ///      read them cold, as a real agent call does.
    ///      Measured 4,041 warm and 6,041 cold per extra listed account; listing all 16 instead of 3
    ///      adds about 78.5k gas cold. The cost is request accounts × listed accounts storage reads, so a
    ///      longer request scales it up.
    uint256 internal constant S18_GAS_PER_LISTED_ACCOUNT_BUDGET = 4_445;
    uint256 internal constant S18_GAS_PER_LISTED_ACCOUNT_BUDGET_ISOLATED = 6_645;

    /// Raising MAX_CEA_ACCOUNTS to 16 costs nothing unless the owner lists more: S18 gas grows with the
    /// number actually listed. Measured on fresh configs listing 3 and 16, after a warm-up on a third.
    function test_gas_svm_S18CostPerListedAccount() public {
        ConfigId warm = ConfigId.wrap(bytes32(uint256(0x5180)));
        ConfigId three = ConfigId.wrap(bytes32(uint256(0x5183)));
        ConfigId sixteen = ConfigId.wrap(bytes32(uint256(0x5196)));
        SvmTerms memory t = _terms();
        vm.startPrank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, warm, svmInitData(CHAIN_SOLANA_DEVNET, t));
        urp.initializeWithMultiplexer(ACCOUNT, three, svmInitData(CHAIN_SOLANA_DEVNET, t));
        t.ceaAccounts = _ceaAccountsOfLength(16);
        urp.initializeWithMultiplexer(ACCOUNT, sixteen, svmInitData(CHAIN_SOLANA_DEVNET, t));
        vm.stopPrank();

        bytes memory req = _good(0);
        vm.prank(address(engine));
        urp.checkAction(warm, ACCOUNT, GATEWAY, 0, req);

        vm.prank(address(engine));
        uint256 g3 = gasleft();
        urp.checkAction(three, ACCOUNT, GATEWAY, 0, req);
        g3 -= gasleft();

        vm.prank(address(engine));
        uint256 g16 = gasleft();
        urp.checkAction(sixteen, ACCOUNT, GATEWAY, 0, req);
        g16 -= gasleft();

        uint256 perAccount = (g16 - g3) / 13;
        emit log_named_uint("S18 gas per extra listed account (10-account request)", perAccount);
        emit log_named_uint("checkAction gas, 3 listed", g3);
        emit log_named_uint("checkAction gas, 16 listed", g16);
        uint256 budget =
            isolatedCalls() ? S18_GAS_PER_LISTED_ACCOUNT_BUDGET_ISOLATED : S18_GAS_PER_LISTED_ACCOUNT_BUDGET;
        assertLe(perAccount, budget, "S18 per listed account");
    }

    function test_svm_MA_creditRevertTouchesOnlyItsToken() public {
        (SvmTerms memory t, address second) = _twoSvmAssets();
        _init(t);
        _check(0, _goodWith(ASSET, 50_000_000));
        _check(0, _goodWith(second, 7_000_000));

        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("svm-second"), second, 2_000_000);

        SvmConfig memory got = urp.getSvmConfig(CID, ACCOUNT);
        assertEq(got.assets[1].spent, 5_000_000, "second asset credited");
        assertEq(got.assets[0].spent, 50_000_000, "first asset untouched");
    }

    // ═════════════════════════════ init ═════════════════════════════

    function test_svmInit_storesTermsAndRoutesToSvm() public {
        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.RulesConfigured(
            CID, address(engine), ACCOUNT, RulesType.UNIVERSAL, VmFamily.SVM, keccak256(bytes(CHAIN_SOLANA_DEVNET))
        );
        vm.expectEmit(true, true, true, true, address(urp));
        emit IPolicy.PolicySet(CID, address(engine), ACCOUNT);
        _initDefault();

        ModeSlot memory m = urp.getMode(CID, ACCOUNT);
        assertTrue(m.initialized, "initialised");
        assertEq(uint8(m.mode), uint8(RulesType.UNIVERSAL), "universal");
        assertEq(uint8(m.vm), uint8(VmFamily.SVM), "svm family");
        assertEq(m.chainHash, keccak256(bytes(CHAIN_SOLANA_DEVNET)), "chain recorded");

        SvmConfig memory c = urp.getSvmConfig(CID, ACCOUNT);
        assertTrue(c.initialized, "config initialised");
        assertEq(c.validUntil, VALID_UNTIL);
        assertEq(c.expectedCEA, CEA);
        assertEq(c.gatewayProgram, GATEWAY_PROG);
        assertEq(c.assets[0].token, ASSET);
        assertEq(c.assets[0].maxPerCall, MAX_PER_CALL);
        assertEq(c.assets[0].maxTotal, MAX_TOTAL);
        assertEq(c.maxGasPerCall, MAX_PC);
        assertEq(c.assets[0].spent, 0, "spent starts at zero");
        assertEq(c.ceaAccounts.length, 3);
        assertEq(c.ceaAccounts[2], ATA_OUT);
        assertEq(c.programs.length, 1);
        assertEq(c.programs[0].program, PROG);
        assertEq(c.programs[0].discriminator, ROUTE);
        assertEq(c.programs[0].discriminatorLen, 8);
        assertEq(c.pins.length, 4);
        assertEq(c.pins[2].accountIndex, 6);
        assertEq(c.pins[2].expected, ATA_OUT);
        assertEq(c.pins[3].accountIndex, 9);
        assertEq(c.dataPins.length, 3);
        assertEq(uint8(c.dataPins[2].mode), uint8(SvmDataPinMode.RATIO_GTE_LE));
        assertEq(c.dataPins[2].num, 95);
        assertEq(c.dataPins[2].den, 100);
    }

    function test_svmInit_eip155GrantReportsEvm() public {
        MockPRC20 sepoliaAsset = new MockPRC20();
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: makeAddr("router"), selector: 0x12345678, beneficiaryOffset: 36, hasBeneficiary: false, maxValue: 0
        });
        Config memory cfg = Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            destChainHash: bytes32(0),
            expectedCEA: makeAddr("cea"),
            maxGasPerCall: 1,
            assets: oneAsset(address(sepoliaAsset), 1, 1),
            allowedCalls: rules
        });
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(cfg));

        assertEq(uint8(urp.getMode(CID, ACCOUNT).vm), uint8(VmFamily.EVM), "eip155 is the EVM family");
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongVmForCall.selector, VmFamily.EVM));
        urp.getSvmConfig(CID, ACCOUNT);
    }

    function test_svmInit_unsupportedNamespaceRevertsNamed() public {
        string memory chain = "cosmos:cosmoshub-4";
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(PushChainLib.UnsupportedNamespace.selector, keccak256(bytes(chain))));
        urp.initializeWithMultiplexer(ACCOUNT, CID, svmInitData(chain, _terms()));

        // Nothing was written: the slot is still empty and a later grant is not refused as re-init.
        assertFalse(urp.getMode(CID, ACCOUNT).initialized, "nothing written");
    }

    function test_svmInit_assetFromAnotherChainReverts() public {
        // A pUSDC that answers Sepolia, granted under a Solana envelope: the teeth bite as on EVM.
        MockPRC20 wrong = new MockPRC20();
        SvmTerms memory t = _terms();
        t.assets[0].token = address(wrong);
        _initReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ChainMismatch.selector,
                keccak256(bytes(CHAIN_SOLANA_DEVNET)),
                keccak256("eip155:11155111")
            ),
            t
        );
    }

    function test_svmInit_codelessAssetReverts() public {
        SvmTerms memory t = _terms();
        t.assets[0].token = makeAddr("no code here");
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidAsset.selector, t.assets[0].token), t);
    }

    function test_svmInit_revertingAssetReverts() public {
        SvmTerms memory t = _terms();
        t.assets[0].token = makeAddr("reverts on every call");
        vm.etch(t.assets[0].token, hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidAsset.selector, t.assets[0].token), t);
    }

    function test_svmInit_reinitRefusedAcrossEverything() public {
        _initDefault();
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID), _terms());
    }

    function test_svmInit_programListOutOfRange() public {
        SvmTerms memory t = _terms();
        t.programs = new AllowedProgram[](0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramListOutOfRange.selector, 0), t);

        t = _terms();
        t.programs = new AllowedProgram[](33);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramListOutOfRange.selector, 33), t);
    }

    function test_svmInit_listBoundsNamed() public {
        SvmTerms memory t = _terms();
        t.pins = new SvmAccountPin[](17);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.TooManySvmPins.selector, 17), t);

        t = _terms();
        t.dataPins = new SvmDataPin[](9);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.TooManySvmDataPins.selector, 9), t);

        t = _terms();
        t.ceaAccounts = new bytes32[](17);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.TooManyCeaAccounts.selector, 17), t);
    }

    /// The value-holding list holds 16: the CEA, one token account per listed asset (up to 8) and up to
    /// 7 swap outputs. Sixteen distinct, valid entries are accepted; the 17th is refused above.
    function test_svmInit_ceaAccountListHoldsSixteen() public {
        SvmTerms memory t = _terms();
        t.ceaAccounts = _ceaAccountsOfLength(16);
        _init(t);
        assertEq(urp.getSvmConfig(CID, ACCOUNT).ceaAccounts.length, 16, "sixteen value-holding accounts stored");
    }

    /// @dev The default three (CEA, ATA_IN, ATA_OUT) padded with distinct keys no request passes.
    function _ceaAccountsOfLength(uint256 n) internal view returns (bytes32[] memory c) {
        c = new bytes32[](n);
        c[0] = CEA;
        c[1] = ATA_IN;
        c[2] = ATA_OUT;
        for (uint256 i = 3; i < n; ++i) {
            c[i] = keccak256(abi.encode("extra value-holding account", i));
        }
    }

    function test_svmInit_expiryGuards() public {
        SvmTerms memory t = _terms();
        t.validUntil = 0;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, uint48(0)), t);

        t.validUntil = uint48(block.timestamp);
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, uint48(block.timestamp)), t
        );
    }

    function test_svmInit_identityFieldsMustBeSet() public {
        SvmTerms memory t = _terms();
        t.expectedCEA = bytes32(0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidSvmConfigField.selector), t);

        t = _terms();
        t.gatewayProgram = bytes32(0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidSvmConfigField.selector), t);

        // A zero token is no longer an identity field: it fails the per-asset teeth, named.
        t = _terms();
        t.assets[0].token = address(0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidAsset.selector, address(0)), t);
    }

    function test_svmInit_discriminatorLenGuards() public {
        SvmTerms memory t = _terms();
        t.programs[0].discriminatorLen = 0; // tagged rule with no tag
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.DiscriminatorLenOutOfRange.selector, 0, uint8(0)), t
        );

        t = _terms();
        t.programs[0].discriminatorLen = 9;
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.DiscriminatorLenOutOfRange.selector, 0, uint8(9)), t
        );

        t = _terms();
        t.programs[0].dataless = true; // dataless rule carrying a tag
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.DiscriminatorLenOutOfRange.selector, 0, uint8(8)), t
        );
    }

    /// @dev ⚠️ NEVER-DELETE. Every forbidden program is refused at GRANT, so an owner cannot be
    ///      talked into allow-listing a drain, and the gateway self-route can never become a
    ///      mandate action however the card is worded.
    function test_svmInit_forbiddenProgramsRefusedInAllowList() public {
        bytes32[8] memory forbidden = [
            exposed.systemProgram(),
            exposed.splTokenProgram(),
            exposed.token2022Program(),
            exposed.stakeProgram(),
            exposed.bpfLoaderUpgradeable(),
            exposed.addressLookupTable(),
            GATEWAY_PROG,
            CEA
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            SvmTerms memory t = _terms();
            t.programs[0].program = forbidden[i];
            _initReverts(
                abi.encodeWithSelector(
                    UniversalRulesPolicyErrors.ForbiddenProgramInAllowList.selector, 0, forbidden[i]
                ),
                t
            );
        }
    }

    function test_svmInit_gatewaySelfWithdrawDiscriminatorIsStillRefused() public {
        // The self-route is reached by targeting the gateway program with this exact tag. The
        // program check fires regardless of the tag, and it fires at init.
        SvmTerms memory t = _terms();
        t.programs[0].program = GATEWAY_PROG;
        t.programs[0].discriminator = SELF_WITHDRAW;
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenProgramInAllowList.selector, 0, GATEWAY_PROG), t
        );
    }

    function _twoRules(AllowedProgram memory second) internal view returns (SvmTerms memory t) {
        t = _terms();
        t.programs = new AllowedProgram[](2);
        t.programs[0] = _routeRule();
        t.programs[0].program = PROG;
        t.programs[1] = second;
        t.pins = new SvmAccountPin[](2);
        t.pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        t.pins[1] = SvmAccountPin({ ruleIndex: 1, accountIndex: 0, expected: CEA });
    }

    function test_svmInit_ambiguousRulesRefused() public {
        // Same program, same 8-byte tag.
        AllowedProgram memory dup = _routeRule();
        dup.program = PROG;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousRule.selector, 0, 1), _twoRules(dup));

        // Same program, a 4-byte tag that is a prefix of the 8-byte one — stored with its tail
        // zeroed, so only a PREFIX comparison sees the collision.
        AllowedProgram memory prefix = _routeRule();
        prefix.program = PROG;
        // forge-lint: disable-next-line(unsafe-typecast)
        prefix.discriminator = bytes8(bytes4(ROUTE)); // a genuine 4-byte prefix, tail zeroed on purpose
        prefix.discriminatorLen = 4;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousRule.selector, 0, 1), _twoRules(prefix));

        // The other order too: the short tag first, the long one second.
        SvmTerms memory swapped = _twoRules(prefix);
        (swapped.programs[0], swapped.programs[1]) = (swapped.programs[1], swapped.programs[0]);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousRule.selector, 0, 1), swapped);

        // Two dataless rules on one program.
        SvmTerms memory t = _twoRules(
            AllowedProgram({ program: PROG, discriminator: 0, discriminatorLen: 0, dataless: true, maxAccounts: 0 })
        );
        t.programs[0].discriminator = 0;
        t.programs[0].discriminatorLen = 0;
        t.programs[0].dataless = true;
        t.dataPins = new SvmDataPin[](0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousRule.selector, 0, 1), t);
    }

    function test_svmInit_distinctRulesOnOneProgramAccepted() public {
        // A different tag, and a dataless rule beside a tagged one, are both exact.
        AllowedProgram memory other = _routeRule();
        other.program = PROG;
        other.discriminator = OTHER_IX;
        _init(_twoRules(other));
        assertEq(urp.getSvmConfig(CID, ACCOUNT).programs.length, 2);
    }

    function test_svmInit_shortTagThatIsNotAPrefixAccepted() public {
        AllowedProgram memory short4 = _routeRule();
        short4.program = PROG;
        // forge-lint: disable-next-line(unsafe-typecast)
        short4.discriminator = bytes8(bytes4(OTHER_IX)); // 4-byte tag, tail zeroed on purpose
        short4.discriminatorLen = 4;
        _init(_twoRules(short4));
        assertEq(urp.getSvmConfig(CID, ACCOUNT).programs.length, 2);
    }

    function test_svmInit_datalessBesideTaggedIsNotAmbiguous() public {
        SvmTerms memory t = _twoRules(
            AllowedProgram({ program: PROG, discriminator: 0, discriminatorLen: 0, dataless: true, maxAccounts: 0 })
        );
        _init(t);
        assertEq(urp.getSvmConfig(CID, ACCOUNT).programs.length, 2);
    }

    function test_svmInit_accountPinGuards() public {
        SvmTerms memory t = _terms();
        t.pins[0].ruleIndex = 1;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmPinRuleOutOfRange.selector, 0, uint8(1)), t);

        t = _terms();
        t.pins[1].accountIndex = 64;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmPinIndexOutOfRange.selector, 1, uint8(64)), t);

        t = _terms();
        t.programs[0].maxAccounts = 5; // pin index 6 is beyond a fixed count of 5
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmPinIndexOutOfRange.selector, 2, uint8(6)), t);
    }

    function test_svmInit_ruleWithoutPinRefused() public {
        AllowedProgram memory other = _routeRule();
        other.program = PROG2;
        SvmTerms memory t = _twoRules(other);
        t.pins = new SvmAccountPin[](1);
        t.pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.RuleWithoutPin.selector, 1), t);
    }

    /// @dev The guard is HYGIENE: a lone authority pin is accepted. This test exists so nobody later
    ///      reads `RuleWithoutPin` as proof that value-carrying positions are pinned — that is the
    ///      compiler's job, and URP cannot check it.
    function test_svmInit_oneUselessPinIsAccepted() public {
        SvmTerms memory t = _terms();
        t.pins = new SvmAccountPin[](1);
        t.pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        _init(t);
        assertEq(urp.getSvmConfig(CID, ACCOUNT).pins.length, 1);
    }

    function test_svmInit_dataPinGuards() public {
        SvmDataPin memory base = _dataPin(SvmDataPinMode.EQ, OFF_FEE, 0, 1, bytes32(0), 0, 0);

        // Every case isolates ONE bad field; the other fields stay valid for it, so the guard under
        // test is the only one that can fire. (Offsets are widened where a longer field needs it.)
        _expectDataPinInvalid(_withRule(base, 1)); // rule out of range
        _expectDataPinInvalid(_withLen(base, 0)); // zero length
        _expectDataPinInvalid(_withOffset(_withLen(base, 33), 40)); // EQ above 32, offset fine for 33
        _expectDataPinInvalid(_withOffset(_withLen(_withMode(base, SvmDataPinMode.GTE_LE), 9), 9)); // int above 8
        _expectDataPinInvalid(_withOffset(_withLen(base, 4), 3)); // from-end offset shorter than the field
        _expectDataPinInvalid(_withOffset(base, 1025)); // from-end offset beyond the ix_data bound
        _expectDataPinInvalid(_fromStart(_withOffset(_withLen(base, 8), 1020))); // from-start overruns the bound

        SvmDataPin memory ratio =
            _dataPin(SvmDataPinMode.RATIO_GTE_LE, OFF_QUOTED_OUT, OFF_IN_AMOUNT, 8, bytes32(0), 95, 100);
        ratio.den = 0;
        _expectDataPinInvalid(ratio); // zero denominator
        ratio.den = 100;
        ratio.offsetB = 4; // second field shorter than the width
        _expectDataPinInvalid(ratio);

        // And the widened shapes are accepted when only the width changed: the guards above fired
        // for the field they name, not for a side effect of the fixture.
        SvmTerms memory ok = _terms();
        ok.dataPins = new SvmDataPin[](2);
        ok.dataPins[0] = _withOffset(_withLen(base, 32), 40);
        ok.dataPins[1] = _withOffset(_withLen(_withMode(base, SvmDataPinMode.GTE_LE), 8), 9);
        _init(ok);
    }

    function test_svmInit_dataPinOnDatalessRuleRefused() public {
        SvmTerms memory t = _terms();
        t.programs[0].discriminator = 0;
        t.programs[0].discriminatorLen = 0;
        t.programs[0].dataless = true;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataPinInvalid.selector, 0), t);
    }

    function _expectDataPinInvalid(SvmDataPin memory dp) internal {
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](1);
        t.dataPins[0] = dp;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataPinInvalid.selector, 0), t);
    }

    /// @dev Memory structs are references: a helper that edited its argument in place would leak
    ///      one case's bad field into the next and every later case would fail on the FIRST guard.
    ///      Each helper therefore edits a copy. (A mutation run caught exactly that leak.)
    function _clone(SvmDataPin memory d) internal pure returns (SvmDataPin memory c) {
        c = SvmDataPin({
            ruleIndex: d.ruleIndex,
            fromEnd: d.fromEnd,
            offset: d.offset,
            offsetB: d.offsetB,
            len: d.len,
            mode: d.mode,
            expected: d.expected,
            num: d.num,
            den: d.den
        });
    }

    function _withRule(SvmDataPin memory d, uint8 r) internal pure returns (SvmDataPin memory c) {
        c = _clone(d);
        c.ruleIndex = r;
    }

    function _withLen(SvmDataPin memory d, uint8 l) internal pure returns (SvmDataPin memory c) {
        c = _clone(d);
        c.len = l;
    }

    function _withOffset(SvmDataPin memory d, uint16 o) internal pure returns (SvmDataPin memory c) {
        c = _clone(d);
        c.offset = o;
    }

    function _withMode(SvmDataPin memory d, SvmDataPinMode m) internal pure returns (SvmDataPin memory c) {
        c = _clone(d);
        c.mode = m;
    }

    function _fromStart(SvmDataPin memory d) internal pure returns (SvmDataPin memory c) {
        c = _clone(d);
        c.fromEnd = false;
    }

    // ═════════════════════════════ check — happy paths ═════════════════════════════

    function test_svm_goodRequestPassesAndMetersSpend() public {
        _initDefault();
        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.OutboundMetered(CID, address(engine), ACCOUNT, ASSET, 50_000_000);
        assertEq(_check(0, _good(50_000_000)), VALIDATION_SUCCESS, "the engine's success sentinel");
        assertEq(_spent(), 50_000_000, "metered");
    }

    function test_svm_zeroAmountPassesAndWritesNothing() public {
        _initDefault();
        vm.recordLogs();
        _check(0, _good(0));
        assertEq(_spent(), 0, "nothing metered");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event for a payload-only request");
    }

    function test_svm_lifetimeCapAccumulates() public {
        _initDefault();
        for (uint256 i; i < 10; ++i) {
            _check(0, _good(MAX_PER_CALL));
        }
        assertEq(_spent(), MAX_TOTAL);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector, MAX_TOTAL + 1, MAX_TOTAL),
            0,
            _good(1)
        );
    }

    function test_svm_datalessRuleMatchesOnlyEmptyIxData() public {
        SvmTerms memory t = _terms();
        t.programs[0].discriminator = 0;
        t.programs[0].discriminatorLen = 0;
        t.programs[0].dataless = true;
        t.dataPins = new SvmDataPin[](0);
        _init(t);

        _check(0, _request(1, _payload("")));

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG, ROUTE),
            0,
            _request(1, _payload(_goodIx()))
        );
    }

    function test_svm_fixedAccountCountAcceptsExactCount() public {
        SvmTerms memory t = _terms();
        t.programs[0].maxAccounts = 10;
        _init(t);
        _check(0, _good(1));
    }

    function test_svm_fromStartPinsAndRawBytesEq() public {
        // A from-start EQ pin over the discriminator itself, 8 bytes, and a 32-byte raw pin over
        // the first word of ix_data — both legal shapes, both exercised.
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](2);
        t.dataPins[0] = _fromStart(_dataPin(SvmDataPinMode.EQ, 0, 0, 8, bytes32(ROUTE), 0, 0));
        bytes memory ix = _goodIx();
        bytes32 firstWord;
        assembly {
            firstWord := mload(add(ix, 0x20))
        }
        t.dataPins[1] = _fromStart(_dataPin(SvmDataPinMode.EQ, 0, 0, 32, firstWord, 0, 0));
        _init(t);
        _check(0, _good(1));
    }

    function test_svm_gteFloorPin() public {
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](1);
        t.dataPins[0] = _dataPin(SvmDataPinMode.GTE_LE, OFF_QUOTED_OUT, 0, 8, bytes32(uint256(49_000_000)), 0, 0);
        _init(t);
        _check(0, _good(1));

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataFloorNotMet.selector, 0, 48_999_999, 49_000_000),
            0,
            _request(1, _payload(_ixData(50_000_000, 48_999_999, 30, 0)))
        );
    }

    /// @dev ⚠️ NEVER-DELETE. S18 cannot be switched off: an empty list, or one without the CEA, is
    ///      refused at grant. (Before review R-06 an empty list silently disabled the aliasing
    ///      defence; the test that pinned that behaviour was replaced by this one.)
    function test_svmInit_ceaAccountsMustContainTheCea() public {
        SvmTerms memory t = _terms();
        t.ceaAccounts = new bytes32[](0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountsMissExpectedCEA.selector), t);

        t = _terms();
        t.ceaAccounts = new bytes32[](2);
        t.ceaAccounts[0] = ATA_IN;
        t.ceaAccounts[1] = ATA_OUT;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountsMissExpectedCEA.selector), t);

        // The CEA alone is the minimal legal list.
        t = _terms();
        t.ceaAccounts = new bytes32[](1);
        t.ceaAccounts[0] = CEA;
        _init(t);
        assertEq(urp.getSvmConfig(CID, ACCOUNT).ceaAccounts.length, 1);
    }

    function test_svmInit_ceaAccountEntriesValidated() public {
        // Zero: the System program's id, present in most account lists.
        SvmTerms memory t = _terms();
        t.ceaAccounts[1] = bytes32(0);
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidCeaAccount.selector, 1), t);

        // Duplicate.
        t = _terms();
        t.ceaAccounts[2] = ATA_IN;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidCeaAccount.selector, 2), t);

        // An allow-listed program's own id.
        t = _terms();
        t.ceaAccounts[2] = PROG;
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidCeaAccount.selector, 2), t);
    }

    function test_svmInit_duplicatePinRefused() public {
        SvmTerms memory t = _terms();
        t.pins[3] = SvmAccountPin({ ruleIndex: 0, accountIndex: 3, expected: ATA_OUT }); // contradicts pin 1
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.DuplicateSvmPin.selector, 1, 3), t);

        t = _terms();
        t.pins[3] = SvmAccountPin({ ruleIndex: 0, accountIndex: 3, expected: ATA_IN }); // repeats pin 1
        _initReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.DuplicateSvmPin.selector, 1, 3), t);

        // The same index under DIFFERENT rules is not a duplicate.
        AllowedProgram memory other = _routeRule();
        other.program = PROG2;
        t = _twoRules(other);
        t.pins = new SvmAccountPin[](2);
        t.pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        t.pins[1] = SvmAccountPin({ ruleIndex: 1, accountIndex: 2, expected: CEA });
        _init(t);
    }

    /// @dev Review R-02: a fixed count above the S13 bound is a rule no request can satisfy.
    function test_svmInit_maxAccountsAboveTheBoundRefused() public {
        SvmTerms memory t = _terms();
        t.programs[0].maxAccounts = 65;
        _initReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmMaxAccountsOutOfRange.selector, 0, uint8(65)), t
        );

        t.programs[0].maxAccounts = 64; // at the bound: legal
        _init(t);
    }

    /// @dev ⚠️ NEVER-DELETE. Review R-01: comparison values the field cannot be compared against.
    ///      The ceiling case is the dangerous one — before the guard it was accepted and NEVER failed
    ///      (E1: a u16 ceiling of 70,000 let 65,535 bps of slippage through; E2: a ratio with
    ///      num = 0 let a zero quoted output through). Both are now refused at grant.
    function test_svmInit_vacuousOrImpossibleDataPinValuesRefused() public {
        // E1 — LTE above the u16 range.
        _expectDataPinInvalid(_dataPin(SvmDataPinMode.LTE_LE, OFF_SLIPPAGE, 0, 2, bytes32(uint256(70_000)), 0, 0));
        // GTE above the u64 range — a floor that can never be met.
        _expectDataPinInvalid(_dataPin(SvmDataPinMode.GTE_LE, OFF_QUOTED_OUT, 0, 8, bytes32(uint256(1) << 64), 0, 0));
        // E2 — RATIO with num = 0.
        _expectDataPinInvalid(
            _dataPin(SvmDataPinMode.RATIO_GTE_LE, OFF_QUOTED_OUT, OFF_IN_AMOUNT, 8, bytes32(0), 0, 100)
        );
        // EQ given a RIGHT-aligned integer (the integer modes' encoding): bytes past `len` are set.
        _expectDataPinInvalid(_dataPin(SvmDataPinMode.EQ, OFF_SLIPPAGE, 0, 2, bytes32(uint256(50)), 0, 0));

        // The boundaries are legal: the largest value each width can hold, and a left-aligned EQ.
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](3);
        t.dataPins[0] = _dataPin(SvmDataPinMode.LTE_LE, OFF_SLIPPAGE, 0, 2, bytes32(uint256(type(uint16).max)), 0, 0);
        t.dataPins[1] = _dataPin(SvmDataPinMode.GTE_LE, OFF_QUOTED_OUT, 0, 8, bytes32(uint256(type(uint64).max)), 0, 0);
        t.dataPins[2] = _dataPin(SvmDataPinMode.EQ, OFF_SLIPPAGE, 0, 2, bytes32(bytes2(0x1e00)), 0, 0); // 30 LE
        _init(t);
    }

    function test_svm_leftAlignedEqPinMatchesTheLittleEndianField() public {
        // 30 bps encoded as Borsh u16 is 0x1e 0x00; the EQ value is those bytes, left-aligned.
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](1);
        t.dataPins[0] = _dataPin(SvmDataPinMode.EQ, OFF_SLIPPAGE, 0, 2, bytes32(bytes2(0x1e00)), 0, 0);
        _init(t);
        _check(0, _good(1)); // _goodIx carries 30 bps

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmDataPinMismatch.selector,
                0,
                bytes32(bytes2(0x1e00)),
                bytes32(bytes2(0x1f00))
            ),
            0,
            _request(1, _payload(_ixData(50_000_000, 49_000_000, 31, 0)))
        );
    }

    // ═════════════════════════════ check — S1 to S10 ═════════════════════════════

    function test_svm_S2_expired() public {
        _initDefault();
        vm.warp(uint256(VALID_UNTIL) + 1);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RulesExpired.selector, VALID_UNTIL), 0, _good(1)
        );
    }

    function test_svm_S3_wrongTarget() public {
        _initDefault();
        address other = makeAddr("not the gateway");
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidTarget.selector, other));
        urp.checkAction(CID, ACCOUNT, other, 0, _good(1));
    }

    function test_svm_S4_calldataShape() public {
        _initDefault();
        _checkReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.CalldataTooShort.selector, 3), 0, hex"aabbcc");

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidSelector.selector, bytes4(0xdeadbeef)),
            0,
            abi.encodePacked(bytes4(0xdeadbeef), new bytes(400))
        );

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.MalformedOutboundRequest.selector, 4 + MIN_OUTBOUND_BODY_LEN - 1
            ),
            0,
            abi.encodePacked(SEND_OUTBOUND_SELECTOR, new bytes(MIN_OUTBOUND_BODY_LEN - 1))
        );
    }

    function test_svm_S5_assetMismatch() public {
        _initDefault();
        address other = makeAddr("other token");
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AssetNotAllowed.selector, other),
            0,
            svmOutboundRequest(other, 1, 1 ether, ACCOUNT, abi.encodePacked(PROG), _payload(_goodIx()))
        );
    }

    function test_svm_S6_perCallCap() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.AmountExceedsCap.selector, MAX_PER_CALL + 1, MAX_PER_CALL
            ),
            0,
            _good(MAX_PER_CALL + 1)
        );
    }

    function test_svm_S6b_amountAboveU64() public {
        SvmTerms memory t = _terms();
        t.assets[0].maxPerCall = type(uint256).max;
        t.assets[0].maxTotal = type(uint256).max;
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsU64.selector, uint256(type(uint64).max) + 1),
            0,
            _good(uint256(type(uint64).max) + 1)
        );

        _check(0, _good(type(uint64).max)); // the last representable lamport count passes
        assertEq(_spent(), type(uint64).max);
    }

    function test_svm_S8_pcValueCap() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.PCValueExceedsCap.selector, MAX_PC + 1, MAX_PC),
            MAX_PC + 1,
            _good(1)
        );
    }

    function test_svm_S9_uncappedGasSwap() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.UncappedGasSwapRejected.selector),
            0,
            svmOutboundRequest(ASSET, 1, 0, ACCOUNT, abi.encodePacked(PROG), _payload(_goodIx()))
        );
    }

    function test_svm_S10_revertRecipient() public {
        _initDefault();
        address other = makeAddr("someone else");
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidRevertRecipient.selector, ACCOUNT, other),
            0,
            svmOutboundRequest(ASSET, 1, 1 ether, other, abi.encodePacked(PROG), _payload(_goodIx()))
        );
    }

    // ═════════════════════════════ check — S11 to S18 ═════════════════════════════

    function _withRecipient(bytes memory recipient) internal view returns (bytes memory) {
        return svmOutboundRequest(ASSET, 1, 1 ether, ACCOUNT, recipient, _payload(_goodIx()));
    }

    function test_svm_S11_recipientShapes() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientNotPubkey.selector, 0), 0, _withRecipient("")
        );

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientNotPubkey.selector, 20),
            0,
            _withRecipient(abi.encodePacked(ACCOUNT))
        );

        // A base58 string is how humans write a pubkey; the wire carries 32 raw bytes. 44 ASCII
        // bytes fail closed on length, before anything is interpreted.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientNotPubkey.selector, 44),
            0,
            _withRecipient(bytes("JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4x"))
        );

        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientNotPubkey.selector, 32),
            0,
            _withRecipient(abi.encodePacked(bytes32(0)))
        );
    }

    function test_svm_S12_emptyPayloadIsNotAWithdraw() public {
        _initDefault();
        _checkReverts(abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmPayloadEmpty.selector), 0, _request(1, ""));
    }

    function test_svm_S12_malformedPayloadCodes() public {
        _initDefault();
        // 1: shorter than the minimum 41 bytes.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedSvmPayload.selector, uint8(1)),
            0,
            _request(1, new bytes(40))
        );

        // 2: count says three accounts, only one is present.
        bytes memory p = abi.encodePacked(uint32(3), CEA, uint8(1), uint32(0), uint8(2), PROG);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedSvmPayload.selector, uint8(2)), 0, _request(1, p)
        );

        // 3: ix_data length claims more bytes than follow.
        p = abi.encodePacked(uint32(1), CEA, uint8(1), uint32(100), uint8(2), PROG);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedSvmPayload.selector, uint8(3)), 0, _request(1, p)
        );

        // 4: one trailing byte — the node rejects it, so URP does.
        p = abi.encodePacked(_payload(_goodIx()), uint8(0));
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedSvmPayload.selector, uint8(4)), 0, _request(1, p)
        );
    }

    function test_svm_S13_withdrawInstructionRefused() public {
        _initDefault();
        // The node's withdraw shape: no accounts, no data, id 1. Never a mandate action.
        bytes memory p = svmExecutePayload(new bytes32[](0), new bool[](0), "", 1, PROG);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmInstructionNotExecute.selector, uint8(1)),
            0,
            _request(1, p)
        );
    }

    function test_svm_S13_bounds() public {
        _initDefault();
        bytes32[] memory a = new bytes32[](65);
        bool[] memory w = new bool[](65);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountsOutOfRange.selector, 65),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );

        (bytes32[] memory a10, bool[] memory w10) = _accounts();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmIxDataTooLong.selector, 1025),
            0,
            _request(1, svmExecutePayload(a10, w10, new bytes(1025), 2, PROG))
        );
    }

    function test_svm_S14_recipientMustEqualPayloadTarget() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientTargetMismatch.selector, PROG2, PROG),
            0,
            svmOutboundRequest(ASSET, 1, 1 ether, ACCOUNT, abi.encodePacked(PROG2), _payload(_goodIx()))
        );
    }

    /// @dev ⚠️ NEVER-DELETE. The forbidden set at CHECK time, independent of the allow-list: even a
    ///      config that somehow carried one of these could not execute it. The gateway program is
    ///      the CEA→UEA self-route; the rest hand a program the CEA's signature over its own funds.
    function test_svm_S15_forbiddenTargets() public {
        _initDefault();
        bytes32[8] memory forbidden = [
            exposed.systemProgram(),
            exposed.splTokenProgram(),
            exposed.token2022Program(),
            exposed.stakeProgram(),
            exposed.bpfLoaderUpgradeable(),
            exposed.addressLookupTable(),
            GATEWAY_PROG,
            CEA
        ];
        (bytes32[] memory a, bool[] memory w) = _accounts();
        for (uint256 i; i < forbidden.length; ++i) {
            bytes memory p = svmExecutePayload(a, w, _goodIx(), 2, forbidden[i]);
            // The System program is the all-zero pubkey: S11 refuses it as a recipient before S15
            // ever sees it as a target. Either way it cannot be named.
            bytes memory err = forbidden[i] == bytes32(0)
                ? abi.encodeWithSelector(UniversalRulesPolicyErrors.RecipientNotPubkey.selector, 32)
                : abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenTargetProgram.selector, forbidden[i]);
            _checkReverts(err, 0, svmOutboundRequest(ASSET, 1, 1 ether, ACCOUNT, abi.encodePacked(forbidden[i]), p));
        }
    }

    function test_svm_S16_programNotAllowed() public {
        _initDefault();
        (bytes32[] memory a, bool[] memory w) = _accounts();

        // Unknown program.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG2, ROUTE),
            0,
            svmOutboundRequest(
                ASSET, 1, 1 ether, ACCOUNT, abi.encodePacked(PROG2), svmExecutePayload(a, w, _goodIx(), 2, PROG2)
            )
        );

        // Right program, a sibling instruction's tag.
        bytes memory sibling = abi.encodePacked(OTHER_IX, _goodIx());
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG, OTHER_IX),
            0,
            _request(1, _payload(sibling))
        );

        // ix_data shorter than the tag: reported masked to what was there. (Deliberate truncations.)
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes3 threeBytes = bytes3(ROUTE);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG, bytes8(threeBytes)),
            0,
            _request(1, _payload(abi.encodePacked(threeBytes)))
        );

        // Empty ix_data against a tagged rule.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG, bytes8(0)),
            0,
            _request(1, _payload(""))
        );
    }

    function test_svm_S16_fixedAccountCountMismatch() public {
        SvmTerms memory t = _terms();
        t.programs[0].maxAccounts = 10;
        _init(t);
        (bytes32[] memory a, bool[] memory w) = _accounts();
        bytes32[] memory a11 = new bytes32[](11);
        bool[] memory w11 = new bool[](11);
        for (uint256 i; i < 10; ++i) {
            a11[i] = a[i];
            w11[i] = w[i];
        }
        a11[10] = ATTACKER;
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountCountMismatch.selector, 11, uint8(10)),
            0,
            _request(1, svmExecutePayload(a11, w11, _goodIx(), 2, PROG))
        );
    }

    function test_svm_S17_accountPinBelowCount() public {
        _initDefault();
        // Exactly as many accounts as the highest pinned index: the pin names index 6, the list
        // ends at 5. The boundary case, so an off-by-one in the count check cannot hide.
        bytes32[] memory six = new bytes32[](6);
        bool[] memory sixW = new bool[](6);
        six[2] = CEA;
        six[3] = ATA_IN;
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountCountBelowPin.selector, 2, 6, uint8(6)),
            0,
            _request(1, svmExecutePayload(six, sixW, _goodIx(), 2, PROG))
        );

        bytes32[] memory a = new bytes32[](4);
        bool[] memory w = new bool[](4);
        a[2] = CEA;
        a[3] = ATA_IN;
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmAccountCountBelowPin.selector, 2, 4, uint8(6)),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );
    }

    /// @dev ⚠️ NEVER-DELETE. The beneficiary pin of the SVM rulebook: the destination token account
    ///      is where the swap's output lands, and it must be the CEA's.
    function test_svm_S17_destinationRedirectedRefused() public {
        _initDefault();
        (bytes32[] memory a, bool[] memory w) = _accounts();
        a[6] = ATTACKER;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmAccountPinMismatch.selector, 2, uint8(6), ATA_OUT, ATTACKER
            ),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );
    }

    function test_svm_S17_sourceSubstitutionRefused() public {
        // The CEA's ATA for a DIFFERENT mint as the source: the agent spending capital outside the
        // mandated asset. The source pin is what stops it.
        _initDefault();
        (bytes32[] memory a, bool[] memory w) = _accounts();
        a[3] = ATA_OUT;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmAccountPinMismatch.selector, 1, uint8(3), ATA_IN, ATA_OUT
            ),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );
    }

    function test_svm_S17_feeFieldPinned() public {
        _initDefault();
        bytes32 want = bytes32(0);
        bytes32 actual = bytes32(uint256(5) << 248);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataPinMismatch.selector, 0, want, actual),
            0,
            _request(1, _payload(_ixData(50_000_000, 49_000_000, 30, 5)))
        );
    }

    function test_svm_S17_slippageCeiling() public {
        _initDefault();
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataCeilingExceeded.selector, 1, 51, 50),
            0,
            _request(1, _payload(_ixData(50_000_000, 49_000_000, 51, 0)))
        );

        _check(0, _request(1, _payload(_ixData(50_000_000, 49_000_000, 50, 0)))); // at the ceiling
    }

    /// @dev ⚠️ NEVER-DELETE. The floor is RELATIVE to the input. A static floor on the output is
    ///      bypassed by an input equal to the whole balance; the ratio is not.
    function test_svm_S17_ratioFloorRelativeToInput() public {
        _initDefault();
        // 49 out for 50 in passes (98%); 49 out for 100 in does not (49%), though 49 would clear
        // any static floor set for a 50-unit swap.
        _check(0, _request(1, _payload(_ixData(50_000_000, 49_000_000, 30, 0))));

        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmDataRatioNotMet.selector,
                2,
                49_000_000,
                100_000_000,
                uint64(95),
                uint64(100)
            ),
            0,
            _request(1, _payload(_ixData(100_000_000, 49_000_000, 30, 0)))
        );

        // Exactly on the line: 95 out for 100 in.
        _check(0, _request(1, _payload(_ixData(100_000_000, 95_000_000, 30, 0))));
    }

    function test_svm_S17_dataTooShortForPin() public {
        _initDefault();
        // The tag plus three zero bytes: the fee and slippage pins read zeros and pass; the ratio
        // pin reaches 19 back into 11 bytes and cannot.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataTooShortForPin.selector, 2, 11),
            0,
            _request(1, _payload(abi.encodePacked(ROUTE, uint8(0), uint8(0), uint8(0))))
        );
    }

    function test_svm_S17_fromEndDataTooShortByOne() public {
        // A from-end pin that reaches exactly one byte past what the tag-only ix_data holds.
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](1);
        // Nine back from the end of a nine-byte ix_data is byte 0 — the tag's first byte.
        t.dataPins[0] = _dataPin(SvmDataPinMode.EQ, 9, 0, 1, bytes32(ROUTE) & bytes32(bytes1(0xff)), 0, 0);
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataTooShortForPin.selector, 0, 8),
            0,
            _request(1, _payload(abi.encodePacked(ROUTE)))
        );
        // One more byte and the pin reaches byte 0, which is the tag's first byte, and passes.
        _check(0, _request(1, _payload(abi.encodePacked(ROUTE, uint8(0)))));
    }

    function test_svm_S17_fromStartDataTooShort() public {
        SvmTerms memory t = _terms();
        t.dataPins = new SvmDataPin[](1);
        t.dataPins[0] = _fromStart(_dataPin(SvmDataPinMode.EQ, 8, 0, 8, bytes32(0), 0, 0));
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataTooShortForPin.selector, 0, 8),
            0,
            _request(1, _payload(abi.encodePacked(ROUTE)))
        );
        // The boundary: fifteen bytes for a field that ends at sixteen.
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.SvmDataTooShortForPin.selector, 0, 15),
            0,
            _request(1, _payload(abi.encodePacked(ROUTE, bytes7(0))))
        );
        // Sixteen, and the field is read: eight zero bytes, which is what the pin expects.
        _check(0, _request(1, _payload(abi.encodePacked(ROUTE, bytes8(0)))));
    }

    function test_svm_S16_shortIxDataNeverReadsPastItself() public {
        // A tag whose last byte equals the execute instruction id (2). If the tag check read past a
        // 7-byte ix_data it would find that id byte in the trailer and "match". It must not.
        SvmTerms memory t = _terms();
        t.programs[0].discriminator = 0xaabbccddeeff0102;
        t.dataPins = new SvmDataPin[](0);
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.ProgramNotAllowed.selector, PROG, bytes8(0xaabbccddeeff0100)
            ),
            0,
            _request(1, _payload(hex"aabbccddeeff01"))
        );
    }

    /// @dev ⚠️ NEVER-DELETE. The closed-set rule: a CEA-controlled account handed to the program at
    ///      a position the rule does not pin is a balance the program was not granted.
    function test_svm_S18_ceaAccountAtUnpinnedIndexRefused() public {
        _initDefault();
        (bytes32[] memory a, bool[] memory w) = _accounts();

        a[4] = ATA_IN; // the source ATA smuggled in at an unpinned position
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex.selector, 4, ATA_IN),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );

        (a, w) = _accounts();
        a[0] = CEA; // the CEA itself, a second time, where the token program should be
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex.selector, 0, CEA),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );

        (a, w) = _accounts();
        a[5] = ATA_OUT; // the destination ATA at an unpinned position, though pinned at 6 and 9
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex.selector, 5, ATA_OUT),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );
    }

    function test_svm_S18_unpinnedFeeAccountIsWhatTheRuleCatches() public {
        // ATA_OUT appears twice in the request — at 6 and at 9 (the fee account). With only the
        // first three pins the fee position is unpinned, and S18 refuses the CEA's own ATA there.
        // The default fixture pins index 9 too, which is what a complete compiler output looks like.
        SvmTerms memory t = _terms();
        t.pins = new SvmAccountPin[](3);
        t.pins[0] = SvmAccountPin({ ruleIndex: 0, accountIndex: 2, expected: CEA });
        t.pins[1] = SvmAccountPin({ ruleIndex: 0, accountIndex: 3, expected: ATA_IN });
        t.pins[2] = SvmAccountPin({ ruleIndex: 0, accountIndex: 6, expected: ATA_OUT });
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CeaAccountAtUnpinnedIndex.selector, 9, ATA_OUT),
            0,
            _good(1)
        );
    }

    // ═════════════════════════════ getters, assertions, refunds ═════════════════════════════

    function test_svm_gettersRouteByFamily() public {
        _initDefault();
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongVmForCall.selector, VmFamily.SVM));
        urp.getConfig(CID, ACCOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongModeForCall.selector, RulesType.UNIVERSAL)
        );
        urp.getNativeConfig(CID, ACCOUNT);

        assertTrue(urp.getSvmConfig(CID, ACCOUNT).initialized);
    }

    function test_svm_getSvmConfigOnNativeSlotReverts() public {
        ArgPin[] memory pins = new ArgPin[](0);
        NativeConfig memory n = NativeConfig({
            initialized: false,
            validUntil: VALID_UNTIL,
            target: makeAddr("nativeTarget"),
            selector: 0x11111111,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: pins
        });
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(n));

        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongModeForCall.selector, RulesType.NATIVE));
        urp.getSvmConfig(CID, ACCOUNT);
    }

    function test_svm_getSvmConfigOnEmptySlotIsZeroed() public view {
        SvmConfig memory c = urp.getSvmConfig(CID, ACCOUNT);
        assertFalse(c.initialized);
        assertEq(c.programs.length, 0);
    }

    function test_svm_assertSpentReadsTheSvmCounter() public {
        _initDefault();
        _check(0, _good(7));
        urp.assertSpent(CID, ACCOUNT, oneSpent(7));

        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AssetSpentMismatch.selector, ASSET, 8, 7));
        urp.assertSpent(CID, ACCOUNT, oneSpent(8));
    }

    function test_svm_creditRevertCreditsTheSvmCounter() public {
        _initDefault();
        _check(0, _good(40));
        bytes32 txId = keccak256("failed outbound");

        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, address(this)));
        urp.creditRevert(CID, ACCOUNT, txId, ASSET, 10);

        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.RevertCredited(txId, CID, ACCOUNT, ASSET, 10);
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, txId, ASSET, 10);
        assertEq(_spent(), 30);

        vm.prank(EXECUTOR_MODULE);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyCredited.selector, txId));
        urp.creditRevert(CID, ACCOUNT, txId, ASSET, 10);

        // Saturating: a claim above the counter applies the counter, and says so.
        bytes32 txId2 = keccak256("another failed outbound");
        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.RevertCredited(txId2, CID, ACCOUNT, ASSET, 30);
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, txId2, ASSET, 1_000);
        assertEq(_spent(), 0);
        assertTrue(urp.isCredited(txId2));
    }

    // ═════════════════════════════ constants and the library ═════════════════════════════

    /// @dev ⚠️ NEVER-DELETE. The hex words in URP are pinned against the base58 ids the Solana
    ///      ecosystem publishes, decoded here by an independent routine. A typo in either fails.
    function test_svm_forbiddenProgramConstantsMatchBase58() public view {
        assertEq(exposed.systemProgram(), base58ToBytes32("11111111111111111111111111111111"), "System");
        assertEq(exposed.splTokenProgram(), base58ToBytes32("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"), "SPL Token");
        assertEq(
            exposed.token2022Program(), base58ToBytes32("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"), "Token-2022"
        );
        assertEq(exposed.stakeProgram(), base58ToBytes32("Stake11111111111111111111111111111111111111"), "Stake");
        assertEq(
            exposed.bpfLoaderUpgradeable(),
            base58ToBytes32("BPFLoaderUpgradeab1e11111111111111111111111"),
            "BPF Loader Upgradeable"
        );
        assertEq(
            exposed.addressLookupTable(),
            base58ToBytes32("AddressLookupTab1e1111111111111111111111111"),
            "Address Lookup Table"
        );
        // And the decoder itself against a value that is not all-zero: SPL Token's well-known hex.
        assertEq(
            base58ToBytes32("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"),
            0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9
        );
    }

    /// @dev The fixture's literal tags are the Anchor discriminators they claim to be.
    function test_fixture_discriminatorsAreTheAnchorTags() public pure {
        assertEq(ROUTE, bytes8(sha256("global:shared_accounts_route")));
        assertEq(OTHER_IX, bytes8(sha256("global:route_with_token_ledger")));
        assertEq(SELF_WITHDRAW, bytes8(sha256("global:send_universal_tx_to_uea")));
    }

    function test_deriveVm_classifiesOnThePrefix() public view {
        assertEq(uint8(lib.deriveVm("eip155:1")), uint8(VmFamily.EVM));
        assertEq(uint8(lib.deriveVm("eip155:11155111")), uint8(VmFamily.EVM));
        assertEq(uint8(lib.deriveVm(CHAIN_SOLANA_DEVNET)), uint8(VmFamily.SVM));
        assertEq(uint8(lib.deriveVm("solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp")), uint8(VmFamily.SVM));
    }

    function test_deriveVm_refusesEverythingElse() public {
        string[6] memory bad = ["", "eip155", "eip155:", "solana:", "EIP155:1", "cosmos:cosmoshub-4"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(PushChainLib.UnsupportedNamespace.selector, keccak256(bytes(bad[i])))
            );
            lib.deriveVm(bad[i]);
        }
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    /// @dev The ratio pin, as a property: passes iff quoted_out × 100 >= in_amount × 95.
    function testFuzz_svm_ratioPin(uint64 inAmount, uint64 quotedOut) public {
        _initDefault();
        bytes memory data = _request(1, _payload(_ixData(inAmount, quotedOut, 30, 0)));
        bool ok = uint256(quotedOut) * 100 >= uint256(inAmount) * 95;
        if (ok) {
            _check(0, data);
            return;
        }
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmDataRatioNotMet.selector,
                2,
                uint256(quotedOut),
                uint256(inAmount),
                uint64(95),
                uint64(100)
            ),
            0,
            data
        );
    }

    /// @dev Every amount above u64 is refused before any Solana-side truncation could happen.
    function testFuzz_svm_amountsAboveU64Refused(uint256 amount) public {
        amount = bound(amount, uint256(type(uint64).max) + 1, type(uint256).max);
        SvmTerms memory t = _terms();
        t.assets[0].maxPerCall = type(uint256).max;
        t.assets[0].maxTotal = type(uint256).max;
        _init(t);
        _checkReverts(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsU64.selector, amount), 0, _good(amount)
        );
    }

    /// @dev Any single substituted pinned position is caught, whichever pin it is.
    function testFuzz_svm_anyPinnedPositionSubstituted(uint8 which, bytes32 stranger) public {
        which = uint8(bound(which, 0, 2));
        vm.assume(stranger != CEA && stranger != ATA_IN && stranger != ATA_OUT);
        _initDefault();
        (bytes32[] memory a, bool[] memory w) = _accounts();
        uint8[3] memory idx = [2, 3, 6];
        bytes32[3] memory expected = [CEA, ATA_IN, ATA_OUT];
        a[idx[which]] = stranger;
        _checkReverts(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmAccountPinMismatch.selector,
                uint256(which),
                idx[which],
                expected[which],
                stranger
            ),
            0,
            _request(1, svmExecutePayload(a, w, _goodIx(), 2, PROG))
        );
    }

    // ═════════════════════════════ through the wallet ═════════════════════════════
    //
    // The wallet is unchanged by the third rulebook. These prove it: a `solana:` grant goes
    // through `grantRules` untouched, lands as an SVM config, and the agent door reaches the
    // gateway with a valid Solana request — while a violating one surfaces as the engine's
    // `PolicyCheckReverted` carrying the URP gate.

    struct Agent {
        AGW wallet;
        address owner;
        address signer;
        bytes32 pid;
    }

    function _agentWithSolanaMandate() internal returns (Agent memory ag) {
        ag.owner = makeAddr("solanaWalletOwner");
        (ag.signer,) = ecdsaKey("solanaAgentSigner");
        ag.wallet = newWallet(ag.owner);
        vm.deal(address(ag.wallet), 100 ether);
        Session memory session = canonicalSession(agentConfig(ag.signer), svmInitData(CHAIN_SOLANA_DEVNET, _terms()));
        vm.prank(ag.owner);
        ag.pid = ag.wallet.grantRules(session);
    }

    function _walletConfigId(Agent memory ag) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        bytes32 actionPolicyId = keccak256(abi.encodePacked(ag.pid, actionId));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(ag.wallet), actionPolicyId)));
    }

    function _agentRequest(Agent memory ag, bytes memory ixData)
        internal
        view
        returns (bytes memory executionCalldata)
    {
        bytes memory req = svmOutboundRequest(
            ASSET, 10, 1 ether, address(ag.wallet), abi.encodePacked(PROG), _payload(ixData)
        );
        return ExecutionLib.encodeSingle(GATEWAY, 0, req);
    }

    /// @dev The agent itself calls the agent door: it is the sender the wallet checks.
    function _submit(Agent memory ag, bytes memory executionCalldata) internal {
        vm.prank(ag.signer);
        ag.wallet.executeAsAgent(ag.pid, ModeCode.unwrap(ModeLib.encodeSimpleSingle()), executionCalldata);
    }

    function test_svm_wallet_grantLandsAsSvmConfigWithNoWalletChange() public {
        Agent memory ag = _agentWithSolanaMandate();
        ConfigId id = _walletConfigId(ag);
        ModeSlot memory m = urp.getMode(id, address(ag.wallet));
        assertTrue(m.initialized);
        assertEq(uint8(m.mode), uint8(RulesType.UNIVERSAL));
        assertEq(uint8(m.vm), uint8(VmFamily.SVM));
        assertEq(urp.getSvmConfig(id, address(ag.wallet)).expectedCEA, CEA);
    }

    function test_svm_wallet_unsupportedNamespaceGrantFailsNamed() public {
        address owner_ = makeAddr("cosmosOwner");
        (address signer,) = ecdsaKey("cosmosSigner");
        AGW w = newWallet(owner_);
        string memory chain = "cosmos:cosmoshub-4";
        Session memory session = canonicalSession(agentConfig(signer), svmInitData(chain, _terms()));
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(PushChainLib.UnsupportedNamespace.selector, keccak256(bytes(chain))));
        w.grantRules(session);
    }

    function test_svm_wallet_validRequestReachesTheGateway() public {
        Agent memory ag = _agentWithSolanaMandate();
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));

        _submit(ag, _agentRequest(ag, _goodIx()));

        assertEq(callsRecorded(GATEWAY), 1, "the outbound reached the gateway");
        assertEq(
            urp.getSvmConfig(_walletConfigId(ag), address(ag.wallet)).assets[0].spent, 10, "metered through the engine"
        );
    }

    function test_svm_wallet_violationSurfacesAsTheUrpGate() public {
        Agent memory ag = _agentWithSolanaMandate();
        etchCallRecorder(GATEWAY);
        vm.store(GATEWAY, bytes32(uint256(0)), bytes32(0));

        // A 5 bps platform fee: the EQ data pin fires inside the engine's policy check.
        bytes memory executionCalldata = _agentRequest(ag, _ixData(50_000_000, 49_000_000, 30, 5));
        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SvmDataPinMismatch.selector, 0, bytes32(0), bytes32(uint256(5) << 248)
            )
        );
        _submit(ag, executionCalldata);

        assertNoCallsTo(GATEWAY);
        assertEq(urp.getSvmConfig(_walletConfigId(ag), address(ag.wallet)).assets[0].spent, 0, "nothing metered");
    }
}
