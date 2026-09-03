// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { MockUniversalGateway, MockPRC20 } from "../mocks/MockUniversalGateway.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { IUCEP } from "../../src/interfaces/IUCEP.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";

import { PermissionId, ConfigId, SmartSessionMode } from "smartsessions/DataTypes.sol";
import { ISmartSession } from "smartsessions/ISmartSession.sol";

/**
 * @notice E2E — Bob lends 100 USDC. The flow document's stages 3, 5, 7 and 7b, end to end, against
 *         the real engine, the real UCEP, the real validator, the real wallet and the real factory.
 *
 * @dev    THE ONLY MOCK IS THE GATEWAY, and it is an OBSERVER: it records the exact bytes it
 *         received and decides nothing. Every judgement about whether a request is legal is made
 *         upstream by UCEP and the wallet.
 *
 * @dev    WHAT THIS DOES NOT PROVE: stages 2, 4 and 6 are off-chain or far-chain (the Ethereum
 *         lock, the agent's research, the TSS settlement). They have no contract in the v3 set.
 *         The fund ledger below therefore starts at "100 pUSDC has arrived on Push Chain".
 *
 * @dev    THE FUND LEDGER IS PARTLY AUTHORED BY THIS TEST, and should not be read as end-to-end
 *         fund verification. The real gateway burns the bridged PRC20; the mock only RECORDS, so
 *         the burn below is performed by the test to keep the ledger observable. What is genuinely
 *         verified on the money path is narrower and stated where it happens: the exact validated
 *         bytes reached the gateway, `msg.sender` was the wallet, and UCEP's counter moved by
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

        // The gateway mock lives AT the address the wallet and UCEP were wired to, so no contract
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
    function _ucepConfig() internal view returns (bytes memory) {
        IUCEP.AllowedCall[] memory rules = new IUCEP.AllowedCall[](1);
        rules[0] = IUCEP.AllowedCall({
            target: MORPHO_BLUE,
            selector: SUPPLY_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0 // supply() is non-payable on the far chain
        });

        return abi.encode(
            IUCEP.Config({
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
        return ucep.getConfig(_configId(pid), address(bobAgw)).spent;
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
        permissionId = bobAgw.grantMandate(canonicalSession(keyConfig, _ucepConfig()));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "mandate live");

        // Steps 3 and 4: funds and gas reach the wallet.
        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);

        // ── LEDGER after stage 3 ──
        assertEq(pUSDC.balanceOf(address(bobAgw)), HUNDRED_USDC, "stage 3: wallet holds 100 pUSDC");
        assertEq(pUSDC.balanceOf(BOB_UEA), 0, "stage 3: the UEA is identity only, clean");
        assertEq(_spent(permissionId), 0, "stage 3: UCEP.spent == 0");

        // ── STAGE 5 · execution through the agent door ──
        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0.05 ether);
        bytes32 opHash = _opHash(ecd, 0, 0, 0, permissionId);
        bytes memory sig = _sessionSig(opHash, permissionId, ed25519);

        vm.expectEmit(true, true, true, true, address(ucep));
        emit IUCEP.OutboundMetered(_configId(permissionId), address(engine), address(bobAgw), HUNDRED_USDC);

        vm.expectEmit(true, true, true, true, address(bobAgw));
        emit PushAgentWallet.MandateActionAuthorized(permissionId, 0, 0, opHash);

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
        assertEq(_spent(permissionId), HUNDRED_USDC, "stage 5: UCEP.spent == 100e6");
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
        bytes32 newPid = bobAgw.grantMandate(canonicalSession(keyConfig, _ucepConfig()));
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
    /// UCEP gate 7, seen through the engine's rewrap.
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
        expectUcepGate(
            abi.encodeWithSelector(
                IUCEP.TotalSpendCapExceeded.selector, uint256(HUNDRED_USDC + 1), uint256(HUNDRED_USDC)
            )
        );
        bobAgw.executeWithSession(address(engine), _singleMode(), over, _signEcdsa(h), 0, 1, 0);
    }

    /// The beneficiary pin is real end to end: an agent trading honestly but for ITSELF is refused
    /// by UCEP gate 15.
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
        expectUcepGate(abi.encodeWithSelector(IUCEP.BeneficiaryMismatch.selector, BOB_AGW_CEA, agentAddr));
        bobAgw.executeWithSession(address(engine), _singleMode(), ecd, _signEcdsa(h), 0, 0, 0);

        assertEq(gateway.callCount(), 0, "nothing dispatched");
        assertEq(_spent(permissionId), 0, "nothing metered");
    }

    /// Failure atomicity at system level: the gateway reverts, and the nonce, UCEP's counter and
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
        assertEq(_spent(permissionId), 0, "UCEP's counter unwound");
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
        permissionId = bobAgw.grantMandate(canonicalSession(ecdsaConfig(agentAddr), _ucepConfig()));

        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);
    }

    function _signEcdsa(bytes32 opHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, opHash);
        return abi.encodePacked(uint8(SmartSessionMode.USE), permissionId, abi.encodePacked(r, s, v));
    }
}
