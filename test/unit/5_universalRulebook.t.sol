// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";
import { UniversalRulesPolicy } from "../../src/policies/UniversalRulesPolicy.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import {
    AllowedCall,
    Config,
    Multicall,
    MULTICALL_SELECTOR,
    NativeConfig,
    RulesType,
    UniversalOutboundTxRequest,
    VALUE_SELECTOR,
    VmFamily
} from "../../src/libraries/Types.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/**
 * @notice URP acceptance suite — U-01 … U-22 (U-19 deferred to Phase 3b: it needs removeSession
 *         on a real wallet).
 *
 * @dev    HOW URP IS DRIVEN HERE. The engine does not call it yet, so the harness sets
 *         SESSION_ENGINE to address(engine) and drives both engine-facing entry points with
 *         `vm.prank(address(engine))`. The engine is NOT mocked — we simply call from its address,
 *         which is what the multiplexer key means.
 *
 * @dev    EXACTLY TWO selector-less `vm.expectRevert()` calls exist in this file, and both are
 *         un-named decode residuals that cannot be given an error without introducing an external
 *         call:
 *           1. gate 4 case (d) — a correct-length, structurally-malformed outbound body;
 *           2. gate 12 — a multicall body that is empty or structurally malformed.
 *         Every other negative test names its expected error.
 */
contract URPTest is BaseTest {
    // The far-chain protocol the allow-list points at. Never called — only named.
    address internal PROTOCOL;
    address internal CEA;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));
    bytes4 internal constant POKE_SELECTOR = bytes4(keccak256("poke()"));

    /// @dev The CEA's migration branch prefix. Hashed from the string rather than imported: the
    ///      core repo is a sibling checkout with no remapping into this project. Source of truth is
    ///      push-chain-core-contracts/src/libraries/Types.sol:61
    ///      (`bytes4 constant MIGRATION_SELECTOR = bytes4(keccak256("UEA_MIGRATION"))`), consumed at
    ///      CEA.sol:298-301. If that string ever changes, this constant goes stale silently — which
    ///      is acceptable only because gate 12 admits exactly ONE prefix and rejects every other
    ///      value, so the test's purpose (proving migration is excluded) cannot regress to a false
    ///      pass: a stale constant still exercises a non-multicall prefix.
    bytes4 internal constant MIGRATION_SELECTOR = bytes4(keccak256("UEA_MIGRATION"));

    /// @dev Beneficiary word sits at offset 36: 4 selector + 32 for the leading uint256.
    uint16 internal constant BENEFICIARY_OFFSET = 36;

    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0xC0FFEE)));

    address internal ACCOUNT;
    address internal ASSET;

    uint48 internal constant VALID_UNTIL = 2_000_000_000;

    function setUp() public override {
        super.setUp();
        PROTOCOL = makeAddr("farChainProtocol");
        CEA = makeAddr("destinationAccount");
        ACCOUNT = makeAddr("agentWallet");
        ASSET = address(new MockPRC20()); // answers SOURCE_CHAIN_NAMESPACE, which URP checks at init
        vm.warp(1_000_000_000);
    }

    // ───────────────────────────── config builders ─────────────────────────────

    /// @dev One allow-list entry: PROTOCOL.swap, with a beneficiary pin and a native cap.
    function _oneRule() internal view returns (AllowedCall[] memory rules) {
        rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
    }

    function _config(AllowedCall[] memory rules) internal view returns (Config memory cfg) {
        cfg = Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            destChainHash: keccak256("eip155:11155111"),
            expectedCEA: CEA,
            asset: ASSET,
            maxAmountPerCall: 100 ether,
            maxAmountTotal: 1000 ether,
            maxPCPerCall: 5 ether,
            spent: 0,
            allowedCalls: rules
        });
    }

    function _defaultConfig() internal view returns (Config memory) {
        return _config(_oneRule());
    }

    /// @dev Initialise as the engine — the only multiplexer the non-engine paths read.
    function _init(Config memory cfg) internal {
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(cfg));
    }

    function _initDefault() internal {
        _init(_defaultConfig());
    }

    // ───────────────────────────── payload builders ─────────────────────────────

    /// @dev A single valid swap instruction benefiting the destination account.
    function _goodCalls() internal view returns (Multicall[] memory calls) {
        calls = new Multicall[](1);
        calls[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA) });
    }

    /// @dev The full gateway calldata: selector + encoded request, with sane routing fields.
    function _requestData(uint256 amount, Multicall[] memory calls) internal view returns (bytes memory) {
        return outboundRequest(ASSET, amount, 1 ether, ACCOUNT, calls);
    }

    function _goodRequest(uint256 amount) internal view returns (bytes memory) {
        return _requestData(amount, _goodCalls());
    }

    /// @dev A full gateway request carrying an ARBITRARY payload, for the gate-12 branch tests.
    ///      Every other field is valid, so gates 1-11 pass and gate 12 is what fires.
    function _requestWithPayload(bytes memory payload) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: "",
                token: ASSET,
                amount: 1 ether,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: 1 ether,
                payload: payload,
                revertRecipient: ACCOUNT
            })
        );
    }

    /// @dev Drive the gauntlet as the engine would.
    function _check(uint256 value, bytes memory data) internal returns (uint256) {
        vm.prank(address(engine));
        return urp.checkAction(CID, ACCOUNT, GATEWAY, value, data);
    }

    function _spent() internal view returns (uint256) {
        return urp.getConfig(CID, ACCOUNT).spent;
    }

    // ═══════════════════════════ construction & init ═══════════════════════════

    /// @dev The zero-address guard moved from the constructor to `initialize` when URP went behind
    ///      a proxy. The NAME is kept: it is the same guard, on the same three arguments, and the
    ///      test ids in the PRD refer to it. Driven through a fresh proxy each time, because that
    ///      is the only context in which `initialize` is reachable.
    function test_constructor_rejectsZeroAddresses() public {
        UniversalRulesPolicy impl = new UniversalRulesPolicy();

        vm.expectRevert(UniversalRulesPolicyErrors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            URP_ADMIN_OWNER,
            abi.encodeCall(UniversalRulesPolicy.initialize, (address(0), EXECUTOR_MODULE, address(engine)))
        );

        vm.expectRevert(UniversalRulesPolicyErrors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            URP_ADMIN_OWNER,
            abi.encodeCall(UniversalRulesPolicy.initialize, (GATEWAY, address(0), address(engine)))
        );

        vm.expectRevert(UniversalRulesPolicyErrors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            URP_ADMIN_OWNER,
            abi.encodeCall(UniversalRulesPolicy.initialize, (GATEWAY, EXECUTOR_MODULE, address(0)))
        );
    }

    /// @dev Formerly "setsImmutables". The three anchors are storage now, but the property under
    ///      test is unchanged: they are readable, correct, and there is no setter for any of them.
    function test_constructor_setsImmutables() public view {
        assertEq(urp.UNIVERSAL_GATEWAY_PC(), GATEWAY, "gateway anchor");
        assertEq(urp.UNIVERSAL_EXECUTOR_MODULE(), EXECUTOR_MODULE, "executor module anchor");
        assertEq(urp.SESSION_ENGINE(), address(engine), "session engine anchor");
    }

    // ═══════════════════════════ upgradeability ═══════════════════════════

    /// @dev An implementation left initialisable is a live contract holding a config the proxy
    ///      knows nothing about. Its constructor must lock it.
    function test_upgradeable_implementationCannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        urpImplementation.initialize(GATEWAY, EXECUTOR_MODULE, address(engine));
    }

    /// @dev The proxy is initialised exactly once, in its constructor. A second call must fail, or
    ///      anyone could re-point the engine this policy trusts.
    function test_upgradeable_proxyCannotBeReinitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        urp.initialize(GATEWAY, EXECUTOR_MODULE, address(engine));
    }

    /// @dev The anchors live in the PROXY's storage, not the implementation's. The implementation
    ///      read directly must therefore answer zero — proof the values were never in bytecode.
    function test_upgradeable_anchorsLiveInProxyStorage() public view {
        assertEq(urpImplementation.UNIVERSAL_GATEWAY_PC(), address(0), "implementation holds no gateway");
        assertEq(urpImplementation.SESSION_ENGINE(), address(0), "implementation holds no engine");
        assertEq(urp.UNIVERSAL_GATEWAY_PC(), GATEWAY, "the proxy holds it");
    }

    /// @dev Only the ProxyAdmin's owner may upgrade. This is the whole security model now, so it
    ///      gets a test that fails loudly if the admin is ever widened.
    function test_upgradeable_onlyAdminOwnerCanUpgrade() public {
        UniversalRulesPolicy next = new UniversalRulesPolicy();
        ProxyAdmin admin = ProxyAdmin(_urpAdmin());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", makeAddr("stranger")));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(urp)), address(next), "");
    }

    /**
     * @dev THE ONE THAT MATTERS. A mandate's spend counter is live money: it is what stops an agent
     *      re-spending a budget. If an upgrade silently reinterpreted storage, `spent` would move
     *      or reset and every existing mandate would be wrong in the attacker's favour.
     *
     *      Meters a real amount, upgrades, then asserts the counter and every anchor survived.
     */
    function test_upgradeable_storageSurvivesUpgrade() public {
        _initDefault();
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));

        uint256 spentBefore = _spent();
        assertGt(spentBefore, 0, "the counter must have moved, or this test proves nothing");

        UniversalRulesPolicy next = new UniversalRulesPolicy();
        vm.prank(URP_ADMIN_OWNER);
        ProxyAdmin(_urpAdmin()).upgradeAndCall(ITransparentUpgradeableProxy(address(urp)), address(next), "");

        assertEq(_spent(), spentBefore, "spend counter survived the upgrade");
        assertEq(urp.UNIVERSAL_GATEWAY_PC(), GATEWAY, "gateway anchor survived");
        assertEq(urp.UNIVERSAL_EXECUTOR_MODULE(), EXECUTOR_MODULE, "executor anchor survived");
        assertEq(urp.SESSION_ENGINE(), address(engine), "engine anchor survived");
    }

    /**
     * @dev ⚠️ NEVER-DELETE. The storage layout is frozen for the life of the proxy; a reorder does
     *      not fail the build, it reinterprets live mandates. If this test fails, the change is
     *      almost certainly wrong — extend the list only for a genuine append.
     */
    function test_upgradeable_storageLayoutIsFrozen() public view {
        // APPENDED 2026-09-09 for native mode: `_mode` and `_native` after `_credited`, `__gap`
        // shrunk 45 -> 43 in the same commit so it still ends at slot 49. Slots 0-4 are unchanged
        // from the deployed layout — that is what makes this an APPEND and not a reinterpretation.
        // The rejected alternative (renaming `_configs` to `_universal`) would have failed here,
        // which is the whole point of the assertion.
        // APPENDED 2026-09-30 for the SVM rulebook: `_svm` after `_native`, `__gap` shrunk 43 -> 42
        // in the same commit so it still ends at slot 49. Slots 0-6 are unchanged.
        string[] memory expected = new string[](9);
        expected[0] = "UNIVERSAL_GATEWAY_PC";
        expected[1] = "UNIVERSAL_EXECUTOR_MODULE";
        expected[2] = "SESSION_ENGINE";
        expected[3] = "_configs";
        expected[4] = "_credited";
        expected[5] = "_mode";
        expected[6] = "_native";
        expected[7] = "_svm";
        expected[8] = "__gap";

        assertStorageLayout("UniversalRulesPolicy", expected);
    }

    /**
     * ⚠️ NEVER-DELETE (the nineteenth, added 2026-09-17). `Config` AND `NativeConfig` MEMBER SLOTS
     * ARE FROZEN.
     *
     * WHY THE TOP-LEVEL LAYOUT TEST ABOVE IS NOT ENOUGH: it pins the CONTRACT's variables, which is
     * where an appended mapping would show up. A struct that is a mapping VALUE does not appear
     * there at all — its members can be reordered, retyped or removed and
     * `test_upgradeable_storageLayoutIsFrozen` stays green while every live config silently
     * reinterprets.
     *
     * THIS TEST EXISTS BECAUSE A PROPOSAL WOULD HAVE DONE EXACTLY THAT. When the chain moved out of
     * `Config` and into the envelope, the obvious tidy-up was to delete the now-unused
     * `destChainHash` field. Measured consequence: `expectedCEA` packs into slot 0 beside
     * `initialized` and `validUntil`, collapsing two slots, and **`spent` moves from slot 7 to slot
     * 5** — so every existing config would read another field's value as its spend counter. The
     * field stays, unwritten, as a permanent hole. `URP.sol:49`: the layout is load-bearing FOREVER.
     *
     * Read from solc's own `storageLayout` output rather than probed with `vm.load`, for the same
     * reason `assertEmptyStorageLayout` is: there is no runtime way to ask a struct where its
     * members live, and a probe would only catch what it happened to look at.
     */
    function test_upgradeable_configStructLayoutIsFrozen() public view {
        // `destChainHash` at slot 1 is a HOLE, deliberately — see the NatSpec above.
        string[10] memory universalLabels = [
            "initialized",
            "validUntil",
            "destChainHash",
            "expectedCEA",
            "asset",
            "maxAmountPerCall",
            "maxAmountTotal",
            "maxPCPerCall",
            "spent",
            "allowedCalls"
        ];
        uint256[10] memory universalSlots = [uint256(0), 0, 1, 2, 3, 4, 5, 6, 7, 8];
        // OFFSET AND TYPE ARE PINNED TOO, not just the slot. A retype that keeps every slot number —
        // `uint48 validUntil` to `uint64`, `address expectedCEA` to `bytes32` — changes how the
        // packed bytes of slot 0 are read while leaving the slot column untouched. Slot-only
        // assertions would wave that through.
        uint256[10] memory universalOffsets = [uint256(0), 1, 0, 0, 0, 0, 0, 0, 0, 0];
        string[10] memory universalTypes = [
            "t_bool",
            "t_uint48",
            "t_bytes32",
            "t_address",
            "t_address",
            "t_uint256",
            "t_uint256",
            "t_uint256",
            "t_uint256",
            // Prefix only: the artifact appends a build-varying numeric id to composite types.
            "t_array(t_struct(AllowedCall)"
        ];

        _assertStructLayout(
            "Config",
            universalLabels.length,
            _toDyn(universalLabels),
            _toDyn(universalSlots),
            _toDyn(universalOffsets),
            _toDyn(universalTypes)
        );

        string[12] memory nativeLabels = [
            "initialized",
            "validUntil",
            "target",
            "selector",
            "maxValuePerCall",
            "maxValueTotal",
            "valueSpent",
            "amount",
            "amountSpent",
            "maxCalls",
            "callsUsed",
            "pins"
        ];
        // `amount` is an `AmountRule` struct occupying slots 4-6 (bool+uint16 packed, then two
        // uint256s), which is why `amountSpent` lands at 7 and `pins` at 9. Read from the artifact,
        // not derived by hand — a first draft of this test guessed 6 and 8 and was wrong, which is
        // itself the argument for pinning these against solc's output rather than arithmetic.
        uint256[12] memory nativeSlots = [uint256(0), 0, 0, 0, 1, 2, 3, 4, 7, 8, 8, 9];
        // Slot 0 packs four members and slot 8 packs two; those offsets are the whole reason a
        // slot-only assertion would be insufficient here.
        uint256[12] memory nativeOffsets = [uint256(0), 1, 7, 27, 0, 0, 0, 0, 0, 0, 4, 0];
        string[12] memory nativeTypes = [
            "t_bool",
            "t_uint48",
            "t_address",
            "t_bytes4",
            "t_uint256",
            "t_uint256",
            "t_uint256",
            "t_struct(AmountRule)",
            "t_uint256",
            "t_uint32",
            "t_uint32",
            "t_array(t_struct(ArgPin)"
        ];

        _assertStructLayout(
            "NativeConfig",
            nativeLabels.length,
            _toDyn(nativeLabels),
            _toDyn(nativeSlots),
            _toDyn(nativeOffsets),
            _toDyn(nativeTypes)
        );

        // `ModeSlot` gained `vm` on 2026-09-30, PLACED BETWEEN `mode` AND `chainHash`: it packs into
        // slot 0 at byte 2, which no earlier implementation ever wrote, so every live entry reads
        // 0 = EVM. `chainHash` stays at slot 1. This is the assertion that makes that claim true
        // rather than argued; an append after `chainHash` would show `vm` at slot 2 and fail here.
        string[4] memory modeLabels = ["initialized", "mode", "vm", "chainHash"];
        uint256[4] memory modeSlots = [uint256(0), 0, 0, 1];
        uint256[4] memory modeOffsets = [uint256(0), 1, 2, 0];
        string[4] memory modeTypes = ["t_bool", "t_enum(RulesType)", "t_enum(VmFamily)", "t_bytes32"];
        _assertStructLayout(
            "ModeSlot", modeLabels.length, _toDyn(modeLabels), _toDyn(modeSlots), _toDyn(modeOffsets), _toDyn(modeTypes)
        );

        // `SvmConfig`, new on 2026-09-30. Frozen from its first deployment like the other two.
        string[13] memory svmLabels = [
            "initialized",
            "validUntil",
            "expectedCEA",
            "gatewayProgram",
            "asset",
            "maxAmountPerCall",
            "maxAmountTotal",
            "maxPCPerCall",
            "spent",
            "ceaAccounts",
            "programs",
            "pins",
            "dataPins"
        ];
        uint256[13] memory svmSlots = [uint256(0), 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
        uint256[13] memory svmOffsets = [uint256(0), 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        string[13] memory svmTypes = [
            "t_bool",
            "t_uint48",
            "t_bytes32",
            "t_bytes32",
            "t_address",
            "t_uint256",
            "t_uint256",
            "t_uint256",
            "t_uint256",
            "t_array(t_bytes32)",
            "t_array(t_struct(AllowedProgram)",
            "t_array(t_struct(SvmAccountPin)",
            "t_array(t_struct(SvmDataPin)"
        ];
        _assertStructLayout(
            "SvmConfig", svmLabels.length, _toDyn(svmLabels), _toDyn(svmSlots), _toDyn(svmOffsets), _toDyn(svmTypes)
        );
    }

    /// @dev Reads one struct's member slots out of URP's compiled artifact and compares them.
    function _assertStructLayout(
        string memory structName,
        uint256 count,
        string[] memory labels,
        uint256[] memory slots,
        uint256[] memory offsets,
        string[] memory types
    ) internal view {
        string memory artifact = vm.readFile("out/UniversalRulesPolicy.sol/UniversalRulesPolicy.json");
        string[] memory typeKeys = vm.parseJsonKeys(artifact, ".storageLayout.types");

        string memory key;
        string memory prefix = string.concat("t_struct(", structName, ")");
        for (uint256 i; i < typeKeys.length; ++i) {
            if (_startsWith(typeKeys[i], prefix)) {
                key = typeKeys[i];
                break;
            }
        }
        require(bytes(key).length != 0, string.concat("no storageLayout entry for ", structName));

        string memory base = string.concat(".storageLayout.types.['", key, "'].members");

        // The COUNT is asserted as well as each member, so that ADDING a field fails here too — a
        // per-member loop alone would happily ignore a tenth member appended after the ninth.
        // Asserted by probing one past the end: the member at index `count` must not exist.
        assertFalse(
            vm.keyExistsJson(artifact, string.concat(base, "[", vm.toString(count), "].label")),
            string.concat(structName, ": a member was ADDED beyond the frozen set")
        );

        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(base, "[", vm.toString(i), "]");
            assertEq(
                vm.parseJsonString(artifact, string.concat(at, ".label")),
                labels[i],
                string.concat(structName, ": member ", vm.toString(i), " changed name or position")
            );
            assertEq(
                vm.parseJsonUint(artifact, string.concat(at, ".slot")),
                slots[i],
                string.concat(structName, ": ", labels[i], " moved slot - every live config would misread")
            );
            assertEq(
                vm.parseJsonUint(artifact, string.concat(at, ".offset")),
                offsets[i],
                string.concat(structName, ": ", labels[i], " moved within its slot - packed bytes would shift")
            );
            // PREFIX, not equality: composite type keys carry a build-varying numeric id
            // (`t_array(t_struct(AllowedCall)71575_storage)dyn_storage`), so pinning the whole
            // string would break on an unrelated recompile. The prefix still catches a retype.
            assertTrue(
                _startsWith(vm.parseJsonString(artifact, string.concat(at, ".type")), types[i]),
                string.concat(structName, ": ", labels[i], " changed type - same slot, different meaning")
            );
        }
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (sb.length < pb.length) return false;
        for (uint256 i; i < pb.length; ++i) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }

    function _toDyn(string[10] memory a) internal pure returns (string[] memory out) {
        out = new string[](10);
        for (uint256 i; i < 10; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(string[12] memory a) internal pure returns (string[] memory out) {
        out = new string[](12);
        for (uint256 i; i < 12; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(uint256[10] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(uint256[12] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](12);
        for (uint256 i; i < 12; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(string[4] memory a) internal pure returns (string[] memory out) {
        out = new string[](4);
        for (uint256 i; i < 4; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(uint256[4] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(string[13] memory a) internal pure returns (string[] memory out) {
        out = new string[](13);
        for (uint256 i; i < 13; ++i) {
            out[i] = a[i];
        }
    }

    function _toDyn(uint256[13] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](13);
        for (uint256 i; i < 13; ++i) {
            out[i] = a[i];
        }
    }

    /// @dev TUP stores its admin in the ERC-1967 admin slot; it is created by the proxy's own
    ///      constructor and is not returned anywhere, so it must be read from that slot.
    function _urpAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(urp), ERC1967Utils.ADMIN_SLOT))));
    }

    /**
     * @dev ⚠️ NEVER-DELETE (the seventeenth). URP's EXACT external selector set.
     *
     *      URP is the security boundary AND it is upgradeable, so an external function appearing on
     *      it that nobody intended is exactly the thing worth pinning. An EXACT set, not a denylist:
     *      a negative assertion cannot fail against a MISNAMED addition, which is the defect class
     *      this form exists to catch.
     *
     *      Extend this list ONLY for a deliberate addition, in the same commit that adds it.
     */
    function test_URP_exactSelectorSet() public view {
        bytes4[] memory expected = new bytes4[](18);
        uint256 i;

        // Wiring anchors and the public constant. Addressed by SIGNATURE, not `.selector`: solc
        // does not expose a `.selector` member on a public state variable's or constant's
        // auto-generated getter.
        expected[i++] = bytes4(keccak256("SEND_OUTBOUND_SELECTOR()"));
        expected[i++] = bytes4(keccak256("SESSION_ENGINE()"));
        expected[i++] = bytes4(keccak256("UNIVERSAL_EXECUTOR_MODULE()"));
        expected[i++] = bytes4(keccak256("UNIVERSAL_GATEWAY_PC()"));
        expected[i++] = bytes4(keccak256("version()"));

        // initialisation
        expected[i++] = UniversalRulesPolicy.initialize.selector;
        expected[i++] = UniversalRulesPolicy.initializeWithMultiplexer.selector;

        // the engine-facing check
        expected[i++] = UniversalRulesPolicy.checkAction.selector;

        // assertions — BOTH overloads, addressed by signature because `.selector` is ambiguous
        expected[i++] = bytes4(keccak256("assertSpent(bytes32,address,uint256)"));
        expected[i++] = bytes4(keccak256("assertSpent(bytes32,address,uint256,uint256,uint32)"));

        // the refund path
        expected[i++] = UniversalRulesPolicy.creditRevert.selector;
        expected[i++] = UniversalRulesPolicy.isCredited.selector;

        // views
        expected[i++] = UniversalRulesPolicy.getConfig.selector;
        expected[i++] = UniversalRulesPolicy.getNativeConfig.selector;
        // Added 2026-09-30 with the SVM rulebook — the third config getter, one per rulebook.
        expected[i++] = UniversalRulesPolicy.getSvmConfig.selector;
        expected[i++] = UniversalRulesPolicy.getMode.selector;
        // Added 2026-09-17 with chain-derived mode. Exposes the hash URP derives NATIVE from, so the
        // deploy script asserts what URP will ACTUALLY use rather than recomputing the formula and
        // agreeing with itself. This test failing on the day the getter landed is the test working.
        expected[i++] = UniversalRulesPolicy.pushChainHash.selector;

        expected[i++] = UniversalRulesPolicy.supportsInterface.selector;

        assertEq(i, 18, "the hard-coded list must be complete");
        assertSelectorSet("UniversalRulesPolicy", expected);
    }

    /**
     * @dev DECISION 47 — pre-upgrade universal mandates keep working with NO migration.
     *
     *      This is the property the whole append-only storage design exists to deliver, and it is
     *      the one that would fail silently if the layout had been reordered. A config written
     *      BEFORE native mode existed has an EMPTY `_mode` slot; `checkAction`'s routing sends an
     *      empty slot to `_checkUniversal`, which is exactly right.
     *
     *      SIMULATING A PRE-UPGRADE CONFIG HONESTLY. The current code writes `_mode` on every init,
     *      so a config created here is NOT pre-upgrade-shaped. The distinguishing feature of a real
     *      one is precisely that `_mode` was never written — the slot did not exist when the config
     *      was created. So the mode slot is zeroed with `vm.store` after init, reproducing the exact
     *      storage state the deployed contract holds today: `_configs` populated, `_mode` empty.
     *
     *      That is a state manipulation, not a mock: nothing supplies behaviour to the code under
     *      test. It only removes a write that the pre-upgrade implementation never made.
     *
     *      ⚠️ AMENDED 2026-09-09 (Phase 3b, review §2.1/§4.1). This test previously asserted that
     *      `getMode` REPORTS a legacy config as uninitialised. That was the symptom of a real bug
     *      dressed as a property: because the re-init guard read the same empty slot, a pre-upgrade
     *      config was RE-INITIALISABLE — its `spent` could be reset to zero, or its mode flipped to
     *      NATIVE, through the owner door. `_modeOf` is now legacy-aware, so the truthful statement
     *      is TWO separate facts, asserted separately:
     *        1. the RAW SLOT is still empty — nothing moved, which is the storage claim;
     *        2. the DERIVED view reports `(true, UNIVERSAL)` — which is what the config actually is.
     */
    function test_upgradeable_preUpgradeUniversalConfigStillValidates() public {
        _initDefault();
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));
        uint256 spentBefore = _spent();

        bytes32 modeSlot = _modeSlotOf(CID, ACCOUNT);
        vm.store(address(urp), modeSlot, bytes32(0));

        // 1. the raw slot is empty — the pre-upgrade storage state, unmoved
        assertEq(vm.load(address(urp), modeSlot), bytes32(0), "the raw _mode slot is empty");
        // 2. and the derived view tells the truth about what the config IS
        assertTrue(urp.getMode(CID, ACCOUNT).initialized, "a legacy config reports as initialised");
        assertEq(uint8(urp.getMode(CID, ACCOUNT).mode), uint8(RulesType.UNIVERSAL), "and reports as UNIVERSAL");

        UniversalRulesPolicy next = new UniversalRulesPolicy();
        vm.prank(URP_ADMIN_OWNER);
        ProxyAdmin(_urpAdmin()).upgradeAndCall(ITransparentUpgradeableProxy(address(urp)), address(next), "");

        // Still routes to the universal gauntlet and still meters, with no migration of any kind.
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));

        assertEq(_spent(), spentBefore + 1 ether, "the pre-upgrade config still meters through gates 1-16");
        assertEq(vm.load(address(urp), modeSlot), bytes32(0), "and its raw _mode slot is STILL empty");
        assertTrue(urp.getMode(CID, ACCOUNT).initialized, "and it still reports as initialised");
    }

    /**
     * @dev ⚠️ NEVER-DELETE — the EIGHTEENTH. Added 2026-09-09 (Phase 3b, review §2.1).
     *
     *      THE TEST THAT WOULD HAVE CAUGHT THE BUG. A pre-upgrade universal config has an empty
     *      `_mode` slot, and the first native-mode implementation keyed its re-initialisation guard
     *      on that slot alone. So every config that exists on Donut today was re-initialisable
     *      through the owner door: re-init UNIVERSAL reset `spent` to zero; re-init NATIVE flipped
     *      the mode under live universal data.
     *
     *      Reach was owner-door only — `grantRules` always mints a fresh permission id, and the
     *      agent door cannot target the engine — so it was owner self-harm rather than an agent
     *      escalation. It is fixed anyway: it silently removed a documented invariant from exactly
     *      the state an upgrade must not weaken.
     *
     *      If this test starts passing for the wrong reason, check that `_modeOf` still consults
     *      `_configs[..].initialized` and not just `_mode`.
     */
    function test_upgradeable_preUpgradeConfigRefusesReinit() public {
        _initDefault();
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));
        uint256 spentBefore = _spent();
        assertGt(spentBefore, 0, "the counter must have moved, or this test proves nothing");

        // The legacy shape: _configs live, _mode never written.
        vm.store(address(urp), _modeSlotOf(CID, ACCOUNT), bytes32(0));

        // (a) re-init as UNIVERSAL would have RESET `spent`.
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_defaultConfig()));

        // (b) re-init as NATIVE would have FLIPPED the mode under live universal data.
        NativeConfig memory native;
        native.validUntil = VALID_UNTIL;
        native.target = PROTOCOL;
        native.selector = SWAP_SELECTOR;
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, nativeInitData(native));

        // Neither attempt touched anything.
        assertEq(_spent(), spentBefore, "spend counter untouched by the refused re-inits");
        assertEq(urp.getConfig(CID, ACCOUNT).asset, ASSET, "and the live config is still readable");
    }

    /// @dev `_mode` is slot 5: keccak(account . keccak(multiplexer . keccak(configId . 5))).
    function _modeSlotOf(ConfigId id, address account) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(account, keccak256(abi.encode(address(engine), keccak256(abi.encode(id, uint256(5))))))
            );
    }

    /// The hand-hashed constant must equal the interface's own selector.
    function test_sendOutboundSelector_matchesHarness() public view {
        assertEq(urp.SEND_OUTBOUND_SELECTOR(), SEND_OUTBOUND_SELECTOR, "URP constant == harness constant");
    }

    function test_supportsInterface() public view {
        assertTrue(urp.supportsInterface(type(IActionPolicy).interfaceId), "IActionPolicy");
        assertTrue(urp.supportsInterface(type(IPolicy).interfaceId), "IPolicy");
        assertTrue(urp.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(urp.supportsInterface(0xdeadbeef), "unknown id");
    }

    /**
     * getConfig round-trips every field, including the deep-copied allow-list.
     *
     * `destChainHash` IS DELIBERATELY NOT ASSERTED HERE ANY MORE. Since 2026-09-17 it is a v2 relic:
     * the slot is kept so `Config`'s layout never moves, but nothing writes it, and the chain of a
     * mandate lives on `getMode(...).chainHash` where it has been verified against the asset. The
     * assertion moved rather than vanished — see the `chainHash` check below.
     */
    function test_getConfig_roundTripsIncludingAllowList() public {
        _initDefault();
        Config memory got = urp.getConfig(CID, ACCOUNT);

        // The chain, from its one home. Literal, not recomputed from the helper's own constant.
        assertEq(
            urp.getMode(CID, ACCOUNT).chainHash,
            0xafa90c317deacd3d68f330a30f96e4fa7736e35e8d1426b2e1b2c04bce1c2fb7,
            "chain recorded on the mode slot"
        );
        assertEq(got.destChainHash, bytes32(0), "the destChainHash relic is never written");

        assertTrue(got.initialized, "initialized set by init, not by _store");
        assertEq(got.validUntil, VALID_UNTIL, "validUntil");
        assertEq(got.expectedCEA, CEA, "expectedCEA");
        assertEq(got.asset, ASSET, "asset");
        assertEq(got.maxAmountPerCall, 100 ether, "maxAmountPerCall");
        assertEq(got.maxAmountTotal, 1000 ether, "maxAmountTotal");
        assertEq(got.maxPCPerCall, 5 ether, "maxPCPerCall");
        assertEq(got.spent, 0, "spent starts at zero");
        assertEq(got.allowedCalls.length, 1, "allow-list deep-copied");
        assertEq(got.allowedCalls[0].target, PROTOCOL, "rule target");
        assertEq(got.allowedCalls[0].selector, SWAP_SELECTOR, "rule selector");
        assertEq(got.allowedCalls[0].beneficiaryOffset, BENEFICIARY_OFFSET, "rule offset");
        assertTrue(got.allowedCalls[0].hasBeneficiary, "rule hasBeneficiary");
        assertEq(got.allowedCalls[0].maxValue, 1 ether, "rule maxValue");
    }

    /// `spent` supplied in initData is ignored — _store forces it to zero.
    function test_init_ignoresSuppliedSpent() public {
        Config memory cfg = _defaultConfig();
        cfg.spent = 500 ether;
        _init(cfg);
        assertEq(_spent(), 0, "supplied spent ignored");
    }

    /// @dev The chain hash is asserted as a LITERAL keccak of the helper's own chain string, not as
    ///      `keccak256(bytes(CHAIN_SEPOLIA))` recomputed here — an assertion that recomputes the
    ///      value under test agrees with itself by construction. This one fails if the envelope
    ///      stops carrying the chain the config was granted for.
    function test_init_emitsBothPolicySetEvents() public {
        vm.expectEmit(true, true, true, true, address(urp));
        // `vm` ADDED 2026-09-30 with the SVM rulebook: an `eip155:` universal grant reports EVM.
        emit IUniversalRulesPolicy.RulesConfigured(
            CID,
            address(engine),
            ACCOUNT,
            RulesType.UNIVERSAL,
            VmFamily.EVM,
            0xafa90c317deacd3d68f330a30f96e4fa7736e35e8d1426b2e1b2c04bce1c2fb7
        );
        vm.expectEmit(true, true, true, true, address(urp));
        emit IPolicy.PolicySet(CID, address(engine), ACCOUNT);
        _initDefault();
    }

    function test_init_rejectsZeroAssetAndZeroCEA() public {
        Config memory noAsset = _defaultConfig();
        noAsset.asset = address(0);
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.InvalidConfigField.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(noAsset));

        Config memory noCEA = _defaultConfig();
        noCEA.expectedCEA = address(0);
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.InvalidConfigField.selector);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(noCEA));
    }

    /// §6.1: a per-call cap of zero is a LEGAL redeploy-only mandate. Do not reject it at init.
    function test_init_acceptsZeroPerCallCap() public {
        Config memory cfg = _defaultConfig();
        cfg.maxAmountPerCall = 0;
        _init(cfg);
        assertEq(urp.getConfig(CID, ACCOUNT).maxAmountPerCall, 0, "zero per-call cap accepted");
    }

    // ═════════════════════════════════ U-08 ═════════════════════════════════

    function test_U08_Expiry_Semantics() public {
        // init with validUntil == 0
        Config memory zero = _defaultConfig();
        zero.validUntil = 0;
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, uint48(0)));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(zero));

        // init with validUntil in the past
        Config memory past = _defaultConfig();
        past.validUntil = uint48(block.timestamp - 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, past.validUntil));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(past));

        // init with validUntil exactly now — also refused: "in the future" is strict
        Config memory now_ = _defaultConfig();
        now_.validUntil = uint48(block.timestamp);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidExpiry.selector, now_.validUntil));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(now_));

        // a live config validates; once expired it rejects everything
        _initDefault();
        assertEq(_check(0, _goodRequest(1 ether)), 0, "live mandate validates");

        vm.warp(uint256(VALID_UNTIL) + 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.RulesExpired.selector, VALID_UNTIL));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));

        // the boundary itself passes: gate 2 is `block.timestamp > validUntil`
        vm.warp(uint256(VALID_UNTIL));
        assertEq(_check(0, _goodRequest(1 ether)), 0, "expiry boundary is inclusive");
    }

    /// type(uint48).max is "never" written explicitly — there is no silent-forever config.
    function test_U08_NeverExpires_IsExplicit() public {
        Config memory cfg = _defaultConfig();
        cfg.validUntil = type(uint48).max;
        _init(cfg);

        vm.warp(uint256(type(uint48).max) - 1);
        assertEq(_check(0, _goodRequest(1 ether)), 0, "explicit never still validates far in the future");
    }

    // ═════════════════════════════════ U-20 ═════════════════════════════════

    function _nRules(uint256 n) internal pure returns (AllowedCall[] memory rules) {
        rules = new AllowedCall[](n);
        for (uint256 i; i < n; ++i) {
            rules[i] = AllowedCall({
                target: address(uint160(uint256(keccak256(abi.encode("protocol", i))))),
                selector: bytes4(keccak256(abi.encode("fn", i))),
                beneficiaryOffset: BENEFICIARY_OFFSET,
                hasBeneficiary: true,
                maxValue: 1 ether
            });
        }
    }

    function test_U20_AllowList_Bounds() public {
        // zero entries
        Config memory empty = _config(new AllowedCall[](0));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AllowListOutOfRange.selector, uint256(0)));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(empty));

        // 33 entries
        Config memory tooMany = _config(_nRules(33));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AllowListOutOfRange.selector, uint256(33)));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(tooMany));

        // 1 entry initialises
        _initDefault();
        assertEq(urp.getConfig(CID, ACCOUNT).allowedCalls.length, 1, "1 entry accepted");

        // 32 entries initialise, under a different config id
        ConfigId other = ConfigId.wrap(bytes32(uint256(0xBEEF)));
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, other, universalInitData(_config(_nRules(32))));
        assertEq(urp.getConfig(other, ACCOUNT).allowedCalls.length, 32, "32 entries accepted");
    }

    /// The worst case the bound permits: a 32-entry allow-list validating a 10-entry payload.
    /// The number is asserted because "a sane gas budget" is unassertable — a test that cannot
    /// fail is worse than no test.
    function test_U20_WorstCaseGas() public {
        AllowedCall[] memory rules = _nRules(32);
        _init(_config(rules));

        // Every entry targets the LAST rule, so each lookup walks the full 32-entry scan.
        AllowedCall memory last = rules[31];
        Multicall[] memory calls = new Multicall[](10);
        for (uint256 i; i < 10; ++i) {
            calls[i] =
                Multicall({ to: last.target, value: 0, data: abi.encodeWithSelector(last.selector, uint256(i), CEA) });
        }

        bytes memory data = _requestData(1 ether, calls);

        vm.prank(address(engine));
        uint256 before = gasleft();
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        uint256 gasUsed = before - gasleft();

        emit log_named_uint("U-20 worst-case checkAction gas", gasUsed);
        assertLt(gasUsed, 500_000, "32-rule allow-list x 10-entry payload stays under budget");
    }

    // ═════════════════════════════════ U-02 ═════════════════════════════════

    /// ⚠️ NEVER-DELETE. No agent-reachable path re-initialises a config or reduces `spent`.
    function test_U02_AgentCannotReset() public {
        _initDefault();
        assertEq(_check(0, _goodRequest(10 ether)), 0, "budget consumed");
        assertEq(_spent(), 10 ether, "spent advanced");

        // (a) re-initialisation is refused, even from the real engine. This is what turns the
        //     engine's owner-only in-place counter-reset lever into a wall.
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_defaultConfig()));
        assertEq(_spent(), 10 ether, "spent survives the refused re-init");

        // (b) creditRevert from any non-module caller reverts — the agent cannot fabricate a
        //     failure to refill its own budget.
        vm.prank(AGENT);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, AGENT));
        urp.creditRevert(CID, ACCOUNT, keccak256("tx"), 10 ether);

        vm.prank(ACCOUNT);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, ACCOUNT));
        urp.creditRevert(CID, ACCOUNT, keccak256("tx"), 10 ether);

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, address(engine))
        );
        urp.creditRevert(CID, ACCOUNT, keccak256("tx"), 10 ether);

        assertEq(_spent(), 10 ether, "spent never reduced by an agent-reachable path");
    }

    // ═════════════════════════════════ U-03 ═════════════════════════════════
    // One negative test per gate, each hitting its NAMED error, each leaving spent untouched.

    function test_U03_gate1_NotInitialized() public {
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.NotInitialized.selector, CID, ACCOUNT));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));
    }

    function test_U03_gate2_MandateExpired() public {
        _initDefault();
        vm.warp(uint256(VALID_UNTIL) + 1);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.RulesExpired.selector, VALID_UNTIL));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate3_InvalidTarget() public {
        _initDefault();
        address notGateway = makeAddr("someOtherPushContract");
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidTarget.selector, notGateway));
        urp.checkAction(CID, ACCOUNT, notGateway, 0, _goodRequest(1 ether));
        assertEq(_spent(), 0, "nothing spent");
    }

    /// Gate 4 case (a): no selector exists to report, so this is NOT InvalidSelector(bytes4(0)).
    function test_U03_gate4a_CalldataTooShort() public {
        _initDefault();
        bytes memory tooShort = hex"112233";
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.CalldataTooShort.selector, uint256(3)));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, tooShort);
        assertEq(_spent(), 0, "nothing spent");
    }

    /// The discriminator really is distinct: an all-zero 4-byte selector — which an attacker can
    /// send freely — reaches gate 4b and reports InvalidSelector(0x00000000), not CalldataTooShort.
    function test_U03_gate4a_ZeroSelectorIsNotConflated() public {
        _initDefault();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidSelector.selector, bytes4(0)));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, hex"00000000");
    }

    function test_U03_gate4b_InvalidSelector() public {
        _initDefault();
        bytes4 wrong = bytes4(keccak256("someOtherGatewayFunction()"));
        bytes memory data = abi.encodePacked(wrong, new bytes(MIN_OUTBOUND_BODY_LEN));
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidSelector.selector, wrong));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    /// Gate 4 case (c): correct selector, body one byte below the floor.
    function test_U03_gate4c_MalformedOutboundRequest() public {
        _initDefault();
        bytes memory data = abi.encodePacked(SEND_OUTBOUND_SELECTOR, new bytes(MIN_OUTBOUND_BODY_LEN - 1));
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.MalformedOutboundRequest.selector, data.length)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    /**
     * Gate 4 case (d): the correct selector and a CORRECT-LENGTH body whose internal offsets are
     * structurally malformed. This asserts ONLY that the call reverts, because it has no named
     * error by design: abi.decode fails with a compiler-generated Panic(0x41) or a bare
     * ABI-decoder revert, and naming it would require wrapping the decode in an external call —
     * which the §6.2 safety argument forbids.
     *
     * THIS IS THE SINGLE PERMITTED SELECTOR-LESS expectRevert IN THIS FILE.
     */
    function test_U03_gate4d_MalformedBodyRevertsUnnamed() public {
        _initDefault();

        // Correct length, but the first word (the outer struct offset) points far out of bounds.
        bytes memory body = new bytes(MIN_OUTBOUND_BODY_LEN);
        assembly {
            mstore(add(body, 0x20), 0xffffffffffffffff)
        }
        bytes memory data = abi.encodePacked(SEND_OUTBOUND_SELECTOR, body);
        assertEq(data.length, 4 + MIN_OUTBOUND_BODY_LEN, "length passes gate 4c, so 4d is what fires");

        vm.prank(address(engine));
        vm.expectRevert();
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate5_AssetMismatch() public {
        _initDefault();
        address wrongToken = makeAddr("someOtherPRC20");
        bytes memory data = outboundRequest(wrongToken, 1 ether, 1 ether, ACCOUNT, _goodCalls());
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AssetMismatch.selector, ASSET, wrongToken));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate6_AmountExceedsCap() public {
        _initDefault();
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.AmountExceedsCap.selector, uint256(101 ether), uint256(100 ether)
            )
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(101 ether));
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate7_TotalSpendCapExceeded() public {
        Config memory cfg = _defaultConfig();
        cfg.maxAmountTotal = 150 ether;
        _init(cfg);

        assertEq(_check(0, _goodRequest(100 ether)), 0, "first request fits");
        assertEq(_spent(), 100 ether, "spent advanced");

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector, uint256(200 ether), uint256(150 ether)
            )
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(100 ether));
        assertEq(_spent(), 100 ether, "spent unchanged by the failed request");
    }

    function test_U03_gate8_PCValueExceedsCap() public {
        _initDefault();
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.PCValueExceedsCap.selector, uint256(6 ether), uint256(5 ether)
            )
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 6 ether, _goodRequest(1 ether));
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate9_UncappedGasSwapRejected() public {
        _initDefault();
        bytes memory data = outboundRequest(ASSET, 1 ether, 0, ACCOUNT, _goodCalls());
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.UncappedGasSwapRejected.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate10_InvalidRevertRecipient() public {
        _initDefault();
        bytes memory data = outboundRequest(ASSET, 1 ether, 1 ether, AGENT, _goodCalls());
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidRevertRecipient.selector, ACCOUNT, AGENT)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate11_RecipientMustBeEmpty() public {
        _initDefault();
        bytes memory data = abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: hex"1234",
                token: ASSET,
                amount: 1 ether,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: 1 ether,
                payload: abi.encodeWithSelector(MULTICALL_SELECTOR, _goodCalls()),
                revertRecipient: ACCOUNT
            })
        );
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.RecipientMustBeEmpty.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);
        assertEq(_spent(), 0, "nothing spent");
    }

    /**
     * Gate 12 is what confines the agent to ONE of the CEA's three payload branches.
     *
     * The CEA dispatches on the payload prefix (push-chain-core-contracts/src/cea/CEA.sol:171-179):
     * multicall, migration (MIGRATION_SELECTOR), or — as the `else` fall-through — a single call
     * that performs `recipient.call{value: msg.value}(payload)` against an arbitrary target with
     * the raw payload (CEA.sol:244), bypassing the allow-list, the beneficiary pin and the
     * per-entry value cap entirely.
     *
     * The migration case below already fails by construction, as a non-multicall prefix. It is
     * asserted explicitly so the INTENT is permanent rather than incidental: a future maintainer
     * who loosens gate 12 into "starts with a known selector" breaks this test.
     */
    function test_U03_gate12_PayloadNotMulticall() public {
        _initDefault();

        // (a) an unrelated magic prefix — the CEA's single-call fall-through branch
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.PayloadNotMulticall.selector);
        urp.checkAction(
            CID,
            ACCOUNT,
            GATEWAY,
            0,
            _requestWithPayload(abi.encodeWithSelector(bytes4(keccak256("NOT_MULTICALL")), _goodCalls()))
        );

        // (b) the CEA's MIGRATION branch — explicitly excluded, not merely unmatched
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.PayloadNotMulticall.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestWithPayload(abi.encodePacked(MIGRATION_SELECTOR)));

        // (c) a migration prefix carrying a body, so the rejection is not an artefact of length
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.PayloadNotMulticall.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestWithPayload(abi.encodePacked(MIGRATION_SELECTOR, uint256(1))));

        // (d) an empty payload — the CEA's single-call branch with a raw empty body
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.PayloadNotMulticall.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestWithPayload(""));

        // (e) too short to even carry a prefix
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.PayloadNotMulticall.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestWithPayload(hex"2cc2"));

        assertEq(_spent(), 0, "nothing spent");
    }

    /**
     * Gate 12's UN-NAMED DECODE RESIDUAL — the same situation as gate 4 case (d), one level down.
     *
     * A payload carrying the correct MULTICALL_SELECTOR but an empty or structurally malformed
     * body passes the prefix check and then reverts INSIDE the ABI decoder: a bare revert or a
     * Panic, not PayloadNotMulticall. Verified by compiled probe — both inputs return empty
     * returndata. So this asserts ONLY that the call reverts.
     *
     * It cannot be given a named error without wrapping the decode in `try this.decode(...)`,
     * which would introduce an external call into checkAction and break the §6.2 safety argument.
     * No MIN_MULTICALL_BODY_LEN pre-check is added either: unlike gate 4c, which guards the
     * dominant malformed case on unauthenticated calldata, this decode sits behind eleven gates,
     * so a second hand-derived constant would be more surface than the named error is worth.
     *
     * THIS AND GATE 4(d) ARE THE ONLY TWO SELECTOR-LESS expectReverts IN THIS FILE.
     *
     * WHY THE RETURNDATA IS ASSERTED TOO. A bare `vm.expectRevert()` passes for ANY revert, so on
     * its own it could not distinguish the decoder residual from some later gate firing — a
     * mutation probe confirmed that replacing the decode with a stub still leaves a
     * bare-expectRevert-only version of this test green. Asserting that the returndata is EMPTY
     * pins the actual mechanism: a URP error would be four bytes or more, so empty returndata is
     * positive evidence that the revert came from inside the ABI decoder and not from a named gate.
     */
    function test_U03_gate12_MalformedMulticallBodyRevertsUnnamed() public {
        _initDefault();

        bytes[2] memory payloads = [
            // (a) the selector alone — a correct prefix with a zero-length body
            abi.encodePacked(MULTICALL_SELECTOR),
            // (b) the correct prefix followed by structurally malformed bytes
            abi.encodePacked(MULTICALL_SELECTOR, bytes32(uint256(0xffffffffffff)))
        ];

        for (uint256 i; i < payloads.length; ++i) {
            bytes memory data = _requestWithPayload(payloads[i]);

            // The selector-less assertion the residual requires...
            vm.prank(address(engine));
            vm.expectRevert();
            urp.checkAction(CID, ACCOUNT, GATEWAY, 0, data);

            // ...plus positive evidence of WHICH revert it was.
            vm.prank(address(engine));
            (bool ok, bytes memory ret) =
                address(urp).call(abi.encodeWithSelector(urp.checkAction.selector, CID, ACCOUNT, GATEWAY, 0, data));
            assertFalse(ok, "reverted");
            assertEq(ret.length, 0, "bare decoder revert, not a named URP error");
        }

        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate13_BatchSizeOutOfRange() public {
        _initDefault();
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.BatchSizeOutOfRange.selector, uint256(0)));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, new Multicall[](0)));
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate14_ForbiddenInnerTarget() public {
        _initDefault();
        Multicall[] memory calls = _goodCalls();
        calls[0].to = GATEWAY;
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector, GATEWAY));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, calls));
        assertEq(_spent(), 0, "nothing spent");
    }

    /// Gate 14's "data.length >= 4" arm — a short inner blob has no selector to look up.
    function test_U03_gate14_MalformedInnerCalldata_shortEntry() public {
        _initDefault();
        Multicall[] memory calls = _goodCalls();
        calls[0].data = hex"1122";
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.MalformedInnerCalldata.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, calls));
        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate15_CallNotAllowed() public {
        _initDefault();

        // unlisted target
        Multicall[] memory wrongTarget = _goodCalls();
        address stranger = makeAddr("unlistedProtocol");
        wrongTarget[0].to = stranger;
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CallNotAllowed.selector, stranger, SWAP_SELECTOR)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, wrongTarget));

        // listed target, unlisted selector
        Multicall[] memory wrongSelector = _goodCalls();
        wrongSelector[0].data = abi.encodeWithSelector(POKE_SELECTOR, uint256(1), CEA);
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CallNotAllowed.selector, PROTOCOL, POKE_SELECTOR)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, wrongSelector));

        assertEq(_spent(), 0, "nothing spent");
    }

    function test_U03_gate16_InnerValueExceedsAllowance() public {
        _initDefault();
        Multicall[] memory calls = _goodCalls();
        calls[0].value = 1 ether + 1;
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.InnerValueExceedsAllowance.selector,
                uint256(0),
                uint256(1 ether + 1),
                uint256(1 ether)
            )
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, calls));
        assertEq(_spent(), 0, "nothing spent");
    }

    // ═════════════════════════════════ U-01 ═════════════════════════════════

    /// ⚠️ NEVER-DELETE. The forbidden destination account BEATS the allow-list. Gate 14 runs
    /// before gate 15, so even an owner who explicitly allow-listed their own destination account
    /// cannot hand the agent direct control of everything it holds.
    function test_U01_ForbiddenCEA_BeatsAllowlist() public {
        // The allow-list explicitly contains the destination account.
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
        rules[1] = AllowedCall({
            target: CEA, // the owner listed their own destination account
            selector: POKE_SELECTOR,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: 1 ether
        });
        _init(_config(rules));

        // Sanity: that rule really is in the list, so the test proves ordering, not absence.
        Config memory stored = urp.getConfig(CID, ACCOUNT);
        assertEq(stored.allowedCalls.length, 2, "two rules stored");
        assertEq(stored.allowedCalls[1].target, CEA, "the CEA rule IS allow-listed");

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: CEA, value: 0, data: abi.encodeWithSelector(POKE_SELECTOR) });

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector, CEA));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, calls));
        assertEq(_spent(), 0, "nothing spent");
    }

    /// The other three forbidden destinations, each individually.
    function test_U01_ForbiddenInnerTargets_walletUrpGateway() public {
        _initDefault();

        address[3] memory forbidden = [ACCOUNT, address(urp), GATEWAY];
        for (uint256 i; i < forbidden.length; ++i) {
            Multicall[] memory calls = _goodCalls();
            calls[0].to = forbidden[i];
            vm.prank(address(engine));
            vm.expectRevert(
                abi.encodeWithSelector(UniversalRulesPolicyErrors.ForbiddenInnerTarget.selector, forbidden[i])
            );
            urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, calls));
        }
        assertEq(_spent(), 0, "nothing spent");
    }

    // ═════════════════════════════════ U-04 ═════════════════════════════════

    /// The sell/reinvest leg. Pins Q1-A against a v2-restore of the zero-amount rejection.
    function test_U04_ZeroAmount_RedeployPath() public {
        _initDefault();

        vm.recordLogs();
        assertEq(_check(0, _goodRequest(0)), 0, "zero-amount request PASSES");

        assertEq(_spent(), 0, "spent unchanged");
        assertEq(vm.getRecordedLogs().length, 0, "no OutboundMetered for a zero-amount request");
    }

    /// Zero-amount still runs the full gauntlet — it is not a bypass.
    function test_U04_ZeroAmount_StillGated() public {
        _initDefault();
        Multicall[] memory calls = _goodCalls();
        calls[0].to = makeAddr("unlistedProtocol");
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.CallNotAllowed.selector, calls[0].to, SWAP_SELECTOR)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(0, calls));
    }

    // ═════════════════════════════════ U-05 ═════════════════════════════════

    /// A 10-entry payload where only the LAST entry is invalid still kills the whole request.
    function test_U05_LastEntryPoisonsBatch() public {
        _initDefault();

        Multicall[] memory calls = new Multicall[](10);
        for (uint256 i; i < 9; ++i) {
            calls[i] =
                Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(i), CEA) });
        }
        // entry 10: correct target and selector, but the beneficiary is the agent
        calls[9] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(9), AGENT) });

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, CEA, AGENT));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(5 ether, calls));
        assertEq(_spent(), 0, "nothing spent - one bad entry kills the batch");
    }

    // ═════════════════════════════════ U-06 ═════════════════════════════════

    function _nGoodCalls(uint256 n) internal view returns (Multicall[] memory calls) {
        calls = new Multicall[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] =
                Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(i), CEA) });
        }
    }

    function test_U06_BatchBounds() public {
        _initDefault();

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.BatchSizeOutOfRange.selector, uint256(0)));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, _nGoodCalls(0)));

        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.BatchSizeOutOfRange.selector, uint256(11)));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, _nGoodCalls(11)));

        assertEq(_check(0, _requestData(1 ether, _nGoodCalls(1))), 0, "1 entry validates");
        assertEq(_check(0, _requestData(1 ether, _nGoodCalls(10))), 0, "10 entries validate");
    }

    // ═════════════════════════════════ U-07 ═════════════════════════════════

    function test_U07_LifetimeCap_AtTheCrossing() public {
        Config memory cfg = _defaultConfig();
        cfg.maxAmountTotal = 100 ether;
        _init(cfg);

        assertEq(_check(0, _goodRequest(60 ether)), 0, "first fits");
        assertEq(_spent(), 60 ether, "60 spent");

        // exactly at the cap passes
        assertEq(_check(0, _goodRequest(40 ether)), 0, "the crossing point itself is allowed");
        assertEq(_spent(), 100 ether, "exactly at the cap");

        // one wei past reverts
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.TotalSpendCapExceeded.selector, uint256(100 ether + 1), uint256(100 ether)
            )
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1));
        assertEq(_spent(), 100 ether, "unchanged");
    }

    /// §10 item 8: unlimited is type(uint256).max with NO special branch — the comparison
    /// simply never trips.
    function test_U07_UnlimitedNeverTrips() public {
        Config memory cfg = _defaultConfig();
        cfg.maxAmountPerCall = type(uint256).max;
        cfg.maxAmountTotal = type(uint256).max;
        _init(cfg);

        assertEq(_check(0, _goodRequest(type(uint128).max)), 0, "huge amount passes an unlimited cap");
        assertEq(_spent(), type(uint128).max, "accumulated");
    }

    /// A per-call cap of zero bridges nothing but redeploys freely.
    function test_U07_ZeroPerCallCap_RedeploysOnly() public {
        Config memory cfg = _defaultConfig();
        cfg.maxAmountPerCall = 0;
        _init(cfg);

        assertEq(_check(0, _goodRequest(0)), 0, "zero-amount redeploy allowed");

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmountExceedsCap.selector, uint256(1), uint256(0))
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1));
        assertEq(_spent(), 0, "never bridges");
    }

    // ═════════════════════════════════ U-09 ═════════════════════════════════

    /// ⚠️ never-delete pair. The two silent-catastrophe pins, asserted individually.
    function test_U09_RoutingPins() public {
        _initDefault();

        // (a) a non-empty recipient — any use of the gateway's direct-transfer mode
        bytes memory withRecipient = abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: abi.encodePacked(AGENT),
                token: ASSET,
                amount: 1 ether,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: 1 ether,
                payload: abi.encodeWithSelector(MULTICALL_SELECTOR, _goodCalls()),
                revertRecipient: ACCOUNT
            })
        );
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.RecipientMustBeEmpty.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, withRecipient);

        // (b) a refund that lands anywhere but the wallet — failure as an exfiltration route
        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.InvalidRevertRecipient.selector, ACCOUNT, AGENT)
        );
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, AGENT, _goodCalls()));

        assertEq(_spent(), 0, "nothing spent");
    }

    // ═════════════════════════════════ U-10 ═════════════════════════════════

    function test_U10_UncappedGasField() public {
        _initDefault();

        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.UncappedGasSwapRejected.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 0, ACCOUNT, _goodCalls()));

        // non-zero, with a Push-side value inside the cap, passes
        assertEq(
            _check(5 ether, outboundRequest(ASSET, 1 ether, 1, ACCOUNT, _goodCalls())),
            0,
            "any non-zero cap is acceptable; the field only may not be uncapped"
        );
    }

    // ═════════════════════════════════ U-11 ═════════════════════════════════

    function test_U11_Beneficiary_BoundsAndPin() public {
        _initDefault();

        // (a) wrong beneficiary — the agent trading honestly but for itself
        Multicall[] memory wrong = _goodCalls();
        wrong[0].data = abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), AGENT);
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.BeneficiaryMismatch.selector, CEA, AGENT));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, wrong));

        // (b) calldata too short to hold the word at BENEFICIARY_OFFSET. Without the bounds check
        //     this would read adjacent memory, which could be manipulated to pass.
        Multicall[] memory short = _goodCalls();
        short[0].data = abi.encodePacked(SWAP_SELECTOR, uint256(1)); // 36 bytes: offset+32 > length
        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.MalformedInnerCalldata.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, short));

        assertEq(_spent(), 0, "nothing spent");
    }

    /// A rule with hasBeneficiary == false skips the check entirely — and its offset is ignored.
    function test_U11_NoBeneficiaryRuleSkipsTheCheck() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL,
            selector: POKE_SELECTOR,
            beneficiaryOffset: 65_535, // a dead offset — never read, because hasBeneficiary is false
            hasBeneficiary: false,
            maxValue: 0
        });
        _init(_config(rules));

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: PROTOCOL, value: 0, data: abi.encodeWithSelector(POKE_SELECTOR) });

        assertEq(_check(0, _requestData(1 ether, calls)), 0, "no-beneficiary rule validates");
    }

    /**
     * §6.1's accepted asymmetry, characterised: an owner MAY store an offset that can never match
     * real calldata, producing a rule that looks alive and always reverts. This is fail-closed and
     * per-rule, and offsets are tooling-generated (O1/O2) — so it is deliberately not guarded
     * on-chain. NOT a security test; it pins the documented behaviour.
     */
    function test_DeadOffset_FailsClosed() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = AllowedCall({
            target: PROTOCOL, selector: SWAP_SELECTOR, beneficiaryOffset: 65_535, hasBeneficiary: true, maxValue: 0
        });
        _init(_config(rules));

        vm.prank(address(engine));
        vm.expectRevert(UniversalRulesPolicyErrors.MalformedInnerCalldata.selector);
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _requestData(1 ether, _goodCalls()));
    }

    // ═════════════════════════════════ U-12 ═════════════════════════════════

    function test_U12_EffectsLast_MeteringEvent() public {
        _initDefault();

        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.OutboundMetered(CID, address(engine), ACCOUNT, 7 ether);

        assertEq(_check(0, _goodRequest(7 ether)), 0, "validates");
        assertEq(_spent(), 7 ether, "spent advanced by exactly the bridged amount");
    }

    /// Accumulation across several successful checks.
    function test_U12_SpendAccumulates() public {
        _initDefault();
        _check(0, _goodRequest(3 ether));
        _check(0, _goodRequest(4 ether));
        assertEq(_spent(), 7 ether, "accumulated");
    }

    // ═════════════════════════════════ U-13 ═════════════════════════════════

    function test_U13_Credit_ModuleOnly() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        address[3] memory strangers = [AGENT, ACCOUNT, address(engine)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, strangers[i])
            );
            urp.creditRevert(CID, ACCOUNT, keccak256("tx"), 1 ether);
        }

        // the module itself succeeds
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("tx"), 1 ether);
        assertEq(_spent(), 9 ether, "module credit applied");
    }

    // ═════════════════════════════════ U-14 ═════════════════════════════════

    function test_U14_Credit_OncePerId() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        bytes32 txId = keccak256("outbound-1");
        assertFalse(urp.isCredited(txId), "not credited yet");

        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, txId, 2 ether);
        assertTrue(urp.isCredited(txId), "recorded");
        assertEq(_spent(), 8 ether, "applied once");

        vm.prank(EXECUTOR_MODULE);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyCredited.selector, txId));
        urp.creditRevert(CID, ACCOUNT, txId, 2 ether);
        assertEq(_spent(), 8 ether, "second credit changed nothing");

        // a different id still works
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("outbound-2"), 3 ether);
        assertEq(_spent(), 5 ether, "distinct ids credit independently");
    }

    /**
     * §6.4's retryability guarantee, asserted at the level it is actually observable.
     *
     * HONEST SCOPE — read before "strengthening" this. The PRD motivates step 2's ordering by a
     * misrouted call "burning the outboundTxId while crediting nothing". In the shipped code that
     * failure mode is unreachable by construction: every path that skips the credit also REVERTS,
     * so the `_credited` write is unwound with the frame either way. Verified by mutation — moving
     * the idempotency write above the config check leaves all 64 tests green, because the two
     * orderings are externally indistinguishable in a single transaction.
     *
     * So this test does NOT prove the ordering; nothing at this level can, and a test asserting
     * otherwise would be a test that cannot fail. What it proves is the guarantee Push core is
     * actually promised in §7: a credit that arrives early or against the wrong mandate reverts
     * NotInitialized, leaves the id uncredited, and the retry then succeeds.
     *
     * The ordering remains as written because it is the correct source-level expression of that
     * guarantee and it stays correct if a future edit makes a non-reverting skip path reachable.
     */
    function test_U14_MisroutedCredit_IsRetryable() public {
        bytes32 txId = keccak256("outbound-misrouted");
        ConfigId ghost = ConfigId.wrap(bytes32(uint256(0xDEAD)));

        // arrives before the config exists (or against the wrong id)
        vm.prank(EXECUTOR_MODULE);
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.NotInitialized.selector, ghost, ACCOUNT));
        urp.creditRevert(ghost, ACCOUNT, txId, 1 ether);

        assertFalse(urp.isCredited(txId), "the id is still uncredited after the failed call");

        // and the retry against the right config succeeds
        _initDefault();
        _check(0, _goodRequest(10 ether));
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, txId, 1 ether);
        assertEq(_spent(), 9 ether, "retry applied");
    }

    // ═════════════════════════════════ U-15 ═════════════════════════════════

    function test_U15_Credit_Saturates() public {
        _initDefault();
        _check(0, _goodRequest(5 ether));

        // credit far more than was ever spent
        vm.expectEmit(true, true, true, true, address(urp));
        emit IUniversalRulesPolicy.RevertCredited(keccak256("big"), CID, ACCOUNT, 5 ether); // the APPLIED amount

        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("big"), 1000 ether);

        assertEq(_spent(), 0, "saturated at zero, no underflow");
    }

    /// A credit landing after the permission is revoked or expired still applies — the accounting
    /// record survives the permission (§4, §7).
    function test_U15_CreditAfterExpiry_LandsHarmlessly() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        vm.warp(uint256(VALID_UNTIL) + 1); // the mandate can no longer validate anything

        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("late"), 4 ether);
        assertEq(_spent(), 6 ether, "credit still applies to the orphan config");

        // but nothing can be spent through it again
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.RulesExpired.selector, VALID_UNTIL));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(1 ether));
    }

    // ═════════════════════════════════ U-16 ═════════════════════════════════

    function test_U16_AssertSpent_ExactEquality() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        // equality passes
        urp.assertSpent(CID, ACCOUNT, 10 ether);

        // mismatch in BOTH directions reverts — stale beliefs never silently become new budgets
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SpentMismatch.selector, uint256(9 ether), uint256(10 ether)
            )
        );
        urp.assertSpent(CID, ACCOUNT, 9 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SpentMismatch.selector, uint256(11 ether), uint256(10 ether)
            )
        );
        urp.assertSpent(CID, ACCOUNT, 11 ether);
    }

    /// The ruled revision: without the initialized check, a wrong config reads spent == 0 and an
    /// assertion of zero PASSES, letting a change batch proceed on a belief about a ghost.
    function test_U16_AssertSpent_GhostConfigHasNoSilentPass() public {
        ConfigId ghost = ConfigId.wrap(bytes32(uint256(0xABCD)));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.NotInitialized.selector, ghost, ACCOUNT));
        urp.assertSpent(ghost, ACCOUNT, 0);
    }

    /// A credit landing between the owner's read and their submit forces recomposition.
    function test_U16_AssertSpent_CreditForcesRecomposition() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        // the owner reads 10 and composes their batch...
        urp.assertSpent(CID, ACCOUNT, 10 ether);

        // ...a credit lands first...
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("race"), 4 ether);

        // ...so the batch's first entry now fails, and the whole change reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalRulesPolicyErrors.SpentMismatch.selector, uint256(10 ether), uint256(6 ether)
            )
        );
        urp.assertSpent(CID, ACCOUNT, 10 ether);
    }

    // ═════════════════════════════════ U-17 ═════════════════════════════════

    /// A stranger calling initializeWithMultiplexer writes only their OWN msg.sender slice.
    function test_U17_KeyedIsolation() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));
        assertEq(_spent(), 10 ether, "engine-keyed config has real state");

        // A stranger initialises the SAME configId and account with a config of their choosing.
        Config memory attackerCfg = _defaultConfig();
        attackerCfg.maxAmountTotal = type(uint256).max;
        vm.prank(AGENT);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(attackerCfg));

        // The engine-keyed config is untouched — including its spend counter.
        Config memory real = urp.getConfig(CID, ACCOUNT);
        assertEq(real.spent, 10 ether, "engine-keyed spent untouched");
        assertEq(real.maxAmountTotal, 1000 ether, "engine-keyed caps untouched");

        // And the stranger's write did NOT clear the engine's initialized flag: re-init still fails.
        vm.prank(address(engine));
        vm.expectRevert(abi.encodeWithSelector(UniversalRulesPolicyErrors.AlreadyInitialized.selector, CID));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_defaultConfig()));
    }

    /**
     * The structural half of U-17: assertSpent, creditRevert and getConfig take NO multiplexer
     * argument, so no caller can address the stranger's slice through them. Asserted by reading
     * back through the real functions after a stranger has written — every one of them reports the
     * engine's view, never the stranger's.
     */
    function test_U17_NoMultiplexerArgumentReachesTheStrangerSlice() public {
        _initDefault();
        _check(0, _goodRequest(10 ether));

        Config memory strangerCfg = _defaultConfig();
        strangerCfg.spent = 999 ether; // ignored by _store anyway
        vm.prank(AGENT);
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(strangerCfg));

        // getConfig reads the engine slice
        assertEq(urp.getConfig(CID, ACCOUNT).spent, 10 ether, "getConfig is engine-keyed");

        // assertSpent reads the engine slice
        urp.assertSpent(CID, ACCOUNT, 10 ether);

        // creditRevert writes the engine slice
        vm.prank(EXECUTOR_MODULE);
        urp.creditRevert(CID, ACCOUNT, keccak256("t"), 1 ether);
        assertEq(urp.getConfig(CID, ACCOUNT).spent, 9 ether, "creditRevert is engine-keyed");
    }

    // ═════════════════════════════════ U-18 ═════════════════════════════════

    /**
     * The URP half. `spent` is written during validation and survives only because validation and
     * dispatch share ONE transaction — so when the surrounding call frame reverts, the write is
     * unwound with it. Proven here by reverting the frame around a successful checkAction.
     *
     * WHAT THIS DOES NOT PROVE, stated because the distinction matters: this is the ATOMICITY half
     * of "optimistic but atomic", not the effects-LAST half. Effects-last is not observable from
     * outside a single transaction — verified by mutation, hoisting `cfg.spent = newSpent` above
     * the inner-call gauntlet leaves all 64 tests green, because the gates that would then run
     * after the write all revert, unwinding it. The ordering is kept because it is what makes the
     * atomicity argument hold without depending on every later gate reverting; §10 item 4 forbids
     * splitting validation from dispatch, which is the change that WOULD make this observable.
     *
     * The wallet half (a real dispatch failure through AGW) arrives in Phase 3c.
     */
    function test_U18_ExecutionRevert_UnwindsSpend() public {
        _initDefault();

        try this.checkThenRevert() {
            fail();
        } catch { }

        assertEq(_spent(), 0, "the optimistic write was unwound with the frame");
    }

    /// @dev External so the try/catch above gets its own frame. Validates, then reverts.
    function checkThenRevert() external {
        vm.prank(address(engine));
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, _goodRequest(10 ether));
        assertEq(_spent(), 10 ether, "spent really was written inside the frame");
        revert("dispatch failed");
    }

    // ═════════════════════════════════ U-21 ═════════════════════════════════

    /**
     * ⚠️ NEVER-DELETE. THIS TEST EXISTS TO FAIL.
     *
     * MIN_OUTBOUND_BODY_LEN is a hand-derived number. If anyone adds a field to
     * UniversalOutboundTxRequest this breaks immediately, instead of silently loosening gate 4c
     * into a check that passes everything.
     */
    function test_U21_MinBodyLen_IsPinnedToTheStruct() public pure {
        assertEq(abi.encode(emptyOutboundRequest()).length, MIN_OUTBOUND_BODY_LEN, "352 pin");
    }

    // ═════════════════════════════════ U-22 ═════════════════════════════════

    /**
     * CHARACTERISATION TEST — NOT A SECURITY TEST.
     *
     * abi.decode ignores trailing bytes, so appending garbage to a valid encoding still decodes
     * and still passes the gauntlet. This pins that behaviour so a future reader does not mistake
     * gate 4 for a canonical-encoding check.
     *
     * The safety argument lives elsewhere, in two independent places: the whole executionCalldata
     * is bound into the wallet's operation hash (so appended bytes invalidate the signature), and
     * the signature is verified LAST (SmartSession.sol:344-352), so anything a policy wrote on
     * garbage-appended calldata is unwound in full. Neither reason depends on the other.
     */
    function test_U22_TrailingGarbage_Decodes() public {
        _initDefault();

        bytes memory clean = _goodRequest(1 ether);
        bytes memory garbled = abi.encodePacked(clean, keccak256("garbage"));
        assertEq(garbled.length, clean.length + 32, "32 arbitrary bytes appended");

        assertEq(_check(0, garbled), 0, "still decodes and still passes - gate 4 is not canonical");
        assertEq(_spent(), 1 ether, "and meters normally");
    }
}
