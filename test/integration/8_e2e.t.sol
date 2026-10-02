// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import {
    AllowedCall,
    AmountRule,
    ArgPin,
    Config,
    ModeSlot,
    NativeConfig,
    RulesType
} from "../../src/libraries/Types.sol";
import { MockUniversalGateway, MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { StakeDummy } from "../mocks/StakeDummy.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockUEA } from "../mocks/MockUEA.sol";

import { AGW } from "../../src/AGW.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { AGWErrors } from "../../src/libraries/Errors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { Multicall } from "../../src/libraries/Types.sol";

import {
    PermissionId,
    ConfigId,
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

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

    AGW internal bobAgw;
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

    /// @dev The agent's Push address — an EOA here; `test_BobFlow_UEAAgent` uses a UEA instead.
    address internal agentAddr;

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
        agentAddr = makeAddr("0xagent");

        vm.warp(1_700_000_000);
    }

    // ───────────────────────────── mandate fixtures ─────────────────────────────

    /// @dev The mandate of the flow document, verbatim: one asset, 100e6 per call and lifetime,
    ///      one Morpho-shaped rule with the beneficiary pinned to the CEA, 30-day expiry.
    function _urpConfig() internal view returns (bytes memory) {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: MORPHO_BLUE,
            selector: SUPPLY_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0 // supply() is non-payable on the far chain
        });

        return universalInitData(
            Config({
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

    function _configId(bytes32 pid) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(GATEWAY, SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(keccak256(abi.encodePacked(address(bobAgw), keccak256(abi.encodePacked(pid, actionId)))));
    }

    function _spent(bytes32 pid) internal view returns (uint256) {
        return urp.getConfig(_configId(pid), address(bobAgw)).spent;
    }

    // ═══════════════════════════════ THE BOB FLOW ═══════════════════════════════

    /// The full flow with an EOA agent: the agent's own address calls the agent door.
    function test_BobFlow_EOAAgent() public {
        _runBobFlow(agentAddr, agentAddr);
    }

    /**
     * The same flow with an external-key agent: the rules set names the key's UEA, and every agent
     * action is the origin key driving its UEA, which calls the wallet. The UEA verifies the external
     * key (here `MockUEA`, with the real UEA's "only the origin key may drive me" rule); the wallet
     * verifies no signature, only that the sender is the agent. The origin key calling the wallet
     * directly is refused like any other stranger.
     */
    function test_BobFlow_UEAAgent() public {
        (address originKey,) = ecdsaKey("0xexternalkey");
        MockUEA ua = new MockUEA(originKey);

        bytes32 livePid = _runBobFlow(address(ua), originKey);

        bytes memory ecd = _executionCalldata(0, 0.01 ether);
        vm.prank(originKey);
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, livePid, originKey));
        bobAgw.executeAsAgent(livePid, _singleMode(), ecd);
    }

    /// @dev Runs stages 3, 5, 7b and 7 with `agent` named in the rules set and `caller` submitting:
    ///      `caller == agent` is an EOA agent calling the door itself; otherwise `agent` is a MockUEA
    ///      driven by `caller`, its origin key. Returns the regranted rules set's id, still live.
    function _runBobFlow(address agent, address caller) internal returns (bytes32 newPid) {
        // ── STAGE 3 · the inbound multicall: deploy, grant, fund ──
        // Step 1 of the flow's multicall table. `deployWallet` calls `initializeAccount` itself, so
        // SmartSession is installed atomically — there is no uninitialised window.
        vm.prank(BOB_UEA);
        bobAgw = AGW(payable(factory.deployWallet("lending")));

        assertEq(bobAgw.owner(), BOB_UEA, "owner is baked into bytecode");
        assertEq(factory.ownerOf(address(bobAgw)), BOB_UEA, "the registry is the root of trust");
        assertTrue(bobAgw.isModuleInstalled(1, address(engine), ""), "engine installed atomically");

        // Step 2: the rules set, naming the agent's Push address.
        vm.prank(BOB_UEA);
        permissionId = bobAgw.grantRules(canonicalSession(agentConfig(agent), _urpConfig()));
        assertTrue(engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "rules set live");
        assertEq(bobAgw.agentOf(permissionId), agent, "the rules set names the agent");

        // Steps 3 and 4: funds and gas reach the wallet.
        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);

        // ── LEDGER after stage 3 ──
        assertEq(pUSDC.balanceOf(address(bobAgw)), HUNDRED_USDC, "stage 3: wallet holds 100 pUSDC");
        assertEq(pUSDC.balanceOf(BOB_UEA), 0, "stage 3: the UEA is identity only, clean");
        assertEq(_spent(permissionId), 0, "stage 3: URP.spent == 0");

        // ── STAGE 5 · execution through the agent door ──
        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0.05 ether);

        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.OutboundMetered(
            _configId(permissionId), address(engine), address(bobAgw), HUNDRED_USDC
        );

        vm.expectEmit(true, true, false, true, address(bobAgw));
        emit IAGW.RulesActionAuthorized(permissionId, agent, keccak256(ecd));

        _act(agent, caller, permissionId, ecd);

        // The gateway received THE EXACT VALIDATED BYTES, from the WALLET.
        assertEq(gateway.callCount(), 1, "stage 5: one outbound");
        MockUniversalGateway.Received memory got = gateway.lastCall();
        assertEq(got.sender, address(bobAgw), "msg.sender is the WALLET - it decides which CEA executes");
        assertEq(got.value, 0.05 ether, "the PC gas-swap value arrived");

        // The dispatched payload is everything after the 52-byte SINGLE header
        // (target 20 + value 32), taken from the calldata the AGENT SUBMITTED.
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

        // ── STAGE 7b · the redeploy path — amount 0, and `spent` does NOT move ──
        // The capital is already at the CEA; moving it between protocols bridges nothing. The
        // lifetime cap counts what is BRIDGED, not what is REDEPLOYED — so with the cap already
        // fully consumed, this must still pass.
        _act(agent, caller, permissionId, _executionCalldata(0, 0.01 ether));

        assertEq(gateway.callCount(), 2, "stage 7b: the redeploy dispatched");
        assertEq(_spent(permissionId), HUNDRED_USDC, "stage 7b: spent UNCHANGED - it counts bridged, not redeployed");

        newPid = _revokeAndRegrant(agent, caller);
    }

    /// @dev Stage 7 · revoke, and a request built for the revoked rules set dies — including after a
    ///      byte-identical regrant, whose id is new. Split out for stack depth with the optimizer off.
    function _revokeAndRegrant(address agent, address caller) internal returns (bytes32 newPid) {
        bytes memory bankedEcd = _executionCalldata(0, 0.01 ether);

        vm.prank(BOB_UEA);
        bobAgw.revokeRules(permissionId);
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)), "revoked");

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agent));
        _act(agent, caller, permissionId, bankedEcd);

        // REGRANT with byte-identical terms — and the request for the old id STILL fails, because the
        // wallet's monotonic grantNonce gave the replacement a different id.
        vm.prank(BOB_UEA);
        newPid = bobAgw.grantRules(canonicalSession(agentConfig(agent), _urpConfig()));
        assertTrue(newPid != permissionId, "the regranted rules set has a NEW id");

        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, permissionId, agent));
        _act(agent, caller, permissionId, bankedEcd);

        assertEq(_spent(newPid), 0, "stage 7: the new rules set's budget is untouched");
        assertEq(gateway.callCount(), 2, "stage 7: nothing dispatched under the old id");

        // and the same request under the NEW id works
        _act(agent, caller, newPid, bankedEcd);
        assertEq(gateway.callCount(), 3, "stage 7: the new id acts");
    }

    /// @dev One agent action: an EOA agent calls the door itself; a UEA agent is driven by its
    ///      origin key, and the UEA is the sender the wallet sees.
    function _act(address agent, address caller, bytes32 pid, bytes memory ecd) internal {
        if (caller == agent) {
            vm.prank(agent);
            bobAgw.executeAsAgent(pid, _singleMode(), ecd);
        } else {
            vm.prank(caller);
            MockUEA(payable(agent))
                .exec(address(bobAgw), 0, abi.encodeCall(AGW.executeAsAgent, (pid, _singleMode(), ecd)));
        }
    }

    /// @dev The EOA agent acts under the suite's rules set.
    function _submitRequest(bytes memory ecd) internal {
        vm.prank(agentAddr);
        bobAgw.executeAsAgent(permissionId, _singleMode(), ecd);
    }

    // ═══════════════════ the caps still bind at system level ═══════════════════

    /// The lifetime cap is real end to end: a second BRIDGING request past the cap is refused by
    /// URP gate 7, seen through the engine's rewrap.
    function test_LifetimeCap_BindsEndToEnd() public {
        _deployAndGrant();

        _submitRequest(_executionCalldata(HUNDRED_USDC, 0));
        assertEq(_spent(permissionId), HUNDRED_USDC, "cap consumed");

        // one more wei over the lifetime cap
        bytes memory over = _executionCalldata(1, 0);

        expectUrpGate(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector,
                uint256(HUNDRED_USDC + 1),
                uint256(HUNDRED_USDC)
            )
        );
        _submitRequest(over);
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
        expectUrpGate(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, BOB_AGW_CEA, agentAddr)
        );
        _submitRequest(ecd);

        assertEq(gateway.callCount(), 0, "nothing dispatched");
        assertEq(_spent(permissionId), 0, "nothing metered");
    }

    /// Failure atomicity at system level: the gateway reverts, and URP's counter and the metering
    /// event unwind (W-18 / U-18, end to end).
    function test_GatewayRevert_UnwindsEverything() public {
        _deployAndGrant();

        gateway.setShouldRevert(true);

        bytes memory ecd = _executionCalldata(HUNDRED_USDC, 0);

        vm.expectRevert(MockUniversalGateway.GatewayRejected.selector);
        _submitRequest(ecd);

        assertEq(_spent(permissionId), 0, "URP's counter unwound");
        assertEq(pUSDC.balanceOf(address(bobAgw)), HUNDRED_USDC, "the funds are untouched");

        // and the identical request works once the gateway recovers
        gateway.setShouldRevert(false);
        _submitRequest(ecd);
        assertEq(gateway.callCount(), 1, "the retry dispatched");
        assertEq(_spent(permissionId), HUNDRED_USDC, "and metered exactly once");
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
        bobAgw = AGW(payable(factory.deployWallet("lending")));

        vm.prank(BOB_UEA);
        permissionId = bobAgw.grantRules(canonicalSession(agentConfig(agentAddr), _urpConfig()));

        pUSDC.mint(address(bobAgw), HUNDRED_USDC);
        vm.deal(address(bobAgw), 1 ether);
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
     * The native counterpart of `test_BobFlow_EOAAgent`: grant, act, meter, revoke — end to end,
     * against the same contracts the universal flow just used.
     *
     * WHAT IS REAL HERE: the engine routes by action id, URP's native gates run on unauthenticated
     * calldata, the wallet dispatches the exact validated bytes, and `StakeDummy` is a genuine
     * counterparty that moves tokens. Nothing on the policy side is stubbed.
     */
    function test_NativeFlow_EndToEnd() public {
        (AGW w, StakeDummy stake, MockERC20 tok, bytes32 pid) = _deployAndGrantNative();

        // ── stage 1: the agent stakes, with the beneficiary pinned to the wallet ──
        bytes memory cd =
            ExecutionLib.encodeSingle(address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(w), 40e6)));
        _submitNative(w, cd, pid);

        assertEq(stake.totalBalance(address(w)), 40e6, "the stake landed on the wallet, not the agent");
        assertEq(tok.balanceOf(address(w)), 60e6, "and the tokens left the wallet");

        NativeConfig memory cfg = urp.getNativeConfig(_configIdNative(pid, address(stake), address(w)), address(w));
        assertEq(cfg.amountSpent, 40e6, "URP metered exactly what was staked");
        assertEq(cfg.callsUsed, 1, "and counted the call");

        // ── stage 2: the owner's change-flow guard reads all three counters ──
        urp.assertSpent(_configIdNative(pid, address(stake), address(w)), address(w), 0, 40e6, 1);

        // ── stage 3: revocation is immediate and the banked mandate dies with it ──
        vm.prank(BOB_UEA);
        w.revokeRules(pid);
        assertFalse(engine.isPermissionEnabled(PermissionId.wrap(pid), address(w)), "revoked");

        bytes memory after_ =
            ExecutionLib.encodeSingle(address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(w), 1e6)));
        // NAMED, not bare: removal cleared the agent, so the wallet refuses before the engine runs. The
        // universal flow asserts exactly this at its own revoke stage — see `_revokeAndRegrant`.
        vm.expectRevert(abi.encodeWithSelector(AGWErrors.CallerIsNotAgent.selector, pid, agentAddr));
        _submitNative(w, after_, pid);
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
        _runBobFlow(agentAddr, agentAddr);

        ConfigId cid = _configId(permissionId);

        // It is a UNIVERSAL config, and the mode surface says so.
        ModeSlot memory slot = urp.getMode(cid, address(bobAgw));
        assertTrue(slot.initialized, "the universal config has a mode slot");
        assertEq(uint8(slot.mode), uint8(RulesType.UNIVERSAL), "and it reports UNIVERSAL");

        // The universal getter works; the native one refuses. Cross-mode reads are loud.
        assertGt(urp.getConfig(cid, address(bobAgw)).spent, 0, "the universal counter moved");
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongModeForCall.selector, RulesType.UNIVERSAL)
        );
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

        _submitRequest(_executionCalldata(HUNDRED_USDC, 0));

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
        bytes32 nativePid = bobAgw.grantRules(_nativeSessionFor(stake, address(bobAgw)));

        bytes memory cd = ExecutionLib.encodeSingle(
            address(stake), 0, abi.encodeCall(StakeDummy.stakeFor, (address(bobAgw), 25e6))
        );
        _submitNative(bobAgw, cd, nativePid);

        assertEq(stake.totalBalance(address(bobAgw)), 25e6, "the native mandate executed");

        // INDEPENDENT METERING, asserted from both sides. The universal counter is unmoved, AND the
        // native counters hold exactly the native amount — checking only the first is weaker than it
        // looks, because the two mandates live under different config ids, so a native write into
        // `_configs` would land on a DIFFERENT slot and leave `_spent(permissionId)` untouched.
        assertEq(_spent(permissionId), universalSpent, "the universal counter is unmoved");

        ConfigId nativeCid = _configIdNative(nativePid, address(stake), address(bobAgw));
        NativeConfig memory ncfg = urp.getNativeConfig(nativeCid, address(bobAgw));
        assertEq(ncfg.amountSpent, 25e6, "the native counter holds exactly the native amount");
        assertEq(ncfg.callsUsed, 1, "and one native call");

        // And the native config id carries NO universal state — the two rulebooks are DISJOINT
        // STORAGE, which is what "independent" actually means here.
        //
        // READ RAW, with `vm.load`, and deliberately so: `getConfig` reverts on the mode slot BEFORE
        // it ever touches the struct, so no public view can observe a native write that landed in
        // `_configs`. An assertion built on the getters passes even when the counters ARE
        // cross-contaminated — measured, by mutating `_checkNative` to write into `_configs` and
        // watching the getter-based version of this test still go green. The raw slot is the only
        // honest instrument.
        //
        // `_configs` is slot 3. `Config.spent` sits at base + 7, NOT base + 8: `initialized` (bool)
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

        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.WrongModeForCall.selector, RulesType.NATIVE));
        urp.getConfig(nativeCid, address(bobAgw));

        // Revoking the native mandate leaves the universal one enabled.
        vm.prank(BOB_UEA);
        bobAgw.revokeRules(nativePid);
        assertTrue(
            engine.isPermissionEnabled(PermissionId.wrap(permissionId), address(bobAgw)),
            "the universal mandate survives the native revoke"
        );
    }

    // ───────────────────────── native scenario plumbing ─────────────────────────

    function _nativeConfigFor(StakeDummy stake, address beneficiary) internal view returns (NativeConfig memory c) {
        ArgPin[] memory pins = new ArgPin[](1);
        pins[0] = ArgPin({ offset: 4, expected: bytes32(uint256(uint160(beneficiary))) });

        c = NativeConfig({
            initialized: false,
            validUntil: uint48(block.timestamp + 7 days),
            target: address(stake),
            selector: StakeDummy.stakeFor.selector,
            maxValuePerCall: 0,
            maxValueTotal: 0,
            valueSpent: 0,
            amount: AmountRule({ enabled: true, offset: 36, maxPerCall: 50e6, maxTotal: 60e6 }),
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
            sessionValidatorInitData: agentConfig(agentAddr),
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: a,
            permitERC4337Paymaster: false
        });
    }

    function _deployAndGrantNative() internal returns (AGW w, StakeDummy stake, MockERC20 tok, bytes32 pid) {
        vm.prank(BOB_UEA);
        w = AGW(payable(factory.deployWallet("staking")));

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
        pid = w.grantRules(_nativeSessionFor(stake, address(w)));
    }

    /// @dev The native action's config id: `keccak(account . keccak(pid . actionId))`, where
    ///      `actionId = keccak(target . selector)`. Derived here rather than imported, so the test
    ///      asserts the engine's derivation rather than inheriting it.
    function _configIdNative(bytes32 pid, address target, address account) internal pure returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(target, StakeDummy.stakeFor.selector));
        return ConfigId.wrap(keccak256(abi.encodePacked(account, keccak256(abi.encodePacked(pid, actionId)))));
    }

    /// @dev The agent itself calls the agent door of `w`.
    function _submitNative(AGW w, bytes memory ecd, bytes32 pid) internal {
        vm.prank(agentAddr);
        w.executeAsAgent(pid, _singleMode(), ecd);
    }
}
