// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { MandateType } from "../../src/libraries/PushWalletTypes.sol";
import { MockUniversalGateway, MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { StakeDummy } from "../mocks/StakeDummy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { IPushAgentWallet } from "../../src/interfaces/IPushAgentWallet.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";

import {
    PermissionId,
    ConfigId,
    SmartSessionMode,
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";

/**
 * @notice E2E — Bob lends 100 USDC. The flow document's stages 3, 5, 7 and 7b, end to end, against
 *         the real engine, the real URP, the real validator, the real wallet and the real factory.
 *
 * @dev    THE ONLY MOCK IS THE GATEWAY, and it is an OBSERVER: it records the exact bytes it
 *         received and decides nothing. Every judgement about whether a request is legal is made
 *         upstream by URP and the wallet.
 *
 * @dev    WHAT THIS DOES NOT PROVE: stages 2, 4 and 6 are off-chain or far-chain (the Ethereum
 *         lock, the agent's research, the TSS settlement). They have no contract in the v3 set.
 *         The fund ledger below therefore starts at "100 pUSDC has arrived on Push Chain".
 *
 * @dev    THE FUND LEDGER IS PARTLY AUTHORED BY THIS TEST, and should not be read as end-to-end
 *         fund verification. The real gateway burns the bridged PRC20; the mock only RECORDS, so
 *         the burn below is performed by the test to keep the ledger observable. What is genuinely
 *         verified on the money path is narrower and stated where it happens: the exact validated
 *         bytes reached the gateway, `msg.sender` was the wallet, and URP's counter moved by
 *         exactly the bridged amount.
 */
contract E2ETest is BaseTest {
    MockUniversalGateway internal gateway;
    MockPRC20 internal pUSDC;

    PushAgentWallet internal bobAgw;
    address internal BOB_UEA;

    /// @dev `0xbobagwcea` — the wallet's destination-chain hand. Derived at grant in production;
    ///      a fixed address here, because deriving it is Push core's job, not this repo's.
    address internal BOB_AGW_CEA;

    /// @dev A Morpho-Blue-shaped target. Never called in this repo — only named in the allow-list.
    address internal MORPHO_BLUE;

    /// @dev `supply(address,uint256,address,uint16)` — the beneficiary is argument 3, so the word
    ///      sits at 4 (selector) + 32 (asset) + 32 (amount) = offset 68.
    bytes4 internal constant SUPPLY_SELECTOR = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    uint16 internal constant BENEFICIARY_OFFSET = 68;

    uint256 internal constant HUNDRED_USDC = 100e6;

    address internal agentAddr;
    uint256 internal agentPk;

    bytes32 internal permissionId;

    function setUp() public override {
        super.setUp();

        // The gateway mock lives AT the address the wallet and URP were wired to, so no contract
        // is rewired for the test — the production wiring is exercised as-is.
        vm.etch(GATEWAY, type(MockUniversalGateway).runtimeCode);
        gateway = MockUniversalGateway(payable(GATEWAY));

        pUSDC = new MockPRC20();
        BOB_UEA = makeAddr("0xbobuea");
        BOB_AGW_CEA = makeAddr("0xbobagwcea");
        MORPHO_BLUE = makeAddr("morphoBlue");
        (agentAddr, agentPk) = ecdsaKey("0xagentkey");

        vm.warp(1_700_000_000);
    }

    // ───────────────────────────── mandate fixtures ─────────────────────────────

    /// @dev The mandate of the flow document, verbatim: one asset, 100e6 per call and lifetime,
    ///      one Morpho-shaped rule with the beneficiary pinned to the CEA, 30-day expiry.
    function _urpConfig() internal view returns (bytes memory) {
        IURP.AllowedCall[] memory rules = new IURP.AllowedCall[](1);
        rules[0] = IURP.AllowedCall({
            target: MORPHO_BLUE,
            selector: SUPPLY_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0 // supply() is non-payable on the far chain
        });

        return universalInitData(
            IURP.Config({
                initialized: false,
                validUntil: uint48(block.timestamp + 30 days),
                destChainHash: keccak256("eip155:1"),
                expectedCEA: BOB_AGW_CEA,
                asset: address(pUSDC),
                maxAmountPerCall: HUNDRED_USDC,
                maxAmountTotal: HUNDRED_USDC,
                maxPCPerCall: 1 ether,
                spent: 0,
                allowedCalls: rules
            })
        );
    }

    /// @dev The far-chain instruction list: supply 100 USDC to Morpho, on behalf of the CEA.
    function _supplyCalls() internal view returns (Multicall[] memory calls) {
        calls = new Multicall[](1);
        calls[0] = Multicall({
            to: MORPHO_BLUE,
            value: 0,
            data: abi.encodeWithSelector(SUPPLY_SELECTOR, address(pUSDC), HUNDRED_USDC, BOB_AGW_CEA, uint16(0))
        });
    }

    function _executionCalldata(uint256 amount, uint256 pcValue) internal view returns (bytes memory) {
        return ExecutionLib.encodeSingle(
            GATEWAY, pcValue, outboundRequest(address(pUSDC), amount, 0.01 ether, address(bobAgw), _supplyCalls())
        );
    }

    function _singleMode() internal pure returns (bytes32) {
        return ModeCode.unwrap(ModeLib.encodeSimpleSingle());
    }

    /// @dev The ten-field hash, rebuilt independently of the contract.
    function _opHash(bytes memory ecd, uint192 key, uint64 seq, uint48 expiry, bytes32 pid)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
                block.chainid,
                address(bobAgw),
                address(engine),
                pid,
                _singleMode(),
                keccak256(ecd),
                key,
                seq,
                expiry
            )
        );
    }

    function _configId(bytes32 pid) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(bobAgw), keccak256(abi.encodePacked(pid, actionId)))));
    }

    function _spent(bytes32 pid) internal view returns (uint256) {
        return urp.getConfig(_configId(pid), address(bobAgw)).spent;
    }

    // ═══════════════════════════════ THE BOB FLOW ═══════════════════════════════

    /// The full flow with an ECDSA agent key — the signature really is verified.
    function test_BobFlow_ECDSA() public {
        _runBobFlow(false);
    }

    /**
     * The same flow with an Ed25519-scheme mandate and the USV observer etched at the precompile.
     *
     * THIS RUN PROVES THE ROUTING, NOT THE CRYPTOGRAPHY. The observer answers a fixed `true`, so
     * what is demonstrated is that a scheme-1 mandate grants, that the wallet reaches the validator,
     * that the validator reaches USV, and that the whole gauntlet and dispatch behave identically —
     * NOT that any Ed25519 signature was checked. Correctness and liveness of that branch are proven
     * only by P-03 against the real precompile; P-04 proves it fails closed when USV has no code.
     */
    function test_BobFlow_Ed25519Routing() public {
        etchUSVObserver();
        _runBobFlow(true);
    }

    function _runBobFlow(bool ed25519) internal {
        // ── STAGE 3 · the inbound multicall: deploy, grant, fund ──
        // Step 1 of the flow's multicall table. `deployWallet` calls `initializeAccount` itself, so
        // SmartSession is installed atomically — there is no uninitialised window.
        vm.prank(BOB_UEA);
        bobAgw = PushAgentWallet(payable(factory.deployWallet("lending")));

        assertEq(bobAgw.owner(), BOB_UEA, "owner is baked into bytecode");
        assertEq(factory.ownerOf(address(bobAgw)), BOB_UEA, "the registry is the root of trust");
        assertTrue(bobAgw.isModuleInstalled(1, address(engine), ""), "engine installed atomically");

        // Step 2: the mandate. Scheme 1 names an Ed25519 key; scheme 0 names the ECDSA address.
        bytes memory keyConfig = ed25519 ? ed25519Config(bytes32(uint256(uint160(agentAddr)))) : ecdsaConfig(agentAddr);

        vm.prank(BOB_UEA);
        permissionId = bobAgw.grantMandate(canonicalSession(keyConfig, _urpConfig()), MandateType.UNIVERSAL);
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "mandate live");

        // Steps 3 and 4: funds and gas reach the wallet.
        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);

        // ── LEDGER after stage 3 ──
        assertEq(pUSDC.balanceOf(address(bobAgw)), HUNDRED_USDC, "stage 3: wallet holds 100 pUSDC");
        assertEq(pUSDC.balanceOf(BOB_UEA), 0, "stage 3: the UEA is identity only, clean");
        assertEq(_spent(permissionId), 0, "stage 3: URP.spent == 0");

        // ── STAGE 5 · execution through the agent door ──
        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0.05 ether);
        bytes32 opHash = _opHash(ecd, 0, 0, 0, permissionId);
        bytes memory sig = _sessionSig(opHash, permissionId, ed25519);

        vm.expectEmit(true, true, true, true, address(urp));
        emit IURP.OutboundMetered(_configId(permissionId), address(engine), address(bobAgw), HUNDRED_USDC);

        vm.expectEmit(true, true, true, true, address(bobAgw));
        emit IPushAgentWallet.MandateActionAuthorized(permissionId, 0, 0, opHash);

        // ANYONE may relay — the caller is not the authority, the signature is.
        vm.prank(RELAYER);
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, sig, 0, 0, 0);

        // The gateway received THE EXACT VALIDATED BYTES, from the WALLET.
        assertEq(gateway.callCount(), 1, "stage 5: one outbound");
        MockUniversalGateway.Received memory got = gateway.lastCall();
        assertEq(got.sender, address(bobAgw), "msg.sender is the WALLET - it decides which CEA executes");
        assertEq(got.value, 0.05 ether, "the PC gas-swap value arrived");

        // The dispatched payload is everything after the 52-byte SINGLE header
        // (target 20 + value 32), taken from the calldata the AGENT SIGNED.
        bytes memory dispatched = new bytes(ecd.length - 52);
        for (uint256 i; i < dispatched.length; ++i) {
            dispatched[i] = ecd[52 + i];
        }
        assertEq(got.rawCalldata, dispatched, "THE EXACT VALIDATED BYTES - the wallet substitutes nothing");

        // Fund movement #4: the gateway burns the bridged amount. (The real gateway does this; the
        // mock records only, so the test performs the burn to keep the ledger observable.)
        pUSDC.burn(address(bobAgw), HUNDRED_USDC);

        // ── LEDGER after stage 5 ──
        assertEq(pUSDC.balanceOf(address(bobAgw)), 0, "stage 5: 100 pUSDC left the wallet");
        assertEq(_spent(permissionId), HUNDRED_USDC, "stage 5: URP.spent == 100e6");
        assertEq(bobAgw.getNonce(0), 1, "stage 5: the replay lane advanced");

        // ── STAGE 7b · the redeploy path — amount 0, and `spent` does NOT move ──
        // The capital is already at the CEA; moving it between protocols bridges nothing. The
        // lifetime cap counts what is BRIDGED, not what is REDEPLOYED — so with the cap already
        // fully consumed, this must still pass.
        _submitRequest(_executionCalldata(0, 0.01 ether), 1, permissionId, ed25519);

        assertEq(gateway.callCount(), 2, "stage 7b: the redeploy dispatched");
        assertEq(_spent(permissionId), HUNDRED_USDC, "stage 7b: spent UNCHANGED - it counts bridged, not redeployed");

        // ── STAGE 7 · revoke, and the banked request dies ──
        // The agent banks a signed request BEFORE the revocation.
        bytes memory bankedEcd = _executionCalldata(0, 0.01 ether);
        bytes32 bankedHash = _opHash(bankedEcd, 0, 2, 0, permissionId);
        bytes memory bankedSig = _sessionSig(bankedHash, permissionId, ed25519);

        vm.prank(BOB_UEA);
        bobAgw.stopMandate(permissionId);
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "revoked");

        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(ISmartSession.InvalidPermissionId.selector, PermissionId.wrap(permissionId))
        );
        bobAgw.executeWithSession(address(engine), _singleMode(), bankedEcd, bankedSig, 0, 2, 0);

        // REGRANT with byte-identical terms — and the banked request STILL fails, because the
        // wallet's monotonic grantNonce gave the replacement a different permissionId, which is
        // bound into op-hash field 5.
        vm.prank(BOB_UEA);
        bytes32 newPid = bobAgw.grantMandate(canonicalSession(keyConfig, _urpConfig()), MandateType.UNIVERSAL);
        assertTrue(newPid != permissionId, "the regranted mandate has a NEW id");

        vm.prank(RELAYER);
        vm.expectRevert(
            abi.encodeWithSelector(ISmartSession.InvalidPermissionId.selector, PermissionId.wrap(permissionId))
        );
        bobAgw.executeWithSession(address(engine), _singleMode(), bankedEcd, bankedSig, 0, 2, 0);

        // and the replacement's counters start at zero
        assertEq(_spent(newPid), 0, "stage 7: the new mandate's budget is untouched");
        assertEq(gateway.callCount(), 2, "stage 7: nothing further dispatched");
    }

    /**
     * @dev USE-mode wire format: mode byte ‖ permissionId ‖ sessionSig.
     *
     *      For the ECDSA run the inner signature is a REAL secp256k1 signature over the op hash, so
     *      the validator genuinely verifies it. For the Ed25519 run it is 64 arbitrary bytes: the
     *      USV observer answers a fixed `true`, so that run proves ROUTING, not cryptography.
     */
    /// @dev Sign and relay one request. Extracted so no single frame in `_runBobFlow` holds every
    ///      local at once — with the optimizer off (the configuration `forge coverage` uses) the
    ///      inlined version does not compile.
    function _submitRequest(bytes memory ecd, uint64 seq, bytes32 pid, bool ed25519) internal {
        bytes memory sig = _sessionSig(_opHash(ecd, 0, seq, 0, pid), pid, ed25519);
        vm.prank(RELAYER);
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, sig, 0, seq, 0);
    }

    function _sessionSig(bytes32 opHash, bytes32 pid, bool ed25519) internal view returns (bytes memory) {
        if (ed25519) {
            bytes memory edSig =
                abi.encodePacked(keccak256(abi.encode(opHash, "ed-hi")), keccak256(abi.encode(opHash, "ed-lo")));
            return abi.encodePacked(uint8(SmartSessionMode.USE), pid, edSig);
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, opHash);
        return abi.encodePacked(uint8(SmartSessionMode.USE), pid, abi.encodePacked(r, s, v));
    }

    // ═══════════════════ the caps still bind at system level ═══════════════════

    /// The lifetime cap is real end to end: a second BRIDGING request past the cap is refused by
    /// URP gate 7, seen through the engine's rewrap.
    function test_LifetimeCap_BindsEndToEnd() public {
        _deployAndGrant();

        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0);
        vm.prank(RELAYER);
        bobAgw.executeWithSession(
            address(engine), _singleMode(), ecd, _signEcdsa(_opHash(ecd, 0, 0, 0, permissionId)), 0, 0, 0
        );
        assertEq(_spent(permissionId), HUNDRED_USDC, "cap consumed");

        // one more wei over the lifetime cap
        bytes memory over = _executionCalldata(1, 0);
        bytes32 h = _opHash(over, 0, 1, 0, permissionId);

        vm.prank(RELAYER);
        expectUrpGate(
            abi.encodeWithSelector(
                IURP.TotalSpendCapExceeded.selector, uint256(HUNDRED_USDC + 1), uint256(HUNDRED_USDC)
            )
        );
        bobAgw.executeWithSession(address(engine), _singleMode(), over, _signEcdsa(h), 0, 1, 0);
    }

    /// The beneficiary pin is real end to end: an agent trading honestly but for ITSELF is refused
    /// by URP gate 15.
    function test_BeneficiaryPin_BindsEndToEnd() public {
        _deployAndGrant();

        Multicall[] memory selfish = new Multicall[](1);
        selfish[0] = Multicall({
            to: MORPHO_BLUE,
            value: 0,
            data: abi.encodeWithSelector(SUPPLY_SELECTOR, address(pUSDC), HUNDRED_USDC, agentAddr, uint16(0))
        });

        bytes memory ecd = ExecutionLib.encodeSingle(
            GATEWAY, 0, outboundRequest(address(pUSDC), HUNDRED_USDC, 0.01 ether, address(bobAgw), selfish)
        );
        bytes32 h = _opHash(ecd, 0, 0, 0, permissionId);

        vm.prank(RELAYER);
        expectUrpGate(abi.encodeWithSelector(IURP.BeneficiaryMismatch.selector, BOB_AGW_CEA, agentAddr));
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, _signEcdsa(h), 0, 0, 0);

        assertEq(gateway.callCount(), 0, "nothing dispatched");
        assertEq(_spent(permissionId), 0, "nothing metered");
    }

    /// Failure atomicity at system level: the gateway reverts, and the nonce, URP's counter and
    /// the metering event all unwind (W-18 / U-18, end to end).
    function test_GatewayRevert_UnwindsEverything() public {
        _deployAndGrant();

        gateway.setShouldRevert(true);

        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0);
        bytes32 h = _opHash(ecd, 0, 0, 0, permissionId);

        vm.prank(RELAYER);
        vm.expectRevert(MockUniversalGateway.GatewayRejected.selector);
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, _signEcdsa(h), 0, 0, 0);

        assertEq(bobAgw.getNonce(0), 0, "the nonce unwound");
        assertEq(_spent(permissionId), 0, "URP's counter unwound");
        assertEq(pUSDC.balanceOf(address(bobAgw)), HUNDRED_USDC, "the funds are untouched");

        // and it works once the gateway recovers — the lane was never burned
        gateway.setShouldRevert(false);
        vm.prank(RELAYER);
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, _signEcdsa(h), 0, 0, 0);
        assertEq(bobAgw.getNonce(0), 1, "the retry succeeded on the same lane position");
    }

    /// The owner door is unconditional even mid-mandate: Bob withdraws everything, with a live
    /// mandate and a live engine, through `execute` — there is no `withdraw()`.
    function test_OwnerWithdraws_MidMandate() public {
        _deployAndGrant();

        vm.prank(BOB_UEA);
        bobAgw.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(
                address(pUSDC), 0, abi.encodeWithSignature("transfer(address,uint256)", BOB_UEA, HUNDRED_USDC)
            )
        );

        assertEq(pUSDC.balanceOf(BOB_UEA), HUNDRED_USDC, "the owner withdrew through execute");
        assertEq(pUSDC.balanceOf(address(bobAgw)), 0, "the wallet is empty");
        assertTrue(
            engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "the mandate is still live"
        );
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _deployAndGrant() internal {
        vm.prank(BOB_UEA);
        bobAgw = PushAgentWallet(payable(factory.deployWallet("lending")));

        vm.prank(BOB_UEA);
        permissionId =
            bobAgw.grantMandate(canonicalSession(ecdsaConfig(agentAddr), _urpConfig()), MandateType.UNIVERSAL);

        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);
    }

    function _signEcdsa(bytes32 opHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, opHash);
        return abi.encodePacked(uint8(SmartSessionMode.USE), permissionId, abi.encodePacked(r, s, v));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                    THE NATIVE SCENARIO — Phase 4
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Bob's SECOND wallet, on the same implementation and the same factory, runs a Push-NATIVE
    // mandate: no gateway, no CEA, no bridging. The point of putting it in this file rather than a
    // unit suite is that both scenarios must hold AGAINST THE SAME DEPLOYED SET — one wallet
    // implementation, one URP proxy, one engine, one validator, one factory.

    /**
     * The native counterpart of `test_BobFlow_ECDSA`: grant, act, meter, revoke — end to end,
     * against the same contracts the universal flow just used.
     *
     * WHAT IS REAL HERE: the engine routes by action id, URP's native gates run on unauthenticated
     * calldata, the wallet dispatches the exact validated bytes, and `StakeDummy` is a genuine
     * counterparty that moves tokens. Nothing on the policy side is stubbed.
     */
    function test_NativeFlow_EndToEnd() public {
        (PushAgentWallet w, StakeDummy stake, MockERC20 tok, bytes32 pid) = _deployAndGrantNative();

        // ── stage 1: the agent stakes, with the beneficiary pinned to the wallet ──
        bytes memory cd =
            ExecutionLib.encodeSingle(address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(w), 40e6)));
        _submitNative(w, cd, 0, pid);

        assertEq(stake.totalBalance(address(w)), 40e6, "the stake landed on the wallet, not the agent");
        assertEq(tok.balanceOf(address(w)), 60e6, "and the tokens left the wallet");

        IURP.NativeConfig memory cfg = urp.getNativeConfig(_configIdNative(pid, address(stake), address(w)), address(w));
        assertEq(cfg.amountSpent, 40e6, "URP metered exactly what was staked");
        assertEq(cfg.callsUsed, 1, "and counted the call");

        // ── stage 2: the owner's change-flow guard reads all three counters ──
        urp.assertSpent(_configIdNative(pid, address(stake), address(w)), address(w), 0, 40e6, 1);

        // ── stage 3: revocation is immediate and the banked mandate dies with it ──
        vm.prank(BOB_UEA);
        w.stopMandate(pid);
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pid), address(w)), "revoked");

        bytes memory after_ =
            ExecutionLib.encodeSingle(address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(w), 1e6)));
        vm.prank(RELAYER);
        // NAMED, not bare: the engine no longer knows this permission, and it says so. The universal
        // flow asserts exactly this at its own revoke stage — see `_runBobFlow` stage 7.
        vm.expectRevert(abi.encodeWithSelector(ISmartSession.InvalidPermissionId.selector, PermissionId.wrap(pid)));
        w.executeWithSession(address(engine), _singleMode(), after_, _signNative(w, after_, 0, 1, pid), 0, 1, 0);
    }

    /**
     * ⚠️ THE REGRESSION GATE (decision 37). The universal scenario must behave identically to how
     * it behaved before native mode existed.
     *
     * The other universal tests in this file already assert that in substance; this one states it
     * as a named claim so the Block report can point at a single test. It runs the full Bob flow
     * and then asserts the two facts native mode could plausibly have disturbed: the universal
     * config still routes to the universal gauntlet, and its mode slot reports UNIVERSAL.
     */
    function test_UniversalFlow_UnchangedByNativeMode() public {
        _runBobFlow(false);

        ConfigId cid = _configId(permissionId);

        // It is a UNIVERSAL config, and the mode surface says so.
        IURP.ModeSlot memory slot = urp.getMode(cid, address(bobAgw));
        assertTrue(slot.initialized, "the universal config has a mode slot");
        assertEq(uint8(slot.mode), uint8(MandateType.UNIVERSAL), "and it reports UNIVERSAL");

        // The universal getter works; the native one refuses. Cross-mode reads are loud.
        assertGt(urp.getConfig(cid, address(bobAgw)).spent, 0, "the universal counter moved");
        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.UNIVERSAL));
        urp.getNativeConfig(cid, address(bobAgw));
    }

    /**
     * Both mandate types on ONE wallet, from one owner, against one deployed set.
     *
     * This is the claim that makes native mode an addition rather than a fork: a wallet may hold a
     * universal mandate and a native mandate at the same time, they meter independently, and
     * revoking one leaves the other untouched.
     */
    function test_BothModes_CoexistOnOneWallet() public {
        // NOT `_runBobFlow` — that ends by REVOKING the universal mandate at stage 7, which would
        // make "the universal mandate survives" vacuous. Grant and exercise it directly instead, so
        // both mandates are live at the same time, which is the claim under test.
        _deployAndGrant();

        bytes memory universalCd = _executionCalldata(HUNDRED_USDC, 0);
        _submitRequest(universalCd, 0, permissionId, false);

        uint256 universalSpent = _spent(permissionId);
        assertGt(universalSpent, 0, "the universal mandate has metered");

        // A native mandate on the SAME wallet.
        MockERC20 tok = new MockERC20();
        StakeDummy stake = new StakeDummy(tok);
        tok.mint(address(bobAgw), 100e6);

        vm.prank(BOB_UEA);
        bobAgw.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(
                address(tok), 0, abi.encodeCall(MockERC20.approve, (address(stake), type(uint256).max))
            )
        );

        vm.prank(BOB_UEA);
        bytes32 nativePid = bobAgw.grantMandate(_nativeSessionFor(stake, address(bobAgw)), MandateType.NATIVE);

        // A SEPARATE NONCE LANE — the SDK convention is one lane per mandate (register N-42), and
        // this is why: lane 0 was consumed by the universal flow above, so reusing it would collide
        // on sequence rather than on anything about the mandate. Lanes are independent, so a native
        // mandate on lane 1 starts at sequence 0 regardless of what lane 0 has done.
        bytes memory cd = ExecutionLib.encodeSingle(
            address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(bobAgw), 25e6))
        );
        _submitNativeOnLane(bobAgw, cd, 1, 0, nativePid);

        assertEq(stake.totalBalance(address(bobAgw)), 25e6, "the native mandate executed");

        // INDEPENDENT METERING, asserted from both sides. The universal counter is unmoved, AND the
        // native counters hold exactly the native amount — checking only the first is weaker than it
        // looks, because the two mandates live under different config ids, so a native write into
        // `$configs` would land on a DIFFERENT slot and leave `_spent(permissionId)` untouched.
        assertEq(_spent(permissionId), universalSpent, "the universal counter is unmoved");

        ConfigId nativeCid = _configIdNative(nativePid, address(stake), address(bobAgw));
        IURP.NativeConfig memory ncfg = urp.getNativeConfig(nativeCid, address(bobAgw));
        assertEq(ncfg.amountSpent, 25e6, "the native counter holds exactly the native amount");
        assertEq(ncfg.callsUsed, 1, "and one native call");

        // And the native config id carries NO universal state — the two rulebooks are DISJOINT
        // STORAGE, which is what "independent" actually means here.
        //
        // READ RAW, with `vm.load`, and deliberately so: `getConfig` reverts on the mode slot BEFORE
        // it ever touches the struct, so no public view can observe a native write that landed in
        // `$configs`. An assertion built on the getters passes even when the counters ARE
        // cross-contaminated — measured, by mutating `_checkNative` to write into `$configs` and
        // watching the getter-based version of this test still go green. The raw slot is the only
        // honest instrument.
        //
        // `$configs` is slot 3. `Config.spent` sits at base + 7, NOT base + 8: `initialized` (bool)
        // and `validUntil` (uint48) PACK into the struct's first slot, so every later field shifts
        // down by one. Located by dumping the slots rather than counting fields — the field count
        // and the slot index are different numbers whenever anything packs.
        bytes32 configsBase = keccak256(
            abi.encode(
                address(bobAgw), keccak256(abi.encode(address(engine), keccak256(abi.encode(nativeCid, uint256(3)))))
            )
        );
        // PIN THE OFFSET FIRST, against a slot known to be NON-ZERO. A raw-slot assertion has no
        // compile-time link to the field it claims to read: reorder `Config` and `+ 7` silently
        // points elsewhere, reads zero, and this test passes while proving nothing. MEASURED — with
        // `+ 8` and without this pin the test still passes; with it, `+ 8` fails loudly.
        bytes32 universalBase = keccak256(
            abi.encode(
                address(bobAgw),
                keccak256(abi.encode(address(engine), keccak256(abi.encode(_configId(permissionId), uint256(3)))))
            )
        );
        assertEq(
            uint256(vm.load(address(urp), bytes32(uint256(universalBase) + 7))),
            universalSpent,
            "offset +7 IS Config.spent - proven against a slot known to be non-zero"
        );
        assertEq(
            uint256(vm.load(address(urp), bytes32(uint256(configsBase) + 7))),
            0,
            "the native action wrote NOTHING into the universal rulebook"
        );

        vm.expectRevert(abi.encodeWithSelector(IURP.WrongModeForCall.selector, MandateType.NATIVE));
        urp.getConfig(nativeCid, address(bobAgw));

        // Revoking the native mandate leaves the universal one enabled.
        vm.prank(BOB_UEA);
        bobAgw.stopMandate(nativePid);
        assertTrue(
            engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)),
            "the universal mandate survives the native revoke"
        );
    }

    // ───────────────────────── native scenario plumbing ─────────────────────────

    function _nativeConfigFor(StakeDummy stake, address beneficiary)
        internal
        view
        returns (IURP.NativeConfig memory c)
    {
        IURP.ArgPin[] memory pins = new IURP.ArgPin[](1);
        pins[0] = IURP.ArgPin({ offset: 4, expected: bytes32(uint256(uint160(beneficiary))) });

        c = IURP.NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: address(stake),
            selector: StakeDummy.stakeFor.selector,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: IURP.AmountRule({ enabled: true, offset: 36, maxPerCall: 50e6, maxTotal: 60e6 }),
            amountSpent: 0,
            maxCalls: 0,
            callsUsed: 0,
            pins: pins
        });
    }

    function _nativeSessionFor(StakeDummy stake, address beneficiary) internal view returns (Session memory) {
        PolicyData[] memory ps = new PolicyData[](1);
        ps[0] = PolicyData({ policy: address(urp), initData: nativeInitData(_nativeConfigFor(stake, beneficiary)) });

        ActionData[] memory a = new ActionData[](1);
        a[0] = ActionData({
            actionTargetSelector: StakeDummy.stakeFor.selector, actionTarget: address(stake), actionPolicies: ps
        });

        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: ecdsaConfig(agentAddr),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: a,
            permitERC4337Paymaster: false
        });
    }

    function _deployAndGrantNative()
        internal
        returns (PushAgentWallet w, StakeDummy stake, MockERC20 tok, bytes32 pid)
    {
        vm.prank(BOB_UEA);
        w = PushAgentWallet(payable(factory.deployWallet("staking")));

        tok = new MockERC20();
        stake = new StakeDummy(tok);
        tok.mint(address(w), 100e6);
        vm.deal(address(w), 1 ether);

        vm.prank(BOB_UEA);
        w.execute(
            _singleMode(),
            ExecutionLib.encodeSingle(
                address(tok), 0, abi.encodeCall(MockERC20.approve, (address(stake), type(uint256).max))
            )
        );

        vm.prank(BOB_UEA);
        pid = w.grantMandate(_nativeSessionFor(stake, address(w)), MandateType.NATIVE);
    }

    /// @dev The native action's config id: `keccak(account . keccak(pid . actionId))`, where
    ///      `actionId = keccak(target . selector)`. Derived here rather than imported, so the test
    ///      asserts the engine's derivation rather than inheriting it.
    function _configIdNative(bytes32 pid, address target, address account) internal pure returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(target, StakeDummy.stakeFor.selector));
        return ConfigId.wrap(keccak256(abi.encodePacked(account, keccak256(abi.encodePacked(pid, actionId)))));
    }

    function _opHashNative(PushAgentWallet w, bytes memory ecd, uint192 key, uint64 seq, bytes32 pid)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("PushAgentWallet.Op.v3"),
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
    }

    function _signNative(PushAgentWallet w, bytes memory ecd, uint192 key, uint64 seq, bytes32 pid)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, _opHashNative(w, ecd, key, seq, pid));
        return abi.encodePacked(uint8(SmartSessionMode.USE), pid, abi.encodePacked(r, s, v));
    }

    function _submitNative(PushAgentWallet w, bytes memory ecd, uint64 seq, bytes32 pid) internal {
        _submitNativeOnLane(w, ecd, 0, seq, pid);
    }

    /// @dev Lanes are independent replay counters, so a second mandate on the same wallet takes its
    ///      own lane and starts at sequence 0 (SDK convention, register N-42).
    function _submitNativeOnLane(PushAgentWallet w, bytes memory ecd, uint192 key, uint64 seq, bytes32 pid) internal {
        vm.prank(RELAYER);
        w.executeWithSession(address(engine), _singleMode(), ecd, _signNative(w, ecd, key, seq, pid), key, seq, 0);
    }
}
