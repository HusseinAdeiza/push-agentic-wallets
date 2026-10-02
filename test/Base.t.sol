// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";

import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context } from "smartsessions/DataTypes.sol";

import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { AgentValidator } from "../src/validators/AgentValidator.sol";

import { UniversalRulesPolicy } from "../src/policies/UniversalRulesPolicy.sol";

import { AGW } from "../src/AGW.sol";

import { AGWFactory } from "../src/AGWFactory.sol";

import {
    Config,
    Multicall,
    MULTICALL_SELECTOR,
    NativeConfig,
    NativeTerms,
    OWNER_LANE_FLAG,
    OwnerIntent,
    RulesType,
    SvmTerms,
    UniversalOutboundTxRequest,
    UniversalTerms
} from "../src/libraries/Types.sol";

/**
 * @title  BaseTest — the shared harness every v3 suite extends.
 * @notice Deploys only what exists today: the permission engine and the session validator.
 *         URP, the wallet and the factory are added to this harness by their own phases.
 */
abstract contract BaseTest is Test {
    // ───────────────────────────── deployments ─────────────────────────────

    SmartSession internal engine;
    AgentValidator internal validator;

    /// @dev THE REAL URP — a TransparentUpgradeableProxy in front of `urpImplementation`. Every
    ///      suite drives this, so every test runs against the deployed shape.
    UniversalRulesPolicy internal urp;

    /// @dev The URP IMPLEMENTATION. Holds no config of its own; its initialiser is disabled.
    UniversalRulesPolicy internal urpImplementation;

    /// @dev The proxy itself, typed. Needed to reach the admin, which TUP creates internally.
    TransparentUpgradeableProxy internal urpProxy;

    /// @dev The wallet IMPLEMENTATION. Clones delegatecall into it; it is never driven directly.
    AGW internal walletImpl;

    /// @dev THE REAL FACTORY — an ERC-1967 proxy in front of `factoryLogic`. Every wallet in every
    ///      suite is now deployed through it, so the wallet's `_factory()` immutable arg is the
    ///      proxy address, exactly as in production. (Phase 3 used a makeAddr placeholder.)
    AGWFactory internal factory;
    AGWFactory internal factoryLogic;

    /// @dev The proxy address, for tests that want it as a plain address.
    address internal FACTORY;

    address internal FACTORY_ADMIN;

    /// @dev Owner of URP's ProxyAdmin — the only account that can upgrade the policy.
    address internal URP_ADMIN_OWNER;

    // ─────────────────────────── named addresses ───────────────────────────

    address internal GATEWAY;
    address internal EXECUTOR_MODULE;
    address internal RELAYER;
    address internal OWNER;
    address internal AGENT;

    // ───────────────────────────── constants ─────────────────────────────

    /// @dev Asserted against IUniversalGatewayPC.sendUniversalTxOutbound.selector in the smoke test.
    ///
    ///      DELIBERATELY HAND-TYPED, not imported from Types.sol. The production constant
    ///      lives there and both the wallet and URP read it from that one place; this copy is the
    ///      INDEPENDENT WITNESS that the shared constant is the value the gateway actually exposes.
    ///      Importing it here would make the test agree with the source by construction and assert
    ///      nothing — a mock supplying the behaviour under test. URP's smoke test pins the two
    ///      against each other, so an edit to either side fails the build rather than passing quietly.
    bytes4 internal constant SEND_OUTBOUND_SELECTOR =
        bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

    /// @dev The smallest possible ABI encoding of a UniversalOutboundTxRequest argument list.
    ///      Derivation (Types.sol:9-18): 32 (outer offset word — the struct is dynamic,
    ///      so abi.encode prefixes a pointer) + 256 (eight head words) + 32 + 32 (length words for
    ///      the two empty dynamic `bytes` fields, `recipient` and `payload`) = 352.
    ///      DO NOT hand-maintain this number: it is pinned against abi.encode of an empty request,
    ///      so a field added to the struct fails the build instead of silently loosening URP's
    ///      gate 4c into a check that passes everything.
    uint256 internal constant MIN_OUTBOUND_BODY_LEN = 352;

    // ─────────────────────────────── setUp ───────────────────────────────

    function setUp() public virtual {
        // Named addresses first — URP's constructor consumes two of them.
        GATEWAY = makeAddr("universalGatewayPC");
        EXECUTOR_MODULE = makeAddr("universalExecutorModule");
        RELAYER = makeAddr("relayer");
        OWNER = makeAddr("owner");
        AGENT = makeAddr("agent");

        FACTORY_ADMIN = makeAddr("factoryAdmin");

        engine = new SmartSession();
        validator = new AgentValidator();

        // URP BEHIND ITS REAL PROXY, not a bare instance. Every suite therefore exercises the
        // deployed shape: storage in the proxy, logic reached by delegatecall. A harness that
        // deployed URP directly would test a contract that does not exist in production, and
        // would silently miss anything that only breaks through a delegatecall.
        URP_ADMIN_OWNER = makeAddr("urpAdminOwner");
        urpImplementation = new UniversalRulesPolicy();
        urpProxy = new TransparentUpgradeableProxy(
            address(urpImplementation),
            URP_ADMIN_OWNER,
            abi.encodeCall(UniversalRulesPolicy.initialize, (GATEWAY, EXECUTOR_MODULE, address(engine)))
        );
        urp = UniversalRulesPolicy(address(urpProxy));

        walletImpl = new AGW(address(engine), address(urp), address(validator), GATEWAY);

        // ERC-1967 proxy -> factory logic, initialised in the SAME transaction, so no
        // initialisation front-run window exists (factory PRD §8 step 3).
        factoryLogic = new AGWFactory();
        factory = AGWFactory(
            address(
                new ERC1967Proxy(
                    address(factoryLogic), abi.encodeCall(AGWFactory.initialize, (FACTORY_ADMIN, address(walletImpl)))
                )
            )
        );
        FACTORY = address(factory);

        vm.label(address(engine), "SmartSession");
        vm.label(address(validator), "AgentValidator");
        vm.label(address(urp), "UniversalRulesPolicy");
        vm.label(address(walletImpl), "AGW(impl)");
        vm.label(address(factory), "AGWFactory(proxy)");
        vm.label(address(factoryLogic), "AGWFactory(logic)");
    }

    // ─────────────────────────── wallet clone helper ───────────────────────────

    /**
     * @notice Deploy an initialised wallet clone owned by `walletOwner`.
     * @dev    THE REAL PATH, as of Phase 4: `deployWallet` called BY THE OWNER. The factory assigns
     *         the index, derives the salt, writes the 40-byte immutable args (owner 0-19, factory
     *         20-39) and calls `initializeAccount` itself. Nothing here simulates the factory any
     *         more, so every earlier suite now exercises the production deployment path.
     */
    function newWallet(address walletOwner) internal returns (AGW wallet) {
        vm.prank(walletOwner);
        return AGW(payable(factory.deployWallet("")));
    }

    // ─────────────────── URP gates seen through the engine ───────────────────

    /**
     * @notice Expect a URP gate to fire, as it surfaces THROUGH the engine.
     * @dev    SHARED HELPER — use this in every suite that drives URP through SmartSession, and in
     *         Phase 5. Do not hand-encode this at call sites.
     *
     *         The engine truncates policy revert data to 32 bytes and rewraps it
     *         (`PolicyLib.sol:139-152`, `_maxCopy: 32`), so a URP error does NOT arrive as itself:
     *         it arrives as `PolicyCheckReverted(bytes32)` carrying the policy's first word — the
     *         4-byte selector LEFT-ALIGNED, the remaining 28 bytes zero. Naming the gate this way
     *         is what makes a negative test say WHICH gate fired instead of "something reverted".
     *
     *         WHAT "FIRST 32 BYTES" ACTUALLY MEANS, measured rather than assumed: for a NO-ARGUMENT
     *         error the word is the 4-byte selector left-aligned and 28 zero bytes. For an error
     *         WITH arguments it is the selector followed by the first 28 bytes of the first
     *         argument — e.g. `PCValueExceedsCap(6 ether, 5 ether)` surfaces as
     *         `9ca1b7e2…53444835`, those trailing bytes being the high half of 6 ether
     *         (0x53444835ec580000). So the caller must pass the full ABI-encoded revert data, and
     *         this helper truncates it exactly as the engine does.
     */
    function expectUrpGate(bytes memory urpRevertData) internal {
        bytes32 firstWord;
        // Mirror `_maxCopy: 32`: take the first word of the policy's revert data verbatim.
        assembly {
            firstWord := mload(add(urpRevertData, 0x20))
        }
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xf4270752), firstWord));
    }

    /// @dev Convenience for the no-argument case, where the word is just the left-aligned selector.
    function expectUrpGate(bytes4 gateSelector) internal {
        vm.expectRevert(abi.encodeWithSelector(bytes4(0xf4270752), bytes32(gateSelector)));
    }

    // ─────────────────────── the exact-selector assertion ───────────────────────

    /**
     * @notice Assert a deployed contract's function selectors equal `expected` EXACTLY.
     * @dev    SHARED HELPER — W-25 here, T-09 in Phase 4. Do not write a second one.
     *
     *         EXACT SET, not "contains no X". A negative assertion cannot fail against a MISNAMED
     *         X — the same defect class that made a `vm.expectCall(..., 0)` on an undeclared
     *         selector pass in Phase 2. An exact set also catches an accidentally-`public` internal
     *         helper such as `_owner()`, which no denylist would ever name.
     *
     *         Selectors are read from the build artifact's `methodIdentifiers`, which is solc's own
     *         view of the external ABI — not a hand-maintained list.
     */
    function assertSelectorSet(string memory contractName, bytes4[] memory expected) internal view {
        string memory path = string.concat("out/", contractName, ".sol/", contractName, ".json");
        string memory artifact = vm.readFile(path);

        string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");

        bytes4[] memory actual = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            actual[i] = bytes4(keccak256(bytes(signatures[i])));
        }

        assertEq(actual.length, expected.length, "selector COUNT differs from the expected set");

        // Every actual selector must appear in `expected`. With equal counts and no duplicates in
        // the ABI, that is set equality.
        for (uint256 i; i < actual.length; ++i) {
            bool found;
            for (uint256 j; j < expected.length; ++j) {
                if (actual[i] == expected[j]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat("unexpected selector in ABI: ", signatures[i]));
        }
    }

    // ───────────────────────────── key helpers ─────────────────────────────

    function ecdsaKey(string memory label) internal returns (address addr, uint256 pk) {
        (addr, pk) = makeAddrAndKey(label);
    }

    /// @dev The agent config every rules set carries: the agent's Push address, `abi.encode(agent)`.
    ///      The exact format `AgentConfigLib` decodes. It feeds the permission id; changing it
    ///      changes every id.
    function agentConfig(address agent) internal pure returns (bytes memory) {
        return abi.encode(agent);
    }

    // ─────────────────────── the storage-layout assertion ───────────────────────

    /**
     * @notice Assert that `contractName` declares NO storage variables, from the build artifact.
     * @dev    SHARED HELPER — used by the validator's `test_holdsNoStorage` (validator PRD §4) and
     *         by the factory's T-01(a). Do not write a second one.
     *
     *         WHY AN ARTIFACT ASSERTION AND NOT `vm.load`. Solidity offers no runtime way to ask
     *         "does this contract declare storage?". Reading chosen slots with `vm.load` and
     *         asserting zero proves only that THOSE slots are zero — equally true of a contract
     *         that declares variables and never writes them. That is a test that cannot fail, so
     *         the assertion is made against solc's own `storageLayout` output instead.
     *
     *         MECHANISM, and it is fussier than it looks — three forms were probed before this one.
     *         `vm.parseJson` ABI-encodes the JSON array it finds. An EMPTY array encodes to exactly
     *         64 bytes: an offset word plus a zero length word. Any declared variable makes it
     *         longer (URP's two produce 1,120). So the length of the raw encoding is itself the
     *         discriminator, and no decode is needed.
     *
     *         The two forms that do NOT work, recorded so they are not retried:
     *           · `abi.decode(..., (bytes[]))` — succeeds on the empty case but REVERTS on a
     *             non-empty one, because each entry is an object, not a bytes value. It fails, but
     *             with a bare EvmError instead of a legible assertion.
     *           · `vm.parseJsonStringArray(..., ".storageLayout.storage[*].label")` — the wildcard
     *             path errors on BOTH cases ("must return exactly one JSON value").
     *
     *         Requires `extra_output = ["storageLayout"]` and read access to `out/` — both are set
     *         in foundry.toml, the latter specifically for this assertion.
     */
    function assertEmptyStorageLayout(string memory contractName) internal view {
        string memory path = string.concat("out/", contractName, ".sol/", contractName, ".json");
        string memory artifact = vm.readFile(path);

        require(vm.keyExistsJson(artifact, ".storageLayout.storage"), "no storageLayout in artifact");

        uint256 encodedLength = vm.parseJson(artifact, ".storageLayout.storage").length;
        assertEq(
            encodedLength,
            64,
            string.concat(contractName, " must declare no storage variables (empty layout encodes to 64 bytes)")
        );
    }

    /**
     * @notice Assert a contract's storage layout is EXACTLY these labels, in this slot order.
     *
     * @dev    THE GUARD THAT MAKES "APPEND ONLY" ENFORCEABLE. Behind a proxy, storage belongs to
     *         the proxy and outlives every implementation, so reordering or retyping a variable
     *         does not fail the build — it silently reinterprets live state. For URP that means
     *         live mandates: a shifted slot could move `spent`, and an agent's budget would read as
     *         unspent. Nothing in Solidity catches that, so it is asserted against solc's own
     *         `storageLayout` output here, exactly as `assertEmptyStorageLayout` does.
     *
     *         A future version may APPEND labels (and decrement `__gap`); this assertion should be
     *         extended, never loosened. If it fails, do not "fix" it by editing the expected list
     *         until you are certain the change is an append and not a reorder.
     *
     * @param contractName   Artifact name, e.g. "URP".
     * @param expectedLabels Variable names in declaration order.
     */
    function assertStorageLayout(string memory contractName, string[] memory expectedLabels) internal view {
        string memory path = string.concat("out/", contractName, ".sol/", contractName, ".json");
        string memory artifact = vm.readFile(path);

        require(vm.keyExistsJson(artifact, ".storageLayout.storage"), "no storageLayout in artifact");

        for (uint256 i; i < expectedLabels.length; ++i) {
            string memory base = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            assertEq(
                vm.parseJsonString(artifact, string.concat(base, ".label")),
                expectedLabels[i],
                string.concat(contractName, " slot ", vm.toString(i), " label moved")
            );
            assertEq(
                vm.parseJsonString(artifact, string.concat(base, ".slot")),
                vm.toString(i),
                string.concat(contractName, " ", expectedLabels[i], " is not at slot ", vm.toString(i))
            );
        }

        // And nothing beyond the expected list — an unexpected trailing variable is a layout change
        // too, and would otherwise pass silently.
        assertFalse(
            vm.keyExistsJson(
                artifact, string.concat(".storageLayout.storage[", vm.toString(expectedLabels.length), "]")
            ),
            string.concat(contractName, " declares more storage than expected")
        );
    }

    // ────────────────────────── canonical session ──────────────────────────

    /**
     * @notice The ONLY session shape v3 permits (deployment spec §4) — the deployed URP as the
     *         single action policy. POSITIVE tests use this.
     * @dev    `salt` is zero here; the wallet overwrites it with its monotonic grantNonce in Phase 3.
     */
    function canonicalSession(bytes memory validatorInitData, bytes memory urpInitData)
        internal
        view
        returns (Session memory)
    {
        return sessionWithPolicy(address(urp), validatorInitData, urpInitData);
    }

    /**
     * @notice The same shape with an arbitrary action policy. NEGATIVE wrong-policy tests use this;
     *         positive tests must not, or they stop testing the shipped wiring.
     */
    function sessionWithPolicy(address policy, bytes memory validatorInitData, bytes memory policyInitData)
        internal
        view
        returns (Session memory)
    {
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({ policy: policy, initData: policyInitData });

        ActionData[] memory actions = new ActionData[](1);
        // Selector BEFORE target — that is the declaration order at DataTypes.sol:82-86.
        actions[0] = ActionData({
            actionTargetSelector: SEND_OUTBOUND_SELECTOR, actionTarget: GATEWAY, actionPolicies: actionPolicies
        });

        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: validatorInitData,
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    // ─────────────────────────── the policy envelope ───────────────────────────

    /// @dev Sepolia, the foreign chain every universal test uses. A string, never a hash — the SDK
    ///      never computes a hash, and neither do these helpers' callers.
    string internal constant CHAIN_SEPOLIA = "eip155:11155111";

    /**
     * @notice Wrap an encoded body in URP's `(string chain, bytes body)` envelope.
     *
     * @dev    SHARED HELPER — use this everywhere a policy `initData` is built. The envelope shape
     *         is IDENTICAL for both modes; the chain string alone decides which rulebook applies,
     *         and both the wallet and URP derive it independently from these same bytes.
     *
     *         THERE IS NO MODE ARGUMENT, and that is the point of the change: no caller — not the
     *         SDK, not a test, not the wallet — ever states a mandate's kind. A test that wants a
     *         NATIVE config passes this chain's own identifier; anything else is UNIVERSAL.
     */
    function envelope(string memory chain, bytes memory body) internal pure returns (bytes memory) {
        return abi.encode(chain, body);
    }

    /**
     * @dev This chain's CAIP-2 identifier, built from `block.chainid` and NEVER a literal.
     *
     *      ⚠️ Foundry's default chain id is 31337, where URP derives `eip155:31337`. A native helper
     *      hard-coding `"eip155:42101"` would produce a UNIVERSAL mandate on the default chain and
     *      every native test would fail for a reason that looks nothing like the cause. Tests that
     *      want the Donut value pin it with `vm.chainId(42101)` and this follows automatically.
     */
    function nativeChain() internal view returns (string memory) {
        return string.concat("eip155:", vm.toString(block.chainid));
    }

    /// @dev The universal case, which is most of them. Takes the storage-shaped `Config` the tests
    ///      already build and narrows it to the wire type — the fields URP owns (`initialized`,
    ///      `spent`, and the `destChainHash` relic) are dropped here rather than at every call site.
    function universalInitData(Config memory cfg) internal pure returns (bytes memory) {
        return universalInitData(CHAIN_SEPOLIA, cfg);
    }

    /// @dev The universal case on a named chain — for the chain-derivation and teeth suites.
    function universalInitData(string memory chain, Config memory cfg) internal pure returns (bytes memory) {
        return envelope(chain, abi.encode(_terms(cfg)));
    }

    /// @dev The native case. The chain is this chain, by definition of the mode.
    function nativeInitData(NativeConfig memory cfg) internal view returns (bytes memory) {
        return envelope(nativeChain(), abi.encode(_terms(cfg)));
    }

    /// @dev `Config` (storage shape, what tests build) → `UniversalTerms` (wire shape).
    function _terms(Config memory cfg) internal pure returns (UniversalTerms memory) {
        return UniversalTerms({
            validUntil: cfg.validUntil,
            expectedCEA: cfg.expectedCEA,
            asset: cfg.asset,
            maxAmountPerCall: cfg.maxAmountPerCall,
            maxAmountTotal: cfg.maxAmountTotal,
            maxPCPerCall: cfg.maxPCPerCall,
            allowedCalls: cfg.allowedCalls
        });
    }

    /// @dev `NativeConfig` (storage shape) → `NativeTerms` (wire shape).
    function _terms(NativeConfig memory cfg) internal pure returns (NativeTerms memory) {
        return NativeTerms({
            validUntil: cfg.validUntil,
            target: cfg.target,
            selector: cfg.selector,
            maxValuePerCall: cfg.maxValuePerCall,
            maxValueTotal: cfg.maxValueTotal,
            amount: cfg.amount,
            maxCalls: cfg.maxCalls,
            pins: cfg.pins
        });
    }

    // ─────────────────────────── outbound request ───────────────────────────

    /// @dev `recipient` is always empty — URP gate 11 requires it.
    function outboundRequest(
        address token,
        uint256 amount,
        uint256 maxPCForGas,
        address revertRecipient,
        Multicall[] memory calls
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: "",
                token: token,
                amount: amount,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: maxPCForGas,
                payload: abi.encodeWithSelector(MULTICALL_SELECTOR, calls),
                revertRecipient: revertRecipient
            })
        );
    }

    /// @dev A zero-valued request, for pinning MIN_OUTBOUND_BODY_LEN against the real struct.
    function emptyOutboundRequest() internal pure returns (UniversalOutboundTxRequest memory req) {
        return req;
    }

    // ─────────────────────────── svm rulebook helpers ───────────────────────────

    /// @dev Solana devnet, the foreign SVM chain every SVM test uses — the exact CAIP-2 string the
    ///      SDK's `CHAIN.SOLANA_DEVNET` carries. A string, never a hash, for the same reason as
    ///      `CHAIN_SEPOLIA`.
    string internal constant CHAIN_SOLANA_DEVNET = "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1";

    /// @dev The SVM case. `SvmTerms` is already the wire type, so nothing to narrow.
    function svmInitData(string memory chain, SvmTerms memory terms) internal pure returns (bytes memory) {
        return envelope(chain, abi.encode(terms));
    }

    /**
     * @dev The node's execute-payload grammar (`universalClient/chains/svm/tx_builder.go`,
     *      `decodePayload`), byte for byte, and what the SDK's `encodeSvmExecutePayload` emits:
     *      `[u32 BE count][count × (pubkey32 ‖ is_writable u8)][u32 BE len][ixData][u8 id][target32]`.
     *      An INDEPENDENT WITNESS of the format URP parses — built here from the node's documented
     *      layout, not from URP's constants, so a URP parser that drifts fails against it.
     */
    function svmExecutePayload(
        bytes32[] memory accounts,
        bool[] memory writable,
        bytes memory ixData,
        uint8 instructionId,
        bytes32 targetProgram
    ) internal pure returns (bytes memory out) {
        require(accounts.length == writable.length, "svmExecutePayload: flags length");
        out = abi.encodePacked(uint32(accounts.length));
        for (uint256 i; i < accounts.length; ++i) {
            out = abi.encodePacked(out, accounts[i], writable[i] ? uint8(1) : uint8(0));
        }
        out = abi.encodePacked(out, uint32(ixData.length), ixData, instructionId, targetProgram);
    }

    /// @dev An outbound request bound for an SVM chain: a 32-byte recipient (the target program)
    ///      and an execute payload. The mirror of `outboundRequest` for the third rulebook.
    function svmOutboundRequest(
        address token,
        uint256 amount,
        uint256 maxPCForGas,
        address revertRecipient,
        bytes memory recipient,
        bytes memory payload
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            SEND_OUTBOUND_SELECTOR,
            UniversalOutboundTxRequest({
                recipient: recipient,
                token: token,
                amount: amount,
                gasLimit: 0,
                gasPrice: 0,
                maxPCForGas: maxPCForGas,
                payload: payload,
                revertRecipient: revertRecipient
            })
        );
    }

    /// @dev Little-endian encoding of the low `n` bytes of `v` — Borsh integers.
    function le(uint256 v, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i))); // byte i of a little-endian integer, truncation intended
        }
    }

    /**
     * @dev Base58 decode of a Solana address into its 32 raw bytes. The INDEPENDENT WITNESS for
     *      URP's program-id constants: the source carries hex words generated by tooling, this
     *      decodes the human-readable ids the Solana ecosystem actually publishes, and a test pins
     *      the two against each other. Pure big-number arithmetic; a 32-byte value never overflows
     *      uint256, and a malformed input reverts.
     */
    function base58ToBytes32(string memory s) internal pure returns (bytes32) {
        bytes memory alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        bytes memory b = bytes(s);
        uint256 n;
        for (uint256 i; i < b.length; ++i) {
            uint256 digit = 58;
            for (uint256 j; j < 58; ++j) {
                if (alphabet[j] == b[i]) {
                    digit = j;
                    break;
                }
            }
            require(digit < 58, "base58: bad char");
            n = n * 58 + digit;
        }
        return bytes32(n);
    }

    // ────────────────────────── assertion helpers ──────────────────────────

    /// @dev No `assertRevertsWith` wrapper exists by design: tests call
    ///      vm.expectRevert(Contract.Error.selector) directly, so the reader sees which
    ///      error is expected at the assertion site.

    // ─────────────────────────── the call recorder ───────────────────────────

    // OBSERVER, NEVER ORACLE. The recorder counts calls and returns empty bytes; it supplies
    // no behaviour to the code under test.
    //
    // WHY A RECORDER AND NOT `vm.expectCall(target, "", 0)`. That form depends on three
    // behaviours at once: empty-calldata prefix matching, zero-count meaning "assert not
    // called", and — the one that actually decides it — whether calls made inside a frame
    // that later REVERTS still count against the expectation. W-28 asserts silence inside
    // `vm.expectRevert`, so that third interaction is load-bearing and varies by version.
    // Worse, a helper built on expectCall cannot be verified here: a cheatcode-level
    // expectation failure is not catchable, so the negative branch can never be demonstrated
    // — a test that cannot fail. The recorder's counter is ordinary storage, so both branches
    // are provable (see test_callRecorder_semantics).
    function etchCallRecorder(address target) internal {
        vm.etch(target, type(CallRecorder).runtimeCode);
    }

    function callsRecorded(address target) internal view returns (uint256) {
        return uint256(vm.load(target, bytes32(uint256(0))));
    }

    /// @dev Asserts `target` was never called. Requires etchCallRecorder(target) first.
    function assertNoCallsTo(address target) internal view {
        assertEq(callsRecorded(target), 0, "expected no calls to target");
    }

    // ─────────────────────────────── run mode ───────────────────────────────

    /// @dev Whether top-level calls run as separate transactions (`--isolate`, which `--gas-report`
    ///      switches on). A plain call to an empty account then costs at least the 21,000 intrinsic
    ///      gas; otherwise it costs a few thousand. Gas tests use it to pick the budget measured for the
    ///      mode they run in.
    function isolatedCalls() internal returns (bool) {
        address probe = makeAddr("isolationProbe");
        uint256 before = gasleft();
        (bool ok,) = probe.call("");
        uint256 cost = before - gasleft();
        assertTrue(ok, "a call to an empty account succeeds");
        return cost >= 21_000;
    }

    // ─────────────────────────── owner intents ───────────────────────────

    /// @dev The origin chain the default signer "lives on" — Ethereum mainnet. Deliberately NOT
    ///      block.chainid: the intent domain's chainId is the signer's home chain.
    uint256 internal constant SIGNER_CHAIN_ID = 1;

    /// @dev Every signature the intent helpers produce is counted here, so an integration test can
    ///      assert how many times the owner was asked to sign (cheatcode calls themselves are not
    ///      countable).
    uint256 internal intentSignatures;

    /**
     * @notice The OwnerIntent digest, built BY HAND from the literal type strings.
     * @dev    INDEPENDENT WITNESS, not a call into OwnerAuthLib: every field is listed here explicitly,
     *         so a library that dropped, reordered or retyped a field produces a different digest and
     *         the signature this helper makes stops verifying.
     */
    function intentDigestWitness(address factoryAddr, OwnerIntent memory i) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)"
                ),
                keccak256("AGWFactory"),
                keccak256("1"),
                i.signerChainId,
                factoryAddr,
                bytes32(block.chainid)
            )
        );
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OwnerIntent(address owner,address wallet,address executor,uint96 index,bytes32 sessionHash,bytes32 mode,bytes32 execCalldataHash,uint192 nonceKey,uint64 nonceSeq,uint64 grantNonce,uint48 deadline,uint256 signerChainId)"
                    ),
                    i.owner,
                    i.wallet,
                    i.executor,
                    i.index,
                    i.sessionHash,
                    i.mode
                ),
                abi.encode(i.execCalldataHash, i.nonceKey, i.nonceSeq, i.grantNonce, i.deadline, i.signerChainId)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    /// @dev Sign `i` with `pk` under the real factory's domain. 65-byte r‖s‖v.
    function signIntent(uint256 pk, OwnerIntent memory i) internal returns (bytes memory) {
        return signIntentFor(FACTORY, pk, i);
    }

    function signIntentFor(address factoryAddr, uint256 pk, OwnerIntent memory i) internal returns (bytes memory) {
        intentSignatures++;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, intentDigestWitness(factoryAddr, i));
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice An intent with every door disabled, ready for a test to switch on the fields it needs.
     * @dev    Zero session and exec hashes mean "not authorised" (D9); the deadline is an hour out.
     */
    function blankIntent(address owner_, address wallet_, address executor_)
        internal
        view
        returns (OwnerIntent memory)
    {
        return OwnerIntent({
            owner: owner_,
            wallet: wallet_,
            executor: executor_,
            index: 0,
            sessionHash: bytes32(0),
            mode: bytes32(0),
            execCalldataHash: bytes32(0),
            nonceKey: OWNER_LANE_FLAG,
            nonceSeq: 0,
            grantNonce: 0,
            deadline: uint48(block.timestamp + 1 hours),
            signerChainId: SIGNER_CHAIN_ID
        });
    }

    /// @dev The predicted address of `owner_`'s next wallet on the real factory.
    function nextWallet(address owner_) internal view returns (address wallet_, uint96 index_) {
        index_ = uint96(factory.walletCount(owner_));
        (wallet_,) = factory.predictWallet(owner_, index_);
    }
}

/// @dev Deployed only via vm.etch, by etchCallRecorder. Observer, never oracle: it counts calls
///      into slot 0 and returns empty bytes, supplying no behaviour to the code under test.
///      Counts CALL only — a STATICCALL cannot write storage and will revert against this
///      contract, which is itself informative: a caller that staticcalls a recorder is telling
///      you the call happened.
contract CallRecorder {
    uint256 public count;

    fallback() external payable {
        count++;
    }

    receive() external payable {
        count++;
    }
}
