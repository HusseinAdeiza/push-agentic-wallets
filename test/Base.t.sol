// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { PushSessionValidator } from "../src/validators/PushSessionValidator.sol";
import { URP } from "../src/policies/URP.sol";
import { PushAgentWallet } from "../src/PushAgentWallet.sol";
import { AGWFactory } from "../src/AGWFactory.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../src/libraries/PushWalletTypes.sol";

/**
 * @title  BaseTest — the shared harness every v3 suite extends.
 * @notice Deploys only what exists today: the permission engine and the session validator.
 *         URP, the wallet and the factory are added to this harness by their own phases.
 */
abstract contract BaseTest is Test {
    // ───────────────────────────── deployments ─────────────────────────────

    SmartSession internal engine;
    PushSessionValidator internal validator;
    URP internal urp;

    /// @dev The wallet IMPLEMENTATION. Clones delegatecall into it; it is never driven directly.
    PushAgentWallet internal walletImpl;

    /// @dev THE REAL FACTORY — an ERC-1967 proxy in front of `factoryLogic`. Every wallet in every
    ///      suite is now deployed through it, so the wallet's `_factory()` immutable arg is the
    ///      proxy address, exactly as in production. (Phase 3 used a makeAddr placeholder.)
    AGWFactory internal factory;
    AGWFactory internal factoryLogic;

    /// @dev The proxy address, for tests that want it as a plain address.
    address internal FACTORY;

    address internal FACTORY_ADMIN;

    // ─────────────────────────── named addresses ───────────────────────────

    /// @dev The Ed25519 precompile. Must equal PushSessionValidator.USV — asserted in the smoke test.
    address internal constant USV = 0xEC00000000000000000000000000000000000001;

    address internal GATEWAY;
    address internal EXECUTOR_MODULE;
    address internal RELAYER;
    address internal OWNER;
    address internal AGENT;

    // ───────────────────────────── constants ─────────────────────────────

    /// @dev Asserted against IUniversalGatewayPC.sendUniversalTxOutbound.selector in the smoke test.
    ///
    ///      DELIBERATELY HAND-TYPED, not imported from PushWalletTypes.sol. The production constant
    ///      lives there and both the wallet and URP read it from that one place; this copy is the
    ///      INDEPENDENT WITNESS that the shared constant is the value the gateway actually exposes.
    ///      Importing it here would make the test agree with the source by construction and assert
    ///      nothing — a mock supplying the behaviour under test. URP's smoke test pins the two
    ///      against each other, so an edit to either side fails the build rather than passing quietly.
    bytes4 internal constant SEND_OUTBOUND_SELECTOR =
        bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

    /// @dev The smallest possible ABI encoding of a UniversalOutboundTxRequest argument list.
    ///      Derivation (PushWalletTypes.sol:9-18): 32 (outer offset word — the struct is dynamic,
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
        validator = new PushSessionValidator();
        urp = new URP(GATEWAY, EXECUTOR_MODULE, address(engine));
        walletImpl = new PushAgentWallet(address(engine), address(urp), address(validator), GATEWAY);

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
        vm.label(address(validator), "PushSessionValidator");
        vm.label(address(urp), "URP");
        vm.label(address(walletImpl), "PushAgentWallet(impl)");
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
    function newWallet(address walletOwner) internal returns (PushAgentWallet wallet) {
        vm.prank(walletOwner);
        return PushAgentWallet(payable(factory.deployWallet("")));
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

    /// @dev Scheme 0, 20-byte key. The exact initData format the validator PRD §10 item 5 freezes:
    ///      abi.encode(uint8, bytes). It feeds the permission id; changing it changes every id.
    function ecdsaConfig(address signer) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), abi.encodePacked(signer));
    }

    /// @dev Scheme 1, 32-byte key.
    function ed25519Config(bytes32 pubKey) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), abi.encodePacked(pubKey));
    }

    /// @dev 65-byte r‖s‖v. EIP-2098 compact signatures are deliberately unsupported.
    function signOpHash(uint256 pk, bytes32 opHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, opHash);
        return abi.encodePacked(r, s, v);
    }

    // ─────────────────────────── the USV observer ───────────────────────────

    // OBSERVER, NEVER ORACLE. This mock records which precompile method was called;
    // it asserts nothing about whether the signature was valid. Liveness of the real
    // Ed25519 path is proven only by P-03 against the live precompile. The original
    // critical bug in this validator was masked by a mock that supplied behaviour —
    // an oracle. Do not extend this mock to return anything but a fixed value.
    //
    // MECHANISM NOTE: the validator reaches USV via STATICCALL, so an observer that records
    // by writing storage cannot work — a staticcall reverts on SSTORE. The observer therefore
    // returns a fixed `true` and nothing else, and *which method was called* is asserted with
    // `vm.expectCall(USV, <exact calldata>)` at the assertion site. That keeps the expected
    // selector visible in the test rather than hidden behind a getter.
    function etchUSVObserver() internal {
        vm.etch(USV, type(USVObserver).runtimeCode);
    }

    /// @dev Assert the next call to USV carries exactly this method + arguments.
    ///      Pairs with etchUSVObserver: the mock answers, this proves what was asked.
    function expectUSVCall(bytes memory expectedCalldata) internal {
        vm.expectCall(USV, expectedCalldata);
    }

    /**
     * @dev A USV observer that answers a fixed `false`.
     *
     *      PERMITTED ONLY IN TESTS NAMED FOR PROPAGATION, NEVER FOR VALIDITY. Pairing this with
     *      `etchUSVObserver` lets V-05/V-06 prove that whatever the precompile answered is what the
     *      validator returned — which is the only Ed25519 property observable without a live chain.
     *      A test that used either observer to claim a signature is *correct* would be the oracle
     *      mistake that let this repo's one shipped critical bug survive review.
     *
     *      Correctness and liveness of the Ed25519 branch are proven ONLY by P-03 against the real
     *      precompile; P-04 proves it fails closed when USV has no code.
     */
    function etchUSVFalseObserver() internal {
        vm.etch(USV, type(USVFalseObserver).runtimeCode);
    }

    /// @dev Remove all code from USV, so fails-closed tests (P-04) exercise a codeless precompile.
    function stripUSV() internal {
        vm.etch(USV, "");
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

/// @dev Deployed only via vm.etch at USV. See etchUSVObserver's comment: observer, never oracle.
///      Returns a FIXED value and records nothing — it must be safe under STATICCALL, which is
///      how the validator actually reaches the precompile. What was called is asserted with
///      vm.expectCall, not read back from here.
contract USVObserver {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(true);
    }
}

/// @dev The `false` counterpart. See etchUSVFalseObserver: permitted only in tests named for
///      PROPAGATION, never for validity. It supplies no correctness — it exists so that
///      "the validator returns what the precompile said" is assertable in both directions.
contract USVFalseObserver {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(false);
    }
}
