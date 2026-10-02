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
 *         `msg.sender` at the gateway, which is what binds it to its destination-chain account.
 *
 * @dev    - Push Chain has no ERC-4337 EntryPoint, so this wallet performs the EntryPoint's jobs
 *           itself in `executeWithSession`.
 *         - An ERC-7579 modular account restricted to validator modules; executor, fallback and
 *           hook modules are refused. A hook would run on the owner path and could block it.
 *         - `execute` is the owner door: no policy is ever consulted on it.
 *         - `executeWithSession` is the agent door: permissionless to call, authorised entirely by
 *           signature, nonce and bound operation hash.
 *         - Deliberately near-stateless. A request exists only for the transaction that carries it.
 */
contract PushAgentWallet is IPushAgentWallet, ReentrancyGuardTransient {
    using ModeLib for ModeCode;

    /// @dev ERC-7579 account id, in vendor.account.semver form.
    string internal constant ACCOUNT_ID = "push.agentwallet.1.0.0";

    /// @dev The only ERC-7579 module type this account supports.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;

    /// @dev Gas stipend for a module's uninstall callback.
    uint256 internal constant UNINSTALL_CALLBACK_GAS_STIPEND = 100_000;

    /// @dev Gas cap on the pre-uninstall state probe of the session engine.
    uint256 internal constant ENGINE_STATE_PROBE_GAS = 30_000;

    // The four wiring addresses. Resolved from the implementation's runtime bytecode, so every
    // clone reads them correctly through delegatecall.

    /// @dev The permission engine installed as the account's default validator.
    address internal immutable DEFAULT_SESSION_ENGINE;

    /// @dev The canonical action policy every mandate must name.
    address internal immutable CANONICAL_UCEP;

    /// @dev The canonical session validator every mandate must name.
    address internal immutable CANONICAL_SESSION_VALIDATOR;

    /// @dev The Push-side outbound gateway, the only target an agent action may reach.
    address internal immutable UNIVERSAL_GATEWAY_PC;

    /// @dev One-shot latch for initializeAccount.
    bool private _initialized;

    /// @dev Monotonic salt source for permission ids; never reused.
    uint64 private _grantNonce;

    /// @dev The account's entire module registry.
    mapping(address => bool) private _installedValidators;

    /// @dev Replay lanes: lane key => next expected sequence number.
    mapping(uint192 => uint64) private _nonces;

    /**
     * @notice Sets the wallet's permanent wiring and locks the implementation itself.
     *
     * @dev    - Reverts with `InvalidModuleAddress` if any of the four addresses is zero.
     *         - Sets the initialised latch, so the implementation can never be initialised or
     *           driven directly; only clones of it can.
     *
     * @param  sessionEngine_       Permission engine installed as the default validator.
     * @param  ucep_                Canonical action policy every mandate must name.
     * @param  sessionValidator_    Canonical session validator every mandate must name.
     * @param  universalGatewayPC_  Push-side outbound gateway.
     */
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

        _initialized = true;
    }

    /// @dev Reverts unless the caller is the clone's immutable-args owner.
    modifier onlyOwner() {
        if (msg.sender != _owner()) revert PushWalletErrors.NotOwner();
        _;
    }

    /**
     * @dev Reverts unless the caller is the owner or the wallet itself. Applied to the three
     *      lifecycle functions only.
     *
     *      - A batch entry targeting the wallet arrives with `msg.sender == address(this)`, so
     *        without this the owner's own one-signature change batch reverts against itself.
     *      - Widening to self is safe because self is reachable only through the owner door: the
     *        only thing that can make the wallet call itself is `_execute`, and the agent door's
     *        dispatch is refused three independent ways.
     *      - Not applied to installModule or uninstallModule; nothing needs them batched.
     */
    modifier onlyOwnerOrSelf() {
        if (msg.sender != _owner() && msg.sender != address(this)) revert PushWalletErrors.NotOwner();
        _;
    }

    /**
     * @dev Reads the owner out of the clone's immutable args.
     *
     *      - Clone args are 40 bytes: owner at 0-19, factory at 20-39.
     *      - Read from bytecode on every call and never cached; a storage mirror of an immutable is
     *        drift surface.
     *      - Meaningful only on a clone. `Clones.fetchCloneArgs` is undefined on a non-clone, and on
     *        the implementation it returns a slice of that contract's own runtime bytecode.
     *      - No guard is added for the implementation case: every door on the implementation is
     *        already inert for an independent reason.
     *
     * @return The clone's owner.
     */
    function _owner() internal view returns (address) {
        return address(bytes20(Clones.fetchCloneArgs(address(this))));
    }

    /**
     * @dev Reads the deploying factory out of the clone's immutable args.
     * @return The factory recorded at clone creation.
     */
    function _factory() internal view returns (address) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        return address(bytes20(_slice20(args, 20)));
    }

    /**
     * @dev Reads 20 bytes at `start` out of a memory blob, without assuming a length. The
     *      short-blob branch is unreachable from the single call site and is expected to show as
     *      uncovered.
     *
     * @param  data   Blob to read from.
     * @param  start  Byte offset to read at.
     * @return out    The 20 bytes at `start`, or zero if the blob is too short.
     */
    function _slice20(bytes memory data, uint256 start) private pure returns (bytes20 out) {
        if (data.length < start + 20) return bytes20(0);
        assembly {
            out := mload(add(add(data, 0x20), start))
        }
    }

    /**
     * @notice Factory-only, callable exactly once. Installs the session engine as the account's
     *         sole validator.
     *
     * @dev    - Reverts with `NotFactory` unless the caller is the clone's recorded factory.
     *         - Reverts with `AlreadyInitialized` if the latch is already set.
     *         - Sets the latch, marks the engine installed, then calls `onInstall("")` with full gas
     *           and bubbles any revert, so the factory's deploy transaction unwinds atomically.
     *         - Emits `ModuleInstalled`, then `AccountInitialized`.
     *         - Session data is never passed here; grants travel only through `grantMandate`.
     */
    function initializeAccount() external {
        if (msg.sender != _factory()) revert PushWalletErrors.NotFactory();
        if (_initialized) revert PushWalletErrors.AlreadyInitialized();

        _initialized = true;
        _installedValidators[DEFAULT_SESSION_ENGINE] = true;

        IERC7579Module(DEFAULT_SESSION_ENGINE).onInstall("");

        emit ModuleInstalled(MODULE_TYPE_VALIDATOR, DEFAULT_SESSION_ENGINE);
        emit AccountInitialized(_owner(), DEFAULT_SESSION_ENGINE);
    }

    /**
     * @notice The owner door. Executes a single call or a batch on the owner's behalf; no policy is
     *         ever consulted.
     *
     * @dev    - Reverts unless the caller is the owner; reentrancy-guarded.
     *         - Reverts on any execution type other than default, and on any call type other than
     *           single or batch.
     *         - Reads only the immutable-args owner and its calldata. No module, policy or engine
     *           state may ever be consulted here, so the door still works with the engine
     *           uninstalled, with a hostile validator installed, or in ghost-mandate state.
     *         - The signature is frozen at `execute(bytes32,bytes)`: the session engine branches on
     *           this exact selector, and any other shape routes validation down a path where the
     *           action policy sees a hardcoded zero value instead of the real one.
     *         - Batch is required product surface: the permission-change flow is one owner signature
     *           batching a spend assertion, a revoke and a grant.
     *         - Dispatches through `_execute` and emits `OwnerExecuted`.
     *         - There is no separate withdraw function; withdrawal, revocation escort and incident
     *           response all run through this door.
     *
     * @param  mode              ERC-7579 mode word; call type and execution type are decoded from it.
     * @param  executionCalldata Encoded execution, single or batch according to `mode`.
     */
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable onlyOwner nonReentrant {
        ModeCode m = ModeCode.wrap(mode);
        (CallType callType, ExecType execType,,) = m.decode();

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
            revert PushWalletErrors.UnsupportedExecutionMode();
        }

        emit OwnerExecuted(mode, keccak256(executionCalldata));
    }

    /**
     * @dev Plain call, bubbling the callee's revert data verbatim. Shared by both doors so the agent
     *      path executes the exact validated bytes.
     *
     * @param target    Address to call.
     * @param value     Native PC to send with the call.
     * @param callData  Calldata to pass, forwarded unchanged.
     */
    function _execute(address target, uint256 value, bytes calldata callData) internal {
        (bool ok, bytes memory ret) = target.call{ value: value }(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice Grants one mandate to an agent key. One of exactly two lifecycle operations.
     *
     * @dev    - Reverts unless the caller is the owner or the wallet itself.
     *         - Rejects any session that is not the one shape this wallet permits, all with
     *           `MalformedSessionShape`: any user-op policy present, any ERC-7739 content or policy,
     *           the ERC-4337 paymaster permit set, an action count other than one, an action whose
     *           target is not the gateway or whose selector is not the outbound send, an action
     *           policy set that is not exactly the canonical policy, or a session validator that is
     *           not the canonical one.
     *         - Rejects a key config the session validator does not accept, including one that makes
     *           it revert; that is why the call is wrapped in a bare catch rather than a typed one,
     *           which would miss the compiler panic this exists to absorb. Wrapping is correct here
     *           only because the external call already exists; the action policy's own decode is
     *           deliberately not wrapped, since there it would introduce one.
     *         - Refusing the paymaster permit keeps dead surface dead: setting it would write a live
     *           permit row into engine storage, and that row decides whether a non-empty
     *           `paymasterAndData` is rejected outright or instead requires a user-op policy to run,
     *           which this shape forbids.
     *         - Overwrites the caller's salt with the wallet's monotonic grant counter, so identical
     *           terms granted twice yield distinct permission ids and a replaced id never recurs.
     *           That is what makes a banked signed request die on regrant.
     *         - Enables the session on the engine and emits `MandateGranted`.
     *         - Validates the session's shape only. The caps, allow-list and expiry inside the policy
     *           config are the policy's own concern; do not extend this into term validation.
     *         - Carries no reentrancy guard: the guard would trip on the owner's own change batch,
     *           and the engine's enable path never calls back into the account.
     *
     * @param  session       The session to enable. Its `salt` field is ignored and overwritten.
     * @return permissionId  The engine's id for the newly enabled mandate.
     */
    function grantMandate(Session calldata session) external onlyOwnerOrSelf returns (bytes32 permissionId) {
        if (session.userOpPolicies.length != 0) revert PushWalletErrors.MalformedSessionShape();

        if (
            session.erc7739Policies.allowedERC7739Content.length != 0
                || session.erc7739Policies.erc1271Policies.length != 0
        ) revert PushWalletErrors.MalformedSessionShape();

        if (session.permitERC4337Paymaster) revert PushWalletErrors.MalformedSessionShape();

        if (session.actions.length != 1) revert PushWalletErrors.MalformedSessionShape();

        if (
            session.actions[0].actionTarget != UNIVERSAL_GATEWAY_PC
                || session.actions[0].actionTargetSelector != SEND_OUTBOUND_SELECTOR
        ) revert PushWalletErrors.MalformedSessionShape();

        if (
            session.actions[0].actionPolicies.length != 1
                || session.actions[0].actionPolicies[0].policy != CANONICAL_UCEP
        ) revert PushWalletErrors.MalformedSessionShape();

        if (address(session.sessionValidator) != CANONICAL_SESSION_VALIDATOR) {
            revert PushWalletErrors.MalformedSessionShape();
        }

        try IPushSessionValidator(CANONICAL_SESSION_VALIDATOR)
            .validateConfig(session.sessionValidatorInitData) returns (
            bool ok
        ) {
            if (!ok) revert PushWalletErrors.MalformedSessionShape();
        } catch {
            revert PushWalletErrors.MalformedSessionShape();
        }

        Session memory sessionMem = session;
        sessionMem.salt = bytes32(uint256(_grantNonce));
        // Checked on purpose: a wrapping counter would mean silent salt reuse.
        _grantNonce++;

        Session[] memory sessions = new Session[](1);
        sessions[0] = sessionMem;
        PermissionId[] memory ids = ISmartSession(DEFAULT_SESSION_ENGINE).enableSessions(sessions);

        permissionId = PermissionId.unwrap(ids[0]);
        emit MandateGranted(permissionId);
    }

    /**
     * @notice Revoke one mandate. The other lifecycle operation, and the emergency lever.
     *
     * @dev    - Reverts unless the caller is the owner or the wallet itself.
     *         - Reverts with `UnknownPermission` if the id is not enabled, because the upstream
     *           removal silently no-ops on a ghost id and an operator must never read "revoked"
     *           while the mandate lives.
     *         - Removes the session and emits `MandateRevoked`. Revocation is immediate, and a
     *           banked signed request dies with the id.
     *         - Deliberately carries no reentrancy guard and no health probe: nothing that can fail
     *           belongs on the stop path, since blockable removal is the one regression this
     *           function can develop.
     *
     * @param  permissionId  The mandate to revoke.
     */
    function stopMandate(bytes32 permissionId) external onlyOwnerOrSelf {
        if (!ISmartSession(DEFAULT_SESSION_ENGINE).isPermissionEnabled(PermissionId.wrap(permissionId), address(this)))
        {
            revert PushWalletErrors.UnknownPermission(permissionId);
        }

        ISmartSession(DEFAULT_SESSION_ENGINE).removeSession(PermissionId.wrap(permissionId));

        emit MandateRevoked(permissionId);
    }

    /**
     * @notice Revokes every mandate on this wallet in one call. The incident-response lever.
     *
     * @dev    - Reverts unless the caller is the owner or the wallet itself.
     *         - Snapshots the permission ids, removes each by id, and emits `MandateRevoked` per id.
     *           Removal is by id, so engine-side array shifting cannot disturb the snapshot.
     *         - Deliberately carries no reentrancy guard and no health probe, for the same reason as
     *           `stopMandate`.
     *         - Gas grows with permission count; wallets hold few permissions by design.
     */
    function stopAll() external onlyOwnerOrSelf {
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

    /**
     * @notice The agent door. Permissionless to call; a request is authorised by its signature, its
     *         nonce and the bound operation hash, never by the caller.
     *
     * @dev    This chain has no EntryPoint, so this function does the EntryPoint's work, in order:
     *         1. reject an expired request; a zero expiry means no expiry, per the 4337 convention
     *         2. reject an uninstalled validator
     *         3. consume the replay position, before validation
     *         4. require use mode and read the permission id from the signature prefix
     *         5. compute the operation hash from arrived data only
     *         6. build the operation, validate it, and enforce the verdict
     *         7. reject any mode other than single and default
     *         8. dispatch the exact validated bytes
     *         9. emit `MandateActionAuthorized`
     *
     *         - The nonce is consumed before validation; deferring it would reopen replay through a
     *           re-entrant validator. Lanes are independent, so a stalled lane never blocks another.
     *         - There is no ceiling on how far ahead a non-zero expiry may sit; a distant expiry is
     *           accepted.
     *         - Not payable, but a validated request does move PC out of the wallet's own balance,
     *           bounded by the policy's per-call ceiling. A relayer cannot attach value.
     *         - Any revert unwinds the whole transaction including the nonce and the policy's
     *           counters; dispatch is never wrapped in try/catch to preserve lane continuity.
     *         - Mode is single-only here: batching lives inside the multicall payload, bounded by
     *           the policy.
     *
     * @param  validator          Installed validator module to validate against.
     * @param  mode               ERC-7579 mode word; must decode to single and default.
     * @param  executionCalldata  Encoded single execution, dispatched byte-for-byte once validated.
     * @param  signature          Engine session signature: mode byte, permission id, then the
     *                            agent's signature.
     * @param  nonceKey           Replay lane to consume from.
     * @param  nonceSeq           Expected sequence number within that lane.
     * @param  requestExpiry      Unix timestamp after which the request is dead; zero means never.
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
        if (requestExpiry != 0 && block.timestamp > requestExpiry) {
            revert PushWalletErrors.RequestExpired();
        }

        if (!_installedValidators[validator]) revert PushWalletErrors.ValidatorNotInstalled(validator);

        uint64 expected = _nonces[nonceKey];
        if (nonceSeq != expected) revert PushWalletErrors.InvalidNonce(nonceKey, expected, nonceSeq);
        _nonces[nonceKey] = expected + 1;

        // Use mode only: in enable mode the engine derives the id from session data, so bytes 1:33
        // would not be a permission id.
        if (signature.length < 33 || uint8(signature[0]) != uint8(SmartSessionMode.USE)) {
            revert PushWalletErrors.InvalidSessionSignature();
        }
        bytes32 permissionId = bytes32(signature[1:33]);

        bytes32 opHash = _computeOpHash(
            validator, permissionId, mode, keccak256(executionCalldata), nonceKey, nonceSeq, requestExpiry
        );

        _validate(validator, mode, executionCalldata, signature, nonceKey, nonceSeq, opHash);

        _gateAndDispatch(mode, executionCalldata);

        emit MandateActionAuthorized(permissionId, nonceKey, nonceSeq, opHash);
    }

    /**
     * @dev Gates the mode to single and default, then dispatches the validated execution unchanged.
     *
     *      - The agent path never batches at the ERC-7579 layer; batching lives inside the multicall
     *        payload instead, bounded by the policy.
     *      - Split out for stack depth only. Inlined, this does not compile with the optimizer off,
     *        which is the configuration `forge coverage` uses.
     *
     * @param mode              ERC-7579 mode word.
     * @param executionCalldata Encoded single execution to dispatch.
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
     * @dev Builds the operation hash an agent signs.
     *
     *      - Ten fields, combined with `abi.encode` for a fixed 32-byte-per-field layout with no
     *        encoding ambiguity. The field list is frozen and must not be shortened.
     *      - Field 5 binds the request to one mandate: the engine reads the permission id from an
     *        unsigned signature prefix, so without it a relayer could re-prefix a signed request onto
     *        a different permission and charge the wrong budget. It is also what makes a banked
     *        request die once the mandate is regranted.
     *      - Field 10 makes the expiry unforgeable, so a relayer cannot extend or trim a request's
     *        lifetime.
     *      - Split out for stack depth only; it reads nothing but its arguments, `block.chainid` and
     *        `address(this)`.
     *
     * @param  validator              Validator the request names.
     * @param  permissionId           Mandate the request is bound to.
     * @param  mode                   ERC-7579 mode word.
     * @param  executionCalldataHash  Hash of the execution calldata, covering every nested layer.
     * @param  nonceKey               Replay lane.
     * @param  nonceSeq               Sequence number within that lane.
     * @param  requestExpiry          Expiry stamp carried by the request.
     * @return The hash the agent's signature must cover.
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
     * @dev Builds the operation, validates it, and enforces the verdict.
     *
     *      - Builds a `PackedUserOperation` for its ABI shape only, since there is no EntryPoint.
     *        The engine requires `sender` to equal `msg.sender`; the nonce field is an informational
     *        mirror of the lane pair.
     *      - The callData selector must be `execute(bytes32,bytes)`, because that is the only engine
     *        branch that decodes the mode and forwards the real decoded value to the action policy.
     *        Every other selector reaches the policy with the account as target and a hardcoded zero
     *        value, which would make the policy's value gate compare against nothing.
     *      - Gas fields are zero and `paymasterAndData` must stay empty, or the engine's paymaster
     *        permit check reverts.
     *      - Calls the validator, then enforces the returned authorizer and time window itself. That
     *        is the EntryPoint's job, and doing it here is what makes the policy's expiry gate real
     *        rather than decorative.
     *      - The engine runs the action policy before verifying the session signature, so policies
     *        see calldata that is not yet authenticated.
     *      - Performs exactly one external call, to the validator. Split out for stack depth.
     *
     * @param validator          Validator module to call.
     * @param mode               ERC-7579 mode word, re-encoded into the operation's calldata.
     * @param executionCalldata  Execution calldata, re-encoded into the operation's calldata.
     * @param signature          Engine session signature.
     * @param nonceKey           Replay lane, mirrored into the operation's nonce field.
     * @param nonceSeq           Sequence number, mirrored into the operation's nonce field.
     * @param opHash             Hash the validator checks the signature against.
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
        PackedUserOperation memory op;
        op.sender = address(this);
        op.nonce = (uint256(nonceKey) << 64) | uint256(nonceSeq);
        op.initCode = "";
        op.callData = abi.encodeWithSelector(this.execute.selector, mode, executionCalldata);
        op.accountGasLimits = bytes32(0);
        op.preVerificationGas = 0;
        op.gasFees = bytes32(0);
        op.paymasterAndData = "";
        op.signature = signature;

        uint256 vd = ValidationData.unwrap(ISmartSession(validator).validateUserOp(op, opHash));

        address authorizer = address(uint160(vd));
        uint48 validUntil = uint48(vd >> 160); // 0 = unbounded
        uint48 validAfter = uint48(vd >> 208);

        if (authorizer != address(0)) revert PushWalletErrors.ValidationFailed(authorizer);
        if (block.timestamp < validAfter) revert PushWalletErrors.OutsideTimeWindow(validAfter, validUntil);
        if (validUntil != 0 && block.timestamp > validUntil) {
            revert PushWalletErrors.OutsideTimeWindow(validAfter, validUntil);
        }
    }

    /**
     * @notice Installs a validator module.
     *
     * @dev    - Reverts unless the caller is the owner; reentrancy-guarded.
     *         - Rejects any module type but validator, the zero address, an address with no code,
     *           and a module that is already installed.
     *         - Marks the module installed, calls `onInstall` with full gas and bubbles any revert,
     *           then emits `ModuleInstalled`.
     *         - Exists as the recovery lever: a corrected validator can be installed on an existing
     *           wallet without moving addresses or funds.
     *
     * @param  moduleTypeId  ERC-7579 module type; only the validator type is accepted.
     * @param  module        Module to install.
     * @param  initData      Opaque data forwarded to the module's `onInstall`.
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

        IERC7579Module(module).onInstall(initData);

        emit ModuleInstalled(moduleTypeId, module);
    }

    /**
     * @notice Uninstalls a validator module. Removal always proceeds.
     *
     * @dev    - Reverts unless the caller is the owner; reentrancy-guarded.
     *         - Rejects any module type but validator, and a module that is not installed.
     *         - If and only if the module is the session engine, probes its initialised state under
     *           a gas cap and refuses removal while it still holds permissions. Uninstalling the
     *           engine with live permissions would run its cleanup loop out of gas and leave rows it
     *           then refuses to reinstall over, so the guard forces a `stopAll` first.
     *         - Unmarks the module before calling back, so a module can never block its own removal.
     *         - Calls `onUninstall` under a stipend inside try/catch, emitting
     *           `UninstallCallbackFailed` if it reverts or exhausts the stipend, then emits
     *           `ModuleUninstalled`.
     *         - The probe is scoped to the engine alone, so a hostile third-party validator can
     *           never block its own removal.
     *         - A probe that reverts or runs out of gas proceeds with removal: the guard exists to
     *           prevent an ordering mistake, not to make a broken engine permanent.
     *
     * @param  moduleTypeId  ERC-7579 module type; only the validator type is accepted.
     * @param  module        Module to uninstall.
     * @param  deInitData    Opaque data forwarded to the module's `onUninstall`.
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

        if (module == DEFAULT_SESSION_ENGINE) {
            (bool ok, bytes memory ret) = module.staticcall{ gas: ENGINE_STATE_PROBE_GAS }(
                abi.encodeCall(ISmartSession.isInitialized, (address(this)))
            );
            if (_probeReportsLivePermissions(ret)) revert PushWalletErrors.EngineStillHoldsPermissions();
        }

        _installedValidators[module] = false;

        try IERC7579Module(module).onUninstall{ gas: UNINSTALL_CALLBACK_GAS_STIPEND }(deInitData) { }
        catch {
            emit UninstallCallbackFailed(module);
        }

        emit ModuleUninstalled(moduleTypeId, module);
    }

    /**
     * @dev Reads the uninstall probe's verdict without ever reverting.
     *
     *      - `abi.decode(ret, (bool))` is NOT usable here: a probe that returns exactly 32 bytes
     *        which are not a canonical bool (`0` or `1`) makes the decoder revert, and that revert
     *        happens INSIDE the guard expression, so a malformed-but-successful probe blocks
     *        removal instead of failing open. The word is compared directly instead.
     *      - Only the canonical `1` counts as "still holds permissions". Every other outcome of
     *        the probe - reverted, out of gas, short return, no return, or a full-length
     *        non-canonical word - proceeds with removal, which is the fail-open property the
     *        guard's own contract promises.
     *      - A canonical `1` still blocks removal, so the ordering mistake this guard exists to
     *        prevent remains caught.
     *
     * @param ret  Raw returndata from the `isInitialized` staticcall.
     * @return Whether the probe affirmatively reported live permissions.
     */
    function _probeReportsLivePermissions(bytes memory ret) private pure returns (bool) {
        if (ret.length < 32) return false;
        uint256 word;
        assembly {
            word := mload(add(ret, 0x20))
        }
        return word == 1;
    }

    /**
     * @notice Whether `module` is installed under `moduleTypeId`.
     * @param  moduleTypeId  ERC-7579 module type to query.
     * @param  module        Module to query.
     * @return True only for an installed validator.
     */
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata) external view returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR && _installedValidators[module];
    }

    /**
     * @notice Whether this account supports an ERC-7579 module type.
     * @param  moduleTypeId  Module type to query.
     * @return True only for the validator type.
     */
    function supportsModule(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    /**
     * @notice Whether this account supports an ERC-7579 execution mode.
     * @dev    Answers for the account as a whole; the agent door additionally restricts itself to
     *         single calls.
     * @param  mode  ERC-7579 mode word to query.
     * @return True for default execution in single or batch call type.
     */
    function supportsExecutionMode(bytes32 mode) external pure returns (bool) {
        (CallType callType, ExecType execType,,) = ModeCode.wrap(mode).decode();
        if (execType != EXECTYPE_DEFAULT) return false;
        return callType == CALLTYPE_SINGLE || callType == CALLTYPE_BATCH;
    }

    /// @notice The wallet's owner, read from the clone's immutable args.
    function owner() external view returns (address) {
        return _owner();
    }

    /// @notice The factory that deployed this wallet.
    function factory() external view returns (address) {
        return _factory();
    }

    /**
     * @notice Next expected sequence number in `nonceKey`'s replay lane.
     * @param  nonceKey  Replay lane to query.
     * @return The sequence number the next request in that lane must carry.
     */
    function getNonce(uint192 nonceKey) external view returns (uint64) {
        return _nonces[nonceKey];
    }

    /// @notice The salt the next grant will use.
    function grantNonce() external view returns (uint64) {
        return _grantNonce;
    }

    /// @notice The ERC-7579 account id, in vendor.account.semver form.
    function accountId() external pure returns (string memory) {
        return ACCOUNT_ID;
    }

    /// @notice The permission engine this wallet installs as its default validator.
    function sessionEngine() external view returns (address) {
        return DEFAULT_SESSION_ENGINE;
    }

    /// @notice The canonical action policy every mandate on this wallet must name.
    function ucep() external view returns (address) {
        return CANONICAL_UCEP;
    }

    /// @notice The canonical session validator every mandate on this wallet must name.
    function sessionValidator() external view returns (address) {
        return CANONICAL_SESSION_VALIDATOR;
    }

    /// @notice The Push-side gateway this wallet's agents send through.
    function universalGateway() external view returns (address) {
        return UNIVERSAL_GATEWAY_PC;
    }

    /// @dev Accepts PC with no logic; the wallet pays outbound gas swaps from its own balance and
    ///      refunds land here.
    receive() external payable { }

    /// @notice Accepts ERC-721 transfers, so destination-side refunds and NFTs can land.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Accepts ERC-1155 transfers, so destination-side refunds and NFTs can land.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @notice Accepts batched ERC-1155 transfers, so destination-side refunds and NFTs can land.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice ERC-165 support check.
     *
     * @dev    - Reports ERC-165 and the two token-receiver interfaces only.
     *         - Deliberately does not report `IERC7579Account`: this account implements that
     *           interface partially, so advertising it would mislead the tooling that probes for it.
     *           Tooling detects the account through `accountId`, `supportsModule` and
     *           `supportsExecutionMode` instead.
     *
     * @param  interfaceId  Interface id to query.
     * @return True for the three supported interfaces.
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId // 0x01ffc9a7
            || interfaceId == 0x150b7a02 // IERC721Receiver
            || interfaceId == 0x4e2312e0; // IERC1155Receiver
    }

    /**
     * @notice Always invalid: the wallet never signs as an ERC-1271 party.
     * @dev    A constant return, with no logic and no future hook. This is also what makes the
     *         engine's enable-mode grant path dead on these wallets.
     * @return The ERC-1271 failure magic value.
     */
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}
