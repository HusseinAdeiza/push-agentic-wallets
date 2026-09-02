// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import {
    Session,
    ActionData,
    PolicyData,
    ERC7739Data,
    ERC7739Context,
    PermissionId
} from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";

import { PushSessionValidator } from "../src/validators/PushSessionValidator.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../src/libraries/PushWalletTypes.sol";

/**
 * @title  BaseTest — the shared harness every v3 suite extends.
 * @notice Deploys only what exists today: the permission engine and the session validator.
 *         UCEP, the wallet and the factory are added to this harness by their own phases.
 */
abstract contract BaseTest is Test {
    // ───────────────────────────── deployments ─────────────────────────────

    SmartSession internal engine;
    PushSessionValidator internal validator;

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
    bytes4 internal constant SEND_OUTBOUND_SELECTOR =
        bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

    /// @dev The smallest possible ABI encoding of a UniversalOutboundTxRequest argument list.
    ///      Derivation (PushWalletTypes.sol:9-18): 32 (outer offset word — the struct is dynamic,
    ///      so abi.encode prefixes a pointer) + 256 (eight head words) + 32 + 32 (length words for
    ///      the two empty dynamic `bytes` fields, `recipient` and `payload`) = 352.
    ///      DO NOT hand-maintain this number: it is pinned against abi.encode of an empty request,
    ///      so a field added to the struct fails the build instead of silently loosening UCEP's
    ///      gate 4c into a check that passes everything.
    uint256 internal constant MIN_OUTBOUND_BODY_LEN = 352;

    // ─────────────────────────────── setUp ───────────────────────────────

    function setUp() public virtual {
        engine = new SmartSession();
        validator = new PushSessionValidator();

        vm.label(address(engine), "SmartSession");
        vm.label(address(validator), "PushSessionValidator");

        GATEWAY = makeAddr("universalGatewayPC");
        EXECUTOR_MODULE = makeAddr("universalExecutorModule");
        RELAYER = makeAddr("relayer");
        OWNER = makeAddr("owner");
        AGENT = makeAddr("agent");
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

    /// @dev Remove all code from USV, so fails-closed tests (P-04) exercise a codeless precompile.
    function stripUSV() internal {
        vm.etch(USV, "");
    }

    // ────────────────────────── canonical session ──────────────────────────

    /**
     * @notice The ONLY session shape v3 permits (deployment spec §4).
     * @dev    `salt` is zero here; the wallet overwrites it with its monotonic grantNonce in
     *         Phase 3. `ucep` is a parameter because UCEP does not exist in this phase.
     */
    function canonicalSession(bytes memory validatorInitData, address ucep, bytes memory ucepInitData)
        internal
        view
        returns (Session memory)
    {
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({ policy: ucep, initData: ucepInitData });

        ActionData[] memory actions = new ActionData[](1);
        // Selector BEFORE target — that is the declaration order at DataTypes.sol:82-86.
        actions[0] = ActionData({
            actionTargetSelector: SEND_OUTBOUND_SELECTOR,
            actionTarget: GATEWAY,
            actionPolicies: actionPolicies
        });

        return Session({
            sessionValidator: ISessionValidator(address(validator)),
            sessionValidatorInitData: validatorInitData,
            salt: bytes32(0),
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0),
                erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    // ─────────────────────────── outbound request ───────────────────────────

    /// @dev `recipient` is always empty — UCEP gate 11 requires it.
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
