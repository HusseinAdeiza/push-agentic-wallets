// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";

import { ISmartSession } from "smartsessions/ISmartSession.sol";
import { Session, PermissionId, ValidationData, SmartSessionMode } from "smartsessions/DataTypes.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { IModule as IERC7579Module } from "erc7579/interfaces/IERC7579Module.sol";

import { IPushSessionValidator } from "./interfaces/IPushSessionValidator.sol";
import { IPushAgentWallet } from "./interfaces/IPushAgentWallet.sol";
import { PushWalletErrors } from "./libraries/PushWalletErrors.sol";
import { SEND_OUTBOUND_SELECTOR, OP_HASH_DOMAIN } from "./libraries/PushWalletTypes.sol";
import {
    ModeCode,
    CallType,
    ExecType,
    ModeLib,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT
} from "./libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "./libraries/ExecutionLib.sol";

/**
 * @title  PushAgentWallet
 * @notice The user's per-purpose agent wallet on Push Chain. It holds the budgeted funds and is
 *         `msg.sender` at the gateway — which is what binds it to its destination-chain account.
 *
 * @dev    PUSH CHAIN HAS NO ERC-4337 ENTRYPOINT, so this wallet performs the EntryPoint's jobs
 *         itself inside the agent door: expiry, replay protection, operation-hash computation,
 *         invoking the validator, and enforcing the verdict. It keeps the `PackedUserOperation`
 *         ABI *shape* only, because the adopted engine speaks it.
 *
 * @dev    An ERC-7579 modular account REDUCED TO ONE MODULE TYPE (validator). Hooks, executors and
 *         fallback modules are refused by the wallet itself — a hook would run on the owner path
 *         and could block it, and the owner path being unblockable is the design's most important
 *         property.
 *
 * @dev    THE TWO DOORS ARE THE ENTIRE AUTHORITY MODEL:
 *           · `execute`            — msg.sender == owner(). NO policy, ever. Reads the
 *                                    immutable-args owner and calldata, and NOTHING else.
 *           · `executeWithSession` — permissionless; full engine validation is the authority.
 */
contract PushAgentWallet is IPushAgentWallet, ReentrancyGuardTransient {
    using ModeLib for ModeCode;

    // ─────────────────────────────── constants ───────────────────────────────

    /// @dev ERC-7579 `vendorname.accountname.semver` — push · agentwallet · 1.0.0.
    ///      The semver tracks THIS CONTRACT's releases; it is not the architecture generation, and
    ///      the two are deliberately allowed to differ.
    string internal constant ACCOUNT_ID = "push.agentwallet.1.0.0";

    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    // Types 2 (executor), 3 (fallback), 4 (hook) exist in the standard and are deliberately NOT
    // supported — supportsModule returns false and install reverts. A hook in particular would run
    // on the owner path and could block it, and the owner path being unblockable is the design's
    // most important property.

    /// @dev Gas stipend for a module's uninstall callback. Named, never inlined.
    uint256 internal constant UNINSTALL_CALLBACK_GAS_STIPEND = 100_000;

    /// @dev Gas cap for the engine-only pre-uninstall staticcall. Named, never inlined.
    uint256 internal constant ENGINE_STATE_PROBE_GAS = 30_000;

    // ─────────────────────────────── immutables ───────────────────────────────

    // THE FOUR WIRING ADDRESSES ARE IMMUTABLE, NOT CONSTANT (a deliberate choice, explained below).
    // Minimal clones DELEGATECALL into this implementation, so immutables resolve from the
    // implementation's own runtime bytecode and every clone reads them correctly. Immutability is
    // preserved exactly as a constant would preserve it — nothing can rewrite them — while tests
    // and deployments pass real, freshly deployed addresses instead of etching code at a hardcoded
    // address, which is how a critical bug once survived a green suite here.

    address internal immutable DEFAULT_SESSION_ENGINE;
    address internal immutable CANONICAL_UCEP;
    address internal immutable CANONICAL_SESSION_VALIDATOR;
    address internal immutable UNIVERSAL_GATEWAY_PC;

    // ──────────────────────────────── storage ────────────────────────────────

    // THIS IS THE WALLET'S WHOLE STATE. FOUR DECLARATIONS. No agent slot, no pause bool, no
    // counters, no session data, no request registry, no pending queue. A request exists only for
    // the duration of the transaction that carries it. The clone is non-upgradeable, so there is
    // no gap and no namespacing.

    bool private _initialized; // slot 0        — one-shot latch for initializeAccount
    uint64 private _grantNonce; // slot 0 packed — permission salt source; monotonic; NEVER reused
    mapping(address => bool) private _installedValidators; // the entire module registry
    mapping(uint192 => uint64) private _nonces; // replay lanes: lane key => next expected position

    // Events are declared in IPushAgentWallet, inherited above.

    // ────────────────────────────── constructor ──────────────────────────────

    constructor(address sessionEngine_, address ucep_, address sessionValidator_, address universalGatewayPC_) {
        if (
            sessionEngine_ == address(0) || ucep_ == address(0) || sessionValidator_ == address(0)
                || universalGatewayPC_ == address(0)
        ) {
            revert PushWalletErrors.InvalidModuleAddress();
        }
        DEFAULT_SESSION_ENGINE = sessionEngine_;
        CANONICAL_UCEP = ucep_;
        CANONICAL_SESSION_VALIDATOR = sessionValidator_;
        UNIVERSAL_GATEWAY_PC = universalGatewayPC_;

        // The implementation itself can never be initialised or driven directly.
        _initialized = true;
    }

    // ─────────────────────────────── modifiers ───────────────────────────────

    /// @dev A direct comparison, no role framework. The owner door reads the immutable-args owner
    ///      and calldata, and nothing else.
    modifier onlyOwner() {
        if (msg.sender != _owner()) revert PushWalletErrors.NotOwner();
        _;
    }

    /**
     * @dev THE THREE LIFECYCLE FUNCTIONS ONLY. A batch entry targeting the wallet arrives
     *      with `msg.sender == address(this)`, so without this the owner's own one-signature change
     *      batch — UCEP's spend assertion, then stopMandate, then grantMandate — reverts `NotOwner`
     *      against itself. That is the ERC-7579 idiom: reference accounts gate configuration
     *      functions `onlyEntryPointOrSelf`; v3 has no EntryPoint, so it is owner-or-self.
     *
     *      THE WIDENING IS SAFE BECAUSE "SELF" IS REACHABLE ONLY THROUGH THE OWNER DOOR. The only
     *      thing that can make the wallet call itself is `_execute`, from one of the two doors. The
     *      owner door is owner authority by definition. The agent door's dispatch target is refused
     *      three independent ways — UCEP gate 3 (`InvalidTarget`), the engine's `InvalidSelfCall`
     *      for an `execute`-selector self-target (`PolicyLib.sol:196`), and the engine's no-policy
     *      floor for any other selector on the account. All three are pinned by the agent-door suite.
     *
     *      THIS IS NOT AN OWNER-DOOR READ. `execute` still consults exactly the
     *      immutable-args owner and calldata; the widening is on the CALLEE's check. Do not
     *      "tighten" it back to `onlyOwner` — that re-breaks the owner.s own one-signature change flow.
     *
     *      NOT applied to installModule/uninstallModule: nothing needs them batched, so no widening.
     */
    modifier onlyOwnerOrSelf() {
        if (msg.sender != _owner() && msg.sender != address(this)) revert PushWalletErrors.NotOwner();
        _;
    }

    // ────────────────────────── immutable-arg helpers ──────────────────────────

    /**
     * @dev The clone's immutable args are 40 bytes: owner at 0–19, factory at 20–39 (encoding
     *      fixed by the factory). Read from bytecode on every call — CACHE NOTHING: a
     *      storage mirror of an immutable is drift surface.
     *
     *      MEANINGFUL ONLY ON A CLONE. `Clones.fetchCloneArgs` has undefined behaviour on a
     *      non-clone (OZ `Clones.sol:255-258`); probe-confirmed, on the implementation it returns
     *      a slice of the implementation's own runtime bytecode, so `_owner()` there yields a
     *      deterministic 20-byte bytecode slice rather than reverting.
     *
     *      DO NOT ADD A GUARD FOR THIS ON THE OWNER PATH — the degraded-state suite forbids it, and a guard would fix
     *      nothing (funds mis-sent to the implementation are unrecoverable with or without one).
     *      Every door on the implementation is inert for an INDEPENDENT reason, and none of the
     *      four is load-bearing alone.
     */
    function _owner() internal view returns (address) {
        return address(bytes20(Clones.fetchCloneArgs(address(this))));
    }

    function _factory() internal view returns (address) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        return address(bytes20(_slice20(args, 20)));
    }

    /// @dev Read 20 bytes at `start` out of a memory blob, without assuming a length.
    ///
    ///      THE SHORT-BLOB BRANCH IS UNREACHABLE AND IS EXPECTED TO SHOW AS UNCOVERED. There is
    ///      exactly one call site (`_factory()`, above), always `(args, 20)` on the clone's 40-byte
    ///      immutable args, so `40 < 40` never holds. It is a defensive-impossible guard, not a
    ///      security gate — unlike ExecutionLib.decodeBatch's three, which ARE gates and are tested.
    function _slice20(bytes memory data, uint256 start) private pure returns (bytes20 out) {
        if (data.length < start + 20) return bytes20(0);
        assembly {
            out := mload(add(add(data, 0x20), start))
        }
    }

    // ──────────────────────── one-shot initialisation ────────────────────────

    /**
     * @notice Factory-only, exactly once. Installs the engine as the sole validator.
     * @dev    Never pass session data here — grants travel only through `grantMandate`.
     *
     *         ON THE IMPLEMENTATION the expected revert is `NotFactory()`, and it is imprecise by
     *         construction: the factory check runs before the `_initialized` latch, and
     *         `_factory()` returns bytecode there, so no caller can match it — including the real
     *         factory. The "true" reason is that the implementation can never be initialised, but
     *         reordering the two guards changes nothing functionally. Leave the order as it stands.
     */
    function initializeAccount() external {
        if (msg.sender != _factory()) revert PushWalletErrors.NotFactory();
        if (_initialized) revert PushWalletErrors.AlreadyInitialized();

        _initialized = true;
        _installedValidators[DEFAULT_SESSION_ENGINE] = true;

        // Empty data, FULL GAS. On a fresh account the engine's dangling-session guard passes
        // trivially and the call is a no-op (`SmartSessionBase.sol:373-375`). Bubble any revert —
        // the factory's deploy transaction then reverts atomically, per its PRD.
        IERC7579Module(DEFAULT_SESSION_ENGINE).onInstall("");

        emit ModuleInstalled(MODULE_TYPE_VALIDATOR, DEFAULT_SESSION_ENGINE);
        emit AccountInitialized(_owner(), DEFAULT_SESSION_ENGINE);
    }

    // ───────────────────────────── the owner door ─────────────────────────────

    /**
     * @notice The owner door. No policy is consulted. Ever.
     *
     * @dev    ABSOLUTE CONSTRAINT, guarded by the owner-path degraded-state suite, which is never
     *         deleted or weakened: this function reads EXACTLY TWO
     *         THINGS — the immutable-args owner and calldata. No module, no policy, no engine
     *         state, no flag may ever be consulted here. It must succeed in every degraded wallet
     *         state: zero mandates, ghost-mandate state, engine uninstalled, hostile validator
     *         installed, engine returning garbage. Adding any check is THE catastrophic regression.
     *
     * @dev    THE SIGNATURE IS FROZEN AT `execute(bytes32,bytes)`. It is not a style choice: the
     *         engine branches on this selector, and any other shape routes validation down a path
     *         where UCEP's value comparison would see a hardcoded zero instead of the real one.
     *
     * @dev    This is also withdrawal, revocation escort and incident response. No dedicated
     *         `withdraw()`/`sweepPC()` exists — a second code path would be a second thing to keep
     *         policy-free forever. A stolen owner key drains the wallet completely: accepted
     *         residual, not this contract's problem to solve.
     */
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable onlyOwner nonReentrant {
        ModeCode m = ModeCode.wrap(mode);
        (CallType callType, ExecType execType,,) = m.decode();

        // BATCH IS REQUIRED PRODUCT SURFACE: the canonical permission-change flow is ONE owner
        // signature batching UCEP's spend assertion, stopMandate, grantMandate and any approval
        // payload the new terms need.
        if (execType != EXECTYPE_DEFAULT) revert PushWalletErrors.UnsupportedExecutionMode();
        if (callType == CALLTYPE_SINGLE) {
            (address target, uint256 value, bytes calldata callData) = ExecutionLib.decodeSingle(executionCalldata);
            _execute(target, value, callData);
        } else if (callType == CALLTYPE_BATCH) {
            Execution[] calldata execs = ExecutionLib.decodeBatch(executionCalldata);
            uint256 len = execs.length;
            for (uint256 i; i < len;) {
                _execute(execs[i].target, execs[i].value, execs[i].callData);
                unchecked {
                    ++i;
                }
            }
        } else {
            // delegatecall, static, or anything else.
            revert PushWalletErrors.UnsupportedExecutionMode();
        }

        emit OwnerExecuted(mode, keccak256(executionCalldata));
    }

    /**
     * @dev The single dispatch primitive, shared by both doors so that the agent path executes the
     *      EXACT validated bytes with no substitution anywhere. A plain `call`, with
     *      the revert reason bubbled verbatim.
     */
    function _execute(address target, uint256 value, bytes calldata callData) internal {
        (bool ok, bytes memory ret) = target.call{ value: value }(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ──────────────────────── mandate lifecycle (3b) ────────────────────────

    /**
     * @notice Grant one mandate. ONE OF EXACTLY TWO LIFECYCLE OPERATIONS.
     *
     * @dev    NO `nonReentrant`, and that is deliberate, not an omission. The guard
     *         would trip on the owner's own change batch, because `execute` already holds the same
     *         transient lock. Dropping it is safe: the engine's enable path makes exactly TWO
     *         external calls — `sessionValidator.isModuleType` (ours, `pure`) and
     *         `policy.initializeWithMultiplexer` (UCEP, which makes no external calls) — and NEVER
     *         calls back into the account (`SmartSessionBase.sol`, `ConfigLib.sol:200-225`). The
     *         shape check above pins the policy to UCEP, so no hostile policy can change that.
     *         `execute`'s own guard still covers the batched case.
     *
     * @dev    IT DOES EXACTLY TWO JOBS: the canonical-shape check, and the salt.
     *         It NEVER validates UCEP's config contents — caps, allow-list and expiry are UCEP's
     *         own init guards, failing closed. The shape check validates the SKELETON; UCEP
     *         validates the ORGANS. Do not extend this into term validation, and do not remove it:
     *         both of the register's orphan wiring rules live in it.
     */
    function grantMandate(Session calldata session) external onlyOwnerOrSelf returns (bytes32 permissionId) {
        // ── step 0 · THE CANONICAL-SHAPE CHECK (owner ruling 2026-08-31) ──
        // Every deviation from the one shape v3 permits reverts MalformedSessionShape().

        // Rule 2 of the deployment spec's wiring table: nothing may live in the zero-floor policy
        // class, because a config without it is legal — so nothing mandatory may live there.
        if (session.userOpPolicies.length != 0) revert PushWalletErrors.MalformedSessionShape();

        // The 7739 path is dead in v3 and stays walled.
        if (
            session.erc7739Policies.allowedERC7739Content.length != 0
                || session.erc7739Policies.erc1271Policies.length != 0
        ) revert PushWalletErrors.MalformedSessionShape();

        // Rule 5: dead surface; paymasterAndData is always empty anyway.
        // WHY REFUSE A FLAG THAT SHOULD BE UNREACHABLE: because "should be" is the whole problem.
        // The wallet always builds the operation with `paymasterAndData` empty, so the engine's
        // paymaster branch (`SmartSession.sol:246-248`) never runs and the flag has no effect
        // TODAY. This check is what keeps that true. Granting with the flag set would write a live
        // `$permitERC4337Paymaster` row into engine storage, and that row is what decides — for a
        // permission that outlives this reasoning — whether a non-empty `paymasterAndData` is
        // rejected outright or instead merely requires one user-operation policy to run. This
        // design mandates ZERO user-operation policies, so that second branch would demand a policy
        // class the grant-shape check forbids. Refusing the flag keeps dead surface genuinely dead
        // rather than dormant, and costs one comparison at grant time.
        if (session.permitERC4337Paymaster) revert PushWalletErrors.MalformedSessionShape();

        // Rule 1: EXACTLY one action, so no wildcard/fallback action policy can ever be configured.
        // The engine's wildcard action would absorb requests that must die — it switches off
        // fail-closed.
        if (session.actions.length != 1) revert PushWalletErrors.MalformedSessionShape();

        if (
            session.actions[0].actionTarget != UNIVERSAL_GATEWAY_PC
                || session.actions[0].actionTargetSelector != SEND_OUTBOUND_SELECTOR
        ) revert PushWalletErrors.MalformedSessionShape();

        // Rule 4 — THE FAIL-CLOSED ANCHOR: UCEP is the sole action policy on the sole action.
        // Strip UCEP => zero action policies => the engine's minimum-one floor kills every request.
        if (
            session.actions[0].actionPolicies.length != 1
                || session.actions[0].actionPolicies[0].policy != CANONICAL_UCEP
        ) revert PushWalletErrors.MalformedSessionShape();

        if (address(session.sessionValidator) != CANONICAL_SESSION_VALIDATOR) {
            revert PushWalletErrors.MalformedSessionShape();
        }

        // THE KEY-CONFIG CHECK, AND THE CATCH IS BARE ON PURPOSE.
        //
        // `validateConfig` is THREE-VALUED: it returns true, returns false, or REVERTS on
        // structurally garbled initData. A bare `catch { }` catches all of it;
        // `catch Error(string memory)` catches only string reverts and would silently miss the
        // compiler `Panic(uint256)` that is the exact case this wrap exists for.
        //
        // WHY WRAP HERE WHEN UCEP'S DECODE IS DELIBERATELY NOT WRAPPED: there, wrapping would have
        // introduced an EXTERNAL CALL into `checkAction`, whose safety rests on having none. HERE
        // THE EXTERNAL CALL ALREADY EXISTS — this line is already a call to the validator. try/catch
        // adds zero new external calls; the cost is syntax. And a named error is the LOUDER failure
        // on an owner path: `Panic(0x41)` in a grant UI is noise.
        //
        // All three outcomes collapse to MalformedSessionShape(). Without this, a garbled key config
        // creates a permission that looks alive and can never validate anything.
        try IPushSessionValidator(CANONICAL_SESSION_VALIDATOR)
            .validateConfig(session.sessionValidatorInitData) returns (
            bool ok
        ) {
            if (!ok) revert PushWalletErrors.MalformedSessionShape();
        } catch {
            revert PushWalletErrors.MalformedSessionShape();
        }

        // ── step 1 · THE SALT — this wrapper's ONLY other job ──
        // Copy to memory because calldata is read-only and the salt must be overwritten. The
        // monotonic counter guarantees byte-identical terms granted twice still yield two DISTINCT
        // permission ids, and that a replaced permission's id NEVER recurs — which is what makes a
        // banked signed request die on regrant (op-hash field 5).
        Session memory sessionMem = session;
        sessionMem.salt = bytes32(uint256(_grantNonce));
        // CHECKED, deliberately. `unchecked` would buy nothing on a uint64 and would turn an
        // unreachable wrap into a SILENT SALT REUSE — the one thing the comment above promises
        // cannot happen. The checked increment is what enforces the promise.
        _grantNonce++;

        // ── step 2 · enable. The engine takes Session[] calldata, but an external call encodes a
        //    memory array identically, so copy-then-encode is the required pattern.
        Session[] memory sessions = new Session[](1);
        sessions[0] = sessionMem;
        PermissionId[] memory ids = ISmartSession(DEFAULT_SESSION_ENGINE).enableSessions(sessions);

        // ── steps 3-4 ──
        permissionId = PermissionId.unwrap(ids[0]);
        emit MandateGranted(permissionId);
    }

    /**
     * @notice Revoke one mandate. The other lifecycle operation, and the emergency lever.
     *
     * @dev    NO `nonReentrant`, NO other guard — this path must have nothing on it that can fail
     *        . STEPS 1-2 ARE THE COMPLETE BODY. Adding any other external call, module check
     *         or health probe here is the one catastrophic regression this contract can develop:
     *         blockable removal.
     *
     *         Revocation is immediate; a banked signed request dies with the id, because the id is
     *         bound into operation-hash field 5.
     */
    function stopMandate(bytes32 permissionId) external onlyOwnerOrSelf {
        // The LOUD-REVOCATION guard. Upstream `removeSession` silently no-ops on ghost ids, and an
        // incident operator must never read "revoked OK" while the mandate lives (a typo'd id).
        if (!ISmartSession(DEFAULT_SESSION_ENGINE).isPermissionEnabled(PermissionId.wrap(permissionId), address(this)))
        {
            revert PushWalletErrors.UnknownPermission(permissionId);
        }

        // Pure storage deletion upstream: no callbacks, msg.sender-scoped, no install-health
        // precondition (`SmartSessionBase.sol:329-354`).
        ISmartSession(DEFAULT_SESSION_ENGINE).removeSession(PermissionId.wrap(permissionId));

        emit MandateRevoked(permissionId);
    }

    /**
     * @notice Stop everything, one signature. THIS IS THE INCIDENT RESPONSE.
     *
     * @dev    NO `nonReentrant`, NO other guard — same reasoning as `stopMandate`. The loop's only
     *         external call is `removeSession`, which makes no external calls of its own, so there
     *         is no reentrancy vector to guard; and nothing that can fail belongs on the stop path.
     *
     *         Gas grows with permission count; wallets hold few permissions by design, and the
     *         per-id loop is the audited upstream primitive — do not batch-optimise it.
     */
    function stopAll() external onlyOwnerOrSelf {
        // Removal is BY ID, so the engine-side array shifting does not affect this memory snapshot.
        PermissionId[] memory ids = ISmartSession(DEFAULT_SESSION_ENGINE).getPermissionIDs(address(this));

        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            ISmartSession(DEFAULT_SESSION_ENGINE).removeSession(ids[i]);
            emit MandateRevoked(PermissionId.unwrap(ids[i]));
            unchecked {
                ++i;
            }
        }
    }

    // ────────────────────────── the agent door (3c) ──────────────────────────

    /**
     * @notice The agent door. PERMISSIONLESS — someone must be able to relay, and there is no
     *         bundler network. The signature, the nonce and the bound hash are the authority;
     *         never the caller.
     *
     * @dev    THE ORDER OF THESE STEPS IS NORMATIVE. Push Chain has no EntryPoint, so this
     *         function performs the EntryPoint's jobs itself: expiry, replay protection, op-hash
     *         computation, invoking the validator, and enforcing the verdict.
     *
     * @dev    NOT `payable`, yet `_execute` performs `call{value: v}` with `v` decoded from the
     *         VALIDATED calldata — so an agent request DOES move PC out of the wallet, from the
     *         wallet's own balance, bounded by UCEP gate 8. That is intended and necessary (the
     *         gateway's gas swap is paid in PC). The relayer cannot attach value; PC leaves only
     *         via a validated request.
     *
     * @dev    FAILURE ATOMICITY, relied on totally: a revert anywhere — validation, verdict,
     *         dispatch, the gateway call, an inner call — unwinds the ENTIRE transaction: the
     *         nonce, UCEP's counters, everything. A failed action costs the relayer gas and changes
     *         nothing else. NEVER wrap dispatch in try/catch to "preserve" the nonce:
     *         atomicity is worth more than lane continuity, and there is no EntryPoint to
     *         catch-and-charge.
     */
    function executeWithSession(
        address validator,
        bytes32 mode,
        bytes calldata executionCalldata,
        bytes calldata signature,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint48 requestExpiry
    ) external nonReentrant {
        // ── step 1 · request expiry ──
        // 0 MEANS NO EXPIRY (the 4337 convention, ruled). There is no ceiling on how far ahead a
        // non-zero stamp may sit — a year-ahead expiry is ACCEPTED, and a test pins that.
        if (requestExpiry != 0 && block.timestamp > requestExpiry) revert PushWalletErrors.RequestExpired();

        // ── step 2 · validator installed ──
        if (!_installedValidators[validator]) revert PushWalletErrors.ValidatorNotInstalled(validator);

        // ── step 3 · CONSUME THE REPLAY POSITION, BEFORE VALIDATION ──
        // Moving this after validation "so a failed validation doesn't burn the lane" reintroduces
        // replay through a re-entrant validator. A failed validation reverts the whole
        // transaction, so the lane is untouched anyway. Lanes are independent: a stalled lane never
        // blocks another. The transient guard covers the door; the consumed position covers the
        // universe.
        uint64 expected = _nonces[nonceKey];
        if (nonceSeq != expected) revert PushWalletErrors.InvalidNonce(nonceKey, expected, nonceSeq);
        _nonces[nonceKey] = expected + 1;

        // ── step 4 · REQUIRE USE MODE FIRST, then extract the permission id ──
        // Engine wire format is `mode byte ‖ permissionId ‖ sessionSig` IN USE MODE ONLY
        // (`EncodeLib.sol:29-37`). IN ENABLE MODE THE ENGINE DOES NOT READ BYTES [1:33] AS A
        // PERMISSION ID AT ALL — it derives the id from the session data — so without this mode
        // check the wallet would bind arbitrary session bytes into op-hash field 5. Field 5 is the
        // agent's signed commitment to WHICH MANDATE, and its meaning must not depend on an
        // unchecked byte or on a ruling in another contract's PRD. The engine's own handling is the
        // second line of defence, not the first.
        if (signature.length < 33 || uint8(signature[0]) != uint8(SmartSessionMode.USE)) {
            revert PushWalletErrors.InvalidSessionSignature();
        }
        bytes32 permissionId = bytes32(signature[1:33]);

        // ── step 5 · the operation hash — from ARRIVED DATA ONLY, never accepted from outside ──
        bytes32 opHash = _computeOpHash(
            validator, permissionId, mode, keccak256(executionCalldata), nonceKey, nonceSeq, requestExpiry
        );

        // ── steps 6-8 · build, validate, enforce the verdict ──
        _validate(validator, mode, executionCalldata, signature, nonceKey, nonceSeq, opHash);

        // ── step 9 · dispatch THE EXACT VALIDATED BYTES ──
        _gateAndDispatch(mode, executionCalldata);

        // ── step 10 · the Push-side attribution record ──
        // Mandate-level monitoring without touching the gateway's frozen event.
        emit MandateActionAuthorized(permissionId, nonceKey, nonceSeq, opHash);
    }

    /**
     * @dev Step 9's mode gate and dispatch.
     *
     *      The agent path NEVER batches at the 7579 layer — batching lives two layers deeper,
     *      inside the multicall payload, bounded by UCEP's ten. The wallet substitutes nothing: if
     *      dispatch bytes differed from validated bytes, every UCEP pin would be void.
     *
     *      SPLIT OUT FOR STACK DEPTH ONLY, and it is load-bearing for tooling: inlined, this
     *      function does not compile with the optimizer off, which is the configuration
     *      `forge coverage` uses. Behaviour is identical either way.
     */
    function _gateAndDispatch(bytes32 mode, bytes calldata executionCalldata) internal {
        (CallType callType, ExecType execType,,) = ModeCode.wrap(mode).decode();
        if (callType != CALLTYPE_SINGLE || execType != EXECTYPE_DEFAULT) {
            revert PushWalletErrors.UnsupportedExecutionMode();
        }
        (address target, uint256 value, bytes calldata callData) = ExecutionLib.decodeSingle(executionCalldata);
        _execute(target, value, callData);
    }

    /**
     * @dev The ten-field operation hash. `abi.encode`, NOT `encodePacked` — a fixed
     *      10 x 32-byte layout with no ambiguity.
     *
     *      THE SHIPPED v2 CODE BOUND EIGHT FIELDS. Ten is the v3 design; fields 5 and 10 are the
     *      additions, and regressing to eight is forbidden for any reason including "v2
     *      compatibility" — there are no v2 signatures to be compatible with.
     *
     *      Field 5 (permissionId) looks redundant given per-policy signers. It is not: the engine
     *      reads permissionId from an UNSIGNED signature prefix, so if one provider reuses a key
     *      across several permissions on one wallet, a relayer could re-prefix a signed request
     *      from mandate A to mandate B and charge the wrong budget. It is also what makes a banked
     *      request DIE ON REGRANT (new id => old signatures unverifiable) — one of the four
     *      permanent guarantees of the system.
     *
     *      Field 10 makes the expiry stamp unforgeable: a relayer cannot extend or trim a
     *      request's lifetime.
     *
     *      Split into its own function for stack depth only; it reads nothing but its arguments,
     *      `block.chainid` and `address(this)`.
     */
    function _computeOpHash(
        address validator,
        bytes32 permissionId,
        bytes32 mode,
        bytes32 executionCalldataHash,
        uint192 nonceKey,
        uint64 nonceSeq,
        uint48 requestExpiry
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN, //  1 cross-protocol isolation
                block.chainid, //  2 cross-chain replay
                address(this), //  3 cross-account replay
                validator, //  4 validator substitution
                permissionId, //  5 cross-mandate substitution
                mode, //  6 single->batch substitution
                executionCalldataHash, //  7 payload integrity — covers every nested layer
                nonceKey, //  8 lane substitution
                nonceSeq, //  9 straight replay
                requestExpiry //  10 expiry substitution
            )
        );
    }

    /**
     * @dev Steps 6-8: build the operation, validate it, and enforce the verdict.
     *      Split out for stack depth; it performs exactly one external call — to the validator.
     */
    function _validate(
        address validator,
        bytes32 mode,
        bytes calldata executionCalldata,
        bytes calldata signature,
        uint192 nonceKey,
        uint64 nonceSeq,
        bytes32 opHash
    ) internal {
        // ── step 6 · the PackedUserOperation, ABI SHAPE ONLY — there is no EntryPoint ──
        PackedUserOperation memory op;
        // The engine requires userOp.sender == msg.sender and reverts otherwise.
        op.sender = address(this);
        // An informational mirror of the lane pair.
        op.nonce = (uint256(nonceKey) << 64) | uint256(nonceSeq);
        op.initCode = "";
        // THE SELECTOR DECIDES WHICH ENGINE BRANCH RUNS, AND ONLY ONE BRANCH IS SAFE. When it
        // equals IERC7579Account.execute.selector the engine decodes the mode and calls the action
        // policy through checkSingle7579Exec, forwarding THE REAL DECODED VALUE — which is what
        // UCEP's gas-value gate compares against (`PolicyLib.sol:196`). Every other selector falls
        // through to the generic branch, which calls the policy with target = account and a
        // HARDCODED value = 0. Hence the frozen signature: `execute(bytes32,bytes)`.
        op.callData = abi.encodeWithSelector(this.execute.selector, mode, executionCalldata);
        // Zeros. Gas-reading userOp policies are inert by construction and must never be attached
        // — and the grant-shape check makes one impossible.
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        // MUST REMAIN EMPTY FOREVER. A non-empty value trips the engine's
        // paymaster-permit check and reverts. There is no paymaster in this design and never will be.
        op.paymasterAndData = "";
        op.signature = signature;

        // ── step 7 · validate ──
        // The interface takes PackedUserOperation MEMORY and returns ValidationData, a uint256 UDVT
        // (`DataTypes.sol:163`). There is no implicit conversion; without the explicit unwrap this
        // line does not compile.
        //
        // The engine runs the action policy — UCEP, the only one, which carries the mandate expiry
        // itself — FIRST, and verifies the session signature LAST (upstream ordering, adopted not
        // chosen). Consequence inherited by every future policy: policies run on calldata that has
        // not yet been authenticated.
        uint256 vd = ValidationData.unwrap(ISmartSession(validator).validateUserOp(op, opHash));

        // ── step 8 · ENFORCE THE VERDICT — the EntryPoint's job, done explicitly ──
        // Silently skipping this makes UCEP's expiry gate DECORATIVE: the engine returns the window
        // in `vd` and only the wallet enforces it. It is not optional.
        address authorizer = address(uint160(vd));
        uint48 validUntil = uint48(vd >> 160); // 0 = unbounded
        uint48 validAfter = uint48(vd >> 208);

        if (authorizer != address(0)) revert PushWalletErrors.ValidationFailed(authorizer);
        if (block.timestamp < validAfter) revert PushWalletErrors.OutsideTimeWindow(validAfter, validUntil);
        if (validUntil != 0 && block.timestamp > validUntil) {
            revert PushWalletErrors.OutsideTimeWindow(validAfter, validUntil);
        }
    }

    // ───────────────────────────── module manager ─────────────────────────────

    /**
     * @notice Install a validator module.
     * @dev    In shipped v3 the catalogue is one module (the engine, installed by the factory).
     *         This exists as the DISASTER-RECOVERY LEVER: if the engine is ever found defective, a
     *         corrected validator installs on existing wallets — addresses, destination accounts
     *         and funds all unmoved. It sits unused for years and pays for itself the day it is
     *         needed.
     */
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        external
        onlyOwner
        nonReentrant
    {
        if (moduleTypeId != MODULE_TYPE_VALIDATOR) {
            revert PushWalletErrors.UnsupportedModuleType(moduleTypeId);
        }
        if (module == address(0) || module.code.length == 0) revert PushWalletErrors.InvalidModuleAddress();
        if (_installedValidators[module]) revert PushWalletErrors.ModuleAlreadyInstalled(module);

        _installedValidators[module] = true;

        // Full gas, bubbling revert: install is a normal owner action; if the module cannot
        // initialise, the owner should know loudly.
        IERC7579Module(module).onInstall(initData);

        emit ModuleInstalled(moduleTypeId, module);
    }

    /**
     * @notice Uninstall a validator module. Removal always proceeds.
     * @dev    THE ACCOUNT UNMARKS FIRST (step 4 below). The account is the source of truth for what
     *         is installed; a module whose internal state goes stale is the module's problem. This
     *         ordering is what makes removal unblockable by a hostile module.
     */
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        onlyOwner
        nonReentrant
    {
        if (moduleTypeId != MODULE_TYPE_VALIDATOR) {
            revert PushWalletErrors.UnsupportedModuleType(moduleTypeId);
        }
        if (!_installedValidators[module]) revert PushWalletErrors.ValidatorNotInstalled(module);

        // THE ENGINE-SCOPED WEDGE GUARD — scoped EXACTLY to the engine constant, nothing else.
        //
        // Uninstalling the engine with live permissions runs its unbounded cleanup loop under the
        // 100k stipend, dies midway, leaves dangling rows, and the engine then refuses reinstall
        // until each row is manually removed. The guard forces the correct order (`stopAll()`
        // first) at the contract level.
        //
        // IT APPLIES TO NO OTHER MODULE. A hostile third-party validator must never
        // be able to block its own removal, so the unblockable-removal guarantee stands for
        // everything but trusted code checked via a capped, failure-tolerant staticcall.
        if (module == DEFAULT_SESSION_ENGINE) {
            (bool ok, bytes memory ret) = module.staticcall{ gas: ENGINE_STATE_PROBE_GAS }(
                abi.encodeCall(ISmartSession.isInitialized, (address(this)))
            );
            if (ok && ret.length >= 32 && abi.decode(ret, (bool))) {
                revert PushWalletErrors.EngineStillHoldsPermissions();
            }
            // Probe reverted / ran out of gas / returned garbage => PROCEED with removal: the guard
            // exists to prevent an ordering mistake, never to make a broken engine irremovable.
        }

        _installedValidators[module] = false;

        // A callback that reverts or burns the whole stipend is still removed; the event is the audit trail.
        try IERC7579Module(module).onUninstall{ gas: UNINSTALL_CALLBACK_GAS_STIPEND }(deInitData) { }
        catch {
            emit UninstallCallbackFailed(module);
        }

        emit ModuleUninstalled(moduleTypeId, module);
    }

    // ─────────────────────────── module & mode views ───────────────────────────

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata) external view returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR && _installedValidators[module];
    }

    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    /// @dev Answers for the ACCOUNT AS A WHOLE, i.e. the owner door's capability. The agent door's
    ///      single-only restriction is contextual and enforced on the agent door itself, not here.
    function supportsExecutionMode(bytes32 mode) external pure returns (bool) {
        (CallType callType, ExecType execType,,) = ModeCode.wrap(mode).decode();
        if (execType != EXECTYPE_DEFAULT) return false;
        return callType == CALLTYPE_SINGLE || callType == CALLTYPE_BATCH;
    }

    // ───────────────────────────── views & plumbing ─────────────────────────────

    function owner() external view returns (address) {
        return _owner();
    }

    function factory() external view returns (address) {
        return _factory();
    }

    /// @dev EntryPoint-equivalent SDK ergonomics.
    function getNonce(uint192 nonceKey) external view returns (uint64) {
        return _nonces[nonceKey];
    }

    function grantNonce() external view returns (uint64) {
        return _grantNonce;
    }

    function accountId() external pure returns (string memory) {
        return ACCOUNT_ID;
    }

    // The four wiring views let the SDK, monitoring and the deployment-record check read a
    // deployed wallet's wiring without a source lookup.

    function sessionEngine() external view returns (address) {
        return DEFAULT_SESSION_ENGINE;
    }

    function ucep() external view returns (address) {
        return CANONICAL_UCEP;
    }

    function sessionValidator() external view returns (address) {
        return CANONICAL_SESSION_VALIDATOR;
    }

    function universalGateway() external view returns (address) {
        return UNIVERSAL_GATEWAY_PC;
    }

    /// @dev Accepts PC with no logic — the wallet pays outbound gas swaps from its own balance,
    ///      and refunds land here.
    receive() external payable { }

    // Destination-side refunds and NFT transfers must land.

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev ERC-165 + the two receiver interfaces, and NOTHING ELSE.
     *
     *      IT DOES NOT REPORT `IERC7579Account`, AND MUST NOT. The wallet
     *      deliberately implements that interface PARTIALLY — it refuses module types 2/3/4, has
     *      no fallback handler, and restricts execution modes. Advertising that interface id
     *      through ERC-165 would be a FALSE CLAIM to exactly the tooling that probes for it;
     *      omission is honest, advertisement is not. Tooling detects 7579 accounts through
     *      `accountId()` / `supportsModule` / `supportsExecutionMode`, which are all present.
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId // 0x01ffc9a7
            || interfaceId == 0x150b7a02 // IERC721Receiver
            || interfaceId == 0x4e2312e0; // IERC1155Receiver
    }

    /**
     * @notice ALWAYS INVALID (ruled). The wallet never signs as an ERC-1271 party in v3.
     * @dev    A second signature entry point is surface without a flow. The body is a constant
     *         return — no logic, no future hook. This is also what makes the engine's ENABLE-mode
     *         flow dead on these wallets.
     */
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}
