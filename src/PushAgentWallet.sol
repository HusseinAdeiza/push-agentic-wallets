// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { Session, PermissionId } from "smartsessions/DataTypes.sol";

import { IERC7579Module, IERC7579Validator, IERC7579Hook } from "./interfaces/IERC7579Module.sol";
import { ISmartSessionMandate } from "./interfaces/ISmartSessionMandate.sol";
import {
    ModeLib,
    ModeCode,
    CallType,
    ExecType,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT
} from "./libraries/ModeLib.sol";
import { ExecutionLib, Execution } from "./libraries/ExecutionLib.sol";
import { PushWalletErrors } from "./libraries/PushWalletErrors.sol";

/**
 * @title  PushAgentWallet
 * @notice Per-user ERC-7579 modular smart account on Push Chain. Holds funds and is the
 *         `msg.sender` seen by `UniversalGatewayPC`, which therefore determines which CEA
 *         executes on the destination chain.
 *
 * @dev    Deployed as an EIP-1167 minimal clone by `AgentWalletFactory` (D-01).
 *         The owner is set once at `initialize` and never changes (D-02).
 *
 *         There is no ERC-4337 EntryPoint on Push Chain (C2), so the account is
 *         driven by `executeWithSession`, a native-AA entry point that unpacks
 *         ERC-4337 ValidationData itself.
 *
 * @dev    v2 / RULE 2 — ONE WALLET PER USER, FOR LIFE. A mandate is no longer a
 *         contract; it is a SmartSession *session* on this wallet, keyed by
 *         `PermissionId`. Mandates multiply inside the session set.
 *
 *         Isolation therefore changed species: v1's structural claim ("different
 *         mandates cannot touch each other because they are different contracts") is
 *         WITHDRAWN. The v2 guarantee is the Mandate Bound (§C.6) — a set of caps
 *         readable directly out of policy state, enforced by `ACPActionPolicy`,
 *         `TimeFramePolicy` and `ValueLimitPolicy`.
 *
 * @dev    This wallet is NOT a custodian. It is the user's own contract, owned
 *         permanently by their UEA. `execute` is `onlyOwner` with no policy attached —
 *         `ACPActionPolicy` runs only on the session path. Owner recovery is
 *         unconditional and survives every failure mode: no SmartSession installed, all
 *         sessions revoked, or a bricked module.
 */
contract PushAgentWallet is ReentrancyGuardTransient, IERC165, IERC721Receiver, IERC1155Receiver {
    // ==============================
    //          CONSTANTS
    // ==============================

    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    // intentionally unreferenced — declared for spec completeness, never installable
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2; // D-04
    // intentionally unreferenced — see above
    uint256 internal constant MODULE_TYPE_FALLBACK = 3; // D-07
    uint256 internal constant MODULE_TYPE_HOOK = 4;

    string internal constant ACCOUNT_ID = "push.agentwallet.1.0.0";

    bytes4 internal constant ERC1271_FAILED = 0xFFFFFFFF;

    /// @dev Domain tag mixed into opHash. Prevents collision with any other digest scheme.
    bytes32 internal constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v1");

    // ==============================
    //          IMMUTABLES
    // ==============================
    // Set in the implementation's constructor, so every clone shares them via the
    // EIP-1167 delegate. They are read by the grant-time guards, which is why they are
    // immutable rather than storage: a mutable policy address would let a future
    // owner-path write silently redefine what "safe session" means.

    /// @notice The only installable validator module in v2.0 (module type 1).
    address public immutable SMART_SESSION;
    /// @notice G3a — the ONLY permitted session action target (P-5, F-25).
    address public immutable UNIVERSAL_GATEWAY_PC;
    /// @notice G3b — mandatory on the gateway action; enforces R1–R15.
    address public immutable ACP_ACTION_POLICY;
    /// @notice A-11 — mandatory in userOpPolicies; enforces a real expiry.
    address public immutable TIMEFRAME_POLICY;
    /// @notice G3b — mandatory on the gateway action; the mandate's lifetime gas budget.
    address public immutable VALUE_LIMIT_POLICY;

    // ==============================
    //           STORAGE
    // ==============================
    // MUST NOT be reordered in any future version (PRD §5.4).

    // slot 0
    address public owner; // immutable in behaviour; set once at initialize()
    bool internal _initialized; // packed with owner

    // slot 1
    address internal _hook; // single hook slot; address(0) = none

    // slot 2 — mapping base
    // ⚠ REVIEW REQUIRED — storage discipline. MUST be nested `type => address => bool`.
    // A flattened `address => bool` would let a validator be treated as an executor,
    // a privilege escalation named in the ERC-7579 security considerations.
    mapping(uint256 moduleTypeId => mapping(address module => bool installed)) internal _modules;

    // slot 3 — mapping base
    mapping(uint192 nonceKey => uint64 seq) internal _nonces;

    // slot 4 — v2 additions. Packs cleanly: 20-byte address + 1-byte bool.
    // Appended AFTER every v1 slot; slots 0–3 stay byte-identical.

    /// @notice Emergency address with exactly two powers: pause and revoke (F-06, P-8).
    ///         address(0) means no guardian, which makes every guardian function inert.
    address public guardian;
    /// @notice When true, the entire session path is blocked. Guardian sets, OWNER clears.
    bool public sessionsPaused;

    // ==============================
    //            EVENTS
    // ==============================

    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);
    event WalletInitialized(address indexed owner);
    event SessionExecuted(address indexed validator, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash);
    event EmergencyRevokeAll(address indexed caller);
    event PCSwept(address indexed to, uint256 amount);

    // ── v2 mandate lifecycle ──
    event MandateGranted(bytes32 indexed permissionId, bytes32 indexed mandateId);
    event MandateRevoked(bytes32 indexed permissionId);
    event MandateReconfigured(bytes32 indexed permissionId);
    event DanglingSessionsPurged(uint256 removed, uint256 remaining);

    // ── v2 guardian (F-06) ──
    event GuardianSet(address indexed previous, address indexed guardian);
    event SessionsPausedSet(bool paused, address indexed by);
    event GuardianRevokedAll(uint256 removed, uint256 remaining);

    // ==============================
    //          MODIFIERS
    // ==============================

    /**
     * @dev Only the owning UEA.
     *
     *      A `msg.sender == address(this)` branch was removed deliberately (D-3). It
     *      existed to permit "batched self-config", but that was never needed: a UEA
     *      multicall calls each target directly (`UEA_EVM: calls[i].to.call(...)`), so
     *      every entry arrives with `msg.sender == UEA`. The branch was unreachable
     *      anyway — `execute` and `installModule` are both `nonReentrant`.
     *
     *      Keeping a dead branch that appears to grant self-call authority is a hazard:
     *      a future maintainer could remove `nonReentrant` to "fix" it and reopen A-04.
     *
     *      SECURITY: `ACPActionPolicy` R7 (rejecting `to == account`) MUST be retained
     *      regardless. A-04 has three independent defences — SmartSession's own
     *      `InvalidSelfCall` check, our R7, and this modifier — and none of them may be
     *      removed as "redundant".
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert PushWalletErrors.Unauthorized();
        _;
    }

    /**
     * @dev Only the designated guardian (F-06, P-8).
     *
     *      `guardian == address(0)` means no guardian. Since `msg.sender` can never be
     *      address(0), every guardian function is inert until one is set — no separate
     *      "guardian configured" flag is needed.
     *
     *      The guardian may only ever REDUCE permissions: pause and revoke. It cannot
     *      spend, cannot grant, and cannot unpause. That asymmetry is the whole design
     *      (P-8, TWO-SPEED AUTHORITY) — it makes the guardian safe to hand to a
     *      watchtower or a hot key, because a compromised guardian is a liveness
     *      problem, never a solvency one.
     */
    modifier onlyGuardian() {
        if (msg.sender != guardian) revert PushWalletErrors.NotGuardian();
        _;
    }

    // ==============================
    //         CONSTRUCTOR
    // ==============================

    /**
     * @notice Pins the session engine, the gateway and the three mandatory policies into
     *         the implementation's code, shared by every clone.
     *
     * @dev    These are constructor immutables rather than storage because the grant-time
     *         guards compare against them. If they were storage, an owner-path write
     *         could redefine "safe session" after the fact and silently disarm G2/G3a/G3b.
     *
     * @dev    DEPLOYMENT ORDER (Step 15): SmartSession, TimeFramePolicy, ValueLimitPolicy
     *         and ACPActionPolicy must all exist BEFORE the wallet implementation, which
     *         must exist before the factory. This inverts v1's Core-then-Modules order.
     */
    constructor(
        address smartSession_,
        address universalGatewayPC_,
        address acpActionPolicy_,
        address timeFramePolicy_,
        address valueLimitPolicy_
    ) {
        if (
            smartSession_ == address(0) || universalGatewayPC_ == address(0) || acpActionPolicy_ == address(0)
                || timeFramePolicy_ == address(0) || valueLimitPolicy_ == address(0)
        ) revert PushWalletErrors.ZeroAddress();

        SMART_SESSION = smartSession_;
        UNIVERSAL_GATEWAY_PC = universalGatewayPC_;
        ACP_ACTION_POLICY = acpActionPolicy_;
        TIMEFRAME_POLICY = timeFramePolicy_;
        VALUE_LIMIT_POLICY = valueLimitPolicy_;
    }

    // ==============================
    //        INITIALIZATION
    // ==============================

    /// @notice Called exactly once by AgentWalletFactory immediately after cloning.
    /// @param  owner_    The UEA that owns this wallet. MUST be non-zero.
    /// @param  guardian_ Emergency pause/revoke address. MAY be address(0) for none.
    /// @dev    Unguarded by caller because the clone is deployed and initialized
    ///         atomically by the factory in the same transaction; the counterfactual
    ///         address does not exist until `cloneDeterministic` returns. The
    ///         `_initialized` flag is the sole protection.
    function initialize(address owner_, address guardian_) external {
        if (_initialized) revert PushWalletErrors.AlreadyInitialized();
        if (owner_ == address(0)) revert PushWalletErrors.ZeroAddress();
        _initialized = true;
        owner = owner_;
        guardian = guardian_; // address(0) permitted — no guardian
        emit WalletInitialized(owner_);
        emit GuardianSet(address(0), guardian_);
    }

    // ==============================
    //       ACCOUNT CONFIG
    // ==============================

    function accountId() external pure returns (string memory) {
        return ACCOUNT_ID;
    }

    function supportsModule(uint256 moduleTypeId) public pure returns (bool) {
        // Executors (2) and fallbacks (3) are intentionally unsupported — D-04, D-07.
        return moduleTypeId == MODULE_TYPE_VALIDATOR || moduleTypeId == MODULE_TYPE_HOOK;
    }

    function supportsExecutionMode(ModeCode mode) external pure returns (bool) {
        (CallType ct, ExecType et,,) = ModeLib.decode(mode);
        if (et != EXECTYPE_DEFAULT) return false; // D-06
        return ct == CALLTYPE_SINGLE || ct == CALLTYPE_BATCH; // D-05: no delegatecall, no static
    }

    // ==============================
    //        MODULE CONFIG
    // ==============================

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        external
        onlyOwner
        nonReentrant
    {
        if (!supportsModule(moduleTypeId)) revert PushWalletErrors.UnsupportedModuleType(moduleTypeId);
        if (module == address(0)) revert PushWalletErrors.ZeroAddress();
        if (_modules[moduleTypeId][module]) {
            revert PushWalletErrors.ModuleAlreadyInstalled(moduleTypeId, module);
        }

        // SECURITY: set state BEFORE the external call — onInstall may reenter.
        _modules[moduleTypeId][module] = true;

        // Only ONE hook may be active. Silently overwriting `_hook` would orphan the
        // previous hook: its `_modules[4][old]` entry would stay true, making it
        // permanently un-reinstallable and making isModuleInstalled lie. This is the
        // single-active-module hazard named in the ERC-7579 security considerations.
        // Require an explicit uninstall first.
        if (moduleTypeId == MODULE_TYPE_HOOK) {
            if (_hook != address(0)) revert PushWalletErrors.HookAlreadyInstalled(_hook);
            _hook = module;
        }

        IERC7579Module(module).onInstall(initData);

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @dev ⚠ REVIEW REQUIRED: `onUninstall` is called AFTER clearing state, so a
    ///      module that reverts in `onUninstall` still blocks removal. This is why
    ///      `emergencyRevokeAll` exists as the escape hatch.
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        onlyOwner
        nonReentrant
    {
        if (!_modules[moduleTypeId][module]) {
            revert PushWalletErrors.ModuleNotInstalled(moduleTypeId, module);
        }

        _modules[moduleTypeId][module] = false;
        if (moduleTypeId == MODULE_TYPE_HOOK && _hook == module) _hook = address(0);

        IERC7579Module(module).onUninstall(deInitData);

        emit ModuleUninstalled(moduleTypeId, module);
    }

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata) external view returns (bool) {
        return _modules[moduleTypeId][module];
    }

    // ==============================
    //          EXECUTION
    // ==============================

    function execute(ModeCode mode, bytes calldata executionCalldata) external payable onlyOwner nonReentrant {
        _execute(mode, executionCalldata);
    }

    /**
     * @notice Native account-abstraction entry point. Replaces EntryPoint.handleOps.
     * @dev    ⚠ REVIEW REQUIRED — the only entirely novel code in the system.
     *         Deliberately callable by ANY address. Authorization is the signature
     *         checked inside, not msg.sender. A relayer, the provider, or the owner
     *         may all submit (D-16).
     * @param validator         Installed type-1 validator (SmartSession)
     * @param mode              ERC-7579 execution mode
     * @param executionCalldata ERC-7579 execution calldata
     * @param signature         Session signature over opHash, in the validator's format
     * @param nonceKey          2D nonce key (D-10)
     * @param nonceSeq          Expected sequence for that key
     */
    function executeWithSession(
        address validator,
        ModeCode mode,
        bytes calldata executionCalldata,
        bytes calldata signature,
        uint192 nonceKey,
        uint64 nonceSeq
    ) external nonReentrant {
        // 0. A-16 — the guardian's reflex. Blocks EVERY mandate in one Push transaction,
        //    collapsing incident response from an origin-chain round trip (minutes) to
        //    seconds. Deliberately first: no nonce is consumed and no policy counter
        //    moves while paused, so a false alarm costs the user nothing (T-36).
        if (sessionsPaused) revert PushWalletErrors.SessionsArePaused();

        // 1. Validator must be installed as type 1.
        if (!_modules[MODULE_TYPE_VALIDATOR][validator]) {
            revert PushWalletErrors.ValidatorNotInstalled(validator);
        }

        // 2. Consume the nonce BEFORE validation. Non-replayable even on later revert
        //    because the whole tx reverts; sequence is strictly monotonic per key.
        uint64 expected = _nonces[nonceKey];
        if (nonceSeq != expected) {
            revert PushWalletErrors.InvalidNonce(nonceKey, expected, nonceSeq);
        }
        unchecked {
            _nonces[nonceKey] = expected + 1;
        }

        // 3. Compute the operation hash. EVERY field is bound.
        bytes32 opHash = _computeOpHash(validator, mode, executionCalldata, nonceKey, nonceSeq);

        // 4. Build a 4337-shaped struct in memory. No EntryPoint consumes it; it is
        //    purely the ABI shape the validator expects.
        PackedUserOperation memory op;
        op.sender = address(this);
        op.nonce = (uint256(nonceKey) << 64) | uint256(nonceSeq);
        op.callData = abi.encodeCall(this.execute, (mode, executionCalldata));
        op.signature = signature;
        // initCode, accountGasLimits, preVerificationGas, gasFees, paymasterAndData
        // remain zero/empty. SmartSession's paymaster check MUST pass on empty data.

        // 5. Validate.
        uint256 validationData = IERC7579Validator(validator).validateUserOp(op, opHash);

        // 6. Unpack ValidationData ourselves — the job an EntryPoint would do.
        _requireValidationData(validator, validationData);

        emit SessionExecuted(validator, nonceKey, nonceSeq, opHash);

        // 7. Execute.
        _execute(mode, executionCalldata);
    }

    /// @notice Current expected sequence number for a 2D nonce key.
    function nonce(uint192 nonceKey) external view returns (uint64) {
        return _nonces[nonceKey];
    }

    // ==============================
    //      OWNER EMERGENCY OPS
    // ==============================

    /// @notice Nuclear option. Uninstalls validators WITHOUT calling onUninstall,
    ///         so a malicious or buggy module cannot block its own removal.
    /// @dev    Owner only. Does not touch funds.
    function emergencyRevokeAll(address[] calldata validators) external onlyOwner {
        uint256 len = validators.length;
        for (uint256 i; i < len;) {
            _modules[MODULE_TYPE_VALIDATOR][validators[i]] = false;
            emit ModuleUninstalled(MODULE_TYPE_VALIDATOR, validators[i]);
            unchecked {
                ++i;
            }
        }
        // Clear the active hook's MAPPING entry too, not just the slot. Because
        // installModule rejects a second hook, `_hook` is provably the only address
        // with _modules[4][.] == true, so this is complete (invariant N-02).
        address h = _hook;
        if (h != address(0)) {
            _modules[MODULE_TYPE_HOOK][h] = false;
            emit ModuleUninstalled(MODULE_TYPE_HOOK, h);
            _hook = address(0);
        }

        emit EmergencyRevokeAll(msg.sender);
    }

    /// @notice Return unspent native PC to a destination. Owner only.
    function sweepPC(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert PushWalletErrors.ZeroAddress();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert PushWalletErrors.NativeTransferFailed();
        emit PCSwept(to, amount);
    }

    // ==============================
    //     MANDATE LIFECYCLE (owner)
    // ==============================

    /**
     * @notice Grant one mandate as a SmartSession session. Tier 0 — fully guarded.
     * @param  session The session template. MUST match §C.5: TimeFramePolicy with a real
     *                 expiry in `userOpPolicies`, and exactly ONE action targeting the
     *                 gateway carrying BOTH ACPActionPolicy and ValueLimitPolicy.
     * @return pid     The PermissionId this mandate is keyed by.
     *
     * @dev A-04 — THE DEFECT THIS CLOSES. Upstream `enableSessions` does NOT reject a
     *      duplicate PermissionId: `$enabledSessions.add` is idempotent and
     *      `ConfigLib.enable` calls `initializeWithMultiplexer` per policy, whose own
     *      doc says "overwrites the config". So re-granting the same
     *      (validator, key, salt) would silently reset ACP `spent` to zero and replace
     *      every cap — a mandate laundering vector. We reject it and route the
     *      legitimate case through `reconfigureMandate`, which is loud.
     *
     * @dev F-17 — requires SmartSession installed. Sessions enabled before install
     *      recreate the `onInstall` brick through the front door: `onInstall` reverts
     *      `SmartSessionModuleAlreadyInstalled` when `$enabledSessions` is non-empty.
     */
    function grantMandate(Session calldata session) external onlyOwner nonReentrant returns (bytes32 pid) {
        if (session.salt == bytes32(0)) revert PushWalletErrors.InvalidMandateId();
        if (!_modules[MODULE_TYPE_VALIDATOR][SMART_SESSION]) revert PushWalletErrors.SessionModuleNotInstalled();

        _requireBoundedSession(session); // A-11 — TimeFrame present and actually expiring
        _requireSafeActions(session); // A-14 — G1, G2, G3a, G3b

        pid = _permissionId(session);
        if (ISmartSessionMandate(SMART_SESSION).isPermissionEnabled(PermissionId.wrap(pid), address(this))) {
            revert PushWalletErrors.MandateAlreadyExists(pid);
        }

        Session[] memory arr = new Session[](1);
        arr[0] = session;
        PermissionId[] memory got = ISmartSessionMandate(SMART_SESSION).enableSessions(arr);

        // Mirror-validity gate (T-10): our `_permissionId` must track IdLib.toPermissionId
        // exactly. If upstream ever changes the derivation, every guard above would be
        // checking a different session than the one enabled. Fail loudly instead.
        if (PermissionId.unwrap(got[0]) != pid) revert PushWalletErrors.MandateNotFound(pid);

        emit MandateGranted(pid, session.salt);
    }

    /**
     * @notice Kill exactly one mandate. Tier 1 — surgical revocation.
     *
     * @dev Deliberately does NOT route through `callValidator`: that requires the module
     *      to be installed, which is false immediately after `emergencyRevokeAll` —
     *      exactly when revocation and purge must still work. `removeSession` is public,
     *      has NO install check (`SmartSessionBase.sol:329`) and is fully
     *      `msg.sender`-scoped, so calling it directly is correct and safe.
     *
     * @dev Q15 — the pinned `removeSession` succeeds SILENTLY on unknown non-zero pids
     *      (it only guards EMPTY_PERMISSIONID; every `removeAll` is a no-op). Without the
     *      existence check below, a typo'd pid would emit `MandateRevoked` for a mandate
     *      that never existed — during an incident the operator reads "revoked ✓" while
     *      the real mandate stays live. Post-`emergencyRevokeAll`, dangling sessions still
     *      report `isPermissionEnabled == true`, so revoking them here still works.
     */
    function revokeMandate(bytes32 pid) external onlyOwner nonReentrant {
        if (!ISmartSessionMandate(SMART_SESSION).isPermissionEnabled(PermissionId.wrap(pid), address(this))) {
            revert PushWalletErrors.MandateNotFound(pid);
        }
        ISmartSessionMandate(SMART_SESSION).removeSession(PermissionId.wrap(pid));
        emit MandateRevoked(pid);
    }

    /**
     * @notice Deliberate update of an existing mandate — the legitimate duplicate case.
     *
     * @dev RESETS ACP `spent` and ValueLimitPolicy `limitUsed` by design (F-16). This is
     *      the explicit, owner-authorised, loudly-evented form of the overwrite that
     *      `grantMandate` exists to prevent happening silently.
     *
     * @dev Q3 — WHY THE INSTALL CHECK HERE (asymmetric vs revokeMandate, deliberately):
     *      the rule is "anything that ENABLES a session requires the module installed;
     *      anything that only REMOVES does not." Reconfigure enables. In the
     *      never-installed state it would recreate the grant-before-install brick (F-17);
     *      in the post-`emergencyRevokeAll` state it would refresh config on a dangling
     *      session that cannot execute, undermining the deliberate
     *      purge → install → grant recovery sequence.
     *      grantMandate ✓ · reconfigureMandate ✓ · revokeMandate ✗ ·
     *      purgeDanglingSessions ✗ · guardianRevoke* ✗
     */
    function reconfigureMandate(Session calldata session) external onlyOwner nonReentrant returns (bytes32 pid) {
        if (session.salt == bytes32(0)) revert PushWalletErrors.InvalidMandateId();
        if (!_modules[MODULE_TYPE_VALIDATOR][SMART_SESSION]) revert PushWalletErrors.SessionModuleNotInstalled();

        _requireBoundedSession(session);
        _requireSafeActions(session);

        pid = _permissionId(session);
        if (!ISmartSessionMandate(SMART_SESSION).isPermissionEnabled(PermissionId.wrap(pid), address(this))) {
            revert PushWalletErrors.MandateNotFound(pid);
        }

        // Remove first: `ConfigLib.enable` ADDS to policyList without clearing it, so
        // enabling over a live session would accumulate policies. removeSession's
        // removeAll gives us a clean slate.
        ISmartSessionMandate(SMART_SESSION).removeSession(PermissionId.wrap(pid));

        Session[] memory arr = new Session[](1);
        arr[0] = session;
        ISmartSessionMandate(SMART_SESSION).enableSessions(arr);

        emit MandateReconfigured(pid);
    }

    /**
     * @notice Tier 3 — recovery from the `onInstall` brick. A-05.
     * @param  maxIterations Chunk size. Repeat until the emitted `remaining` is zero.
     *
     * @dev THE PROOF THE WALLET IS NOT PERMANENTLY BRICKABLE. `emergencyRevokeAll` skips
     *      module callbacks (deliberately — a hostile module must not be able to resist
     *      removal), which leaves SmartSession's `$enabledSessions` populated. `onInstall`
     *      then reverts `SmartSessionModuleAlreadyInstalled` forever. Looping
     *      `removeSession` properly clears that set, after which `installModule` works
     *      again. Runbook S-6: emergencyRevokeAll → purge until remaining == 0 →
     *      installModule → re-grant.
     *
     * @dev Q16 — `remaining` is computed from the snapshot (`total - n`), which is exact:
     *      `getPermissionIDs` returns a memory copy and every removal in the loop
     *      succeeds. Re-reading the live length would cost an extra external call to
     *      report the same number.
     */
    function purgeDanglingSessions(uint256 maxIterations) external onlyOwner nonReentrant {
        PermissionId[] memory pids = ISmartSessionMandate(SMART_SESSION).getPermissionIDs(address(this));
        uint256 total = pids.length;
        uint256 n = total < maxIterations ? total : maxIterations;
        for (uint256 i; i < n;) {
            ISmartSessionMandate(SMART_SESSION).removeSession(pids[i]);
            unchecked {
                ++i;
            }
        }
        emit DanglingSessionsPurged(n, total - n);
    }

    // ==============================
    //           GUARDIAN
    // ==============================

    /// @notice Owner may rotate freely.
    /// @dev    The guardian is NOT in the CREATE2 salt, so rotation does not violate
    ///         D-02 — the wallet address stays derived from `owner` alone, and the CEA
    ///         on every external chain is unaffected.
    function setGuardian(address g) external onlyOwner {
        emit GuardianSet(guardian, g);
        guardian = g;
    }

    /**
     * @notice REFLEX (A-16). Blocks the session path globally, in one Push transaction.
     *
     * @dev Reversible WITHOUT re-granting — which is precisely why it exists alongside
     *      revoke. Revoking and then re-granting runs `initializeWithMultiplexer`, which
     *      RESETS ACP `spent` and ValueLimitPolicy `limitUsed` to zero. A false alarm
     *      must not silently re-arm a mandate's caps (T-36).
     */
    function guardianPause() external onlyGuardian {
        sessionsPaused = true;
        emit SessionsPausedSet(true, msg.sender);
    }

    /// @notice Only the OWNER may unpause. The guardian can reduce permissions, never
    ///         restore them (P-8). A compromised guardian is therefore a liveness
    ///         problem, never a solvency one.
    function unpauseSessions() external onlyOwner {
        sessionsPaused = false;
        emit SessionsPausedSet(false, msg.sender);
    }

    /// @notice DECISION. Kills exactly one mandate.
    /// @dev    Q15 — same existence check as `revokeMandate`: a typo'd pid during an
    ///         incident must revert loudly, not emit a phantom `MandateRevoked`.
    function guardianRevoke(bytes32 pid) external onlyGuardian nonReentrant {
        if (!ISmartSessionMandate(SMART_SESSION).isPermissionEnabled(PermissionId.wrap(pid), address(this))) {
            revert PushWalletErrors.MandateNotFound(pid);
        }
        ISmartSessionMandate(SMART_SESSION).removeSession(PermissionId.wrap(pid));
        emit MandateRevoked(pid);
    }

    /**
     * @notice Kills all mandates WITHOUT bricking the wallet.
     *
     * @dev Contrast `emergencyRevokeAll`, which skips callbacks and DOES brick. That one
     *      stays owner-only: a guardian able to brick but not to purge
     *      (`purgeDanglingSessions` is `onlyOwner`) would be a far nastier griefing
     *      vector than anything it defends against. Looping `removeSession` properly
     *      clears `$enabledSessions`, so `installModule` still works afterwards (T-38).
     *
     * @dev Q4 — emits per-pid `MandateRevoked` for indexer parity plus a completeness
     *      signal, because the guardian must be able to tell whether `maxIterations`
     *      covered everything. `remaining` uses the snapshot for the same reason as
     *      `purgeDanglingSessions`.
     */
    function guardianRevokeAll(uint256 maxIterations) external onlyGuardian nonReentrant {
        PermissionId[] memory pids = ISmartSessionMandate(SMART_SESSION).getPermissionIDs(address(this));
        uint256 total = pids.length;
        uint256 n = total < maxIterations ? total : maxIterations;
        for (uint256 i; i < n;) {
            ISmartSessionMandate(SMART_SESSION).removeSession(pids[i]);
            emit MandateRevoked(PermissionId.unwrap(pids[i]));
            unchecked {
                ++i;
            }
        }
        emit GuardianRevokedAll(n, total - n);
    }

    /// @notice Owner-gated passthrough so SmartSession sees msg.sender == address(this).
    /// @dev    `data` MUST be an ABI-encoded call to SmartSession (e.g. enableSessions).
    ///         ⚠ REVIEW REQUIRED: the installed-validator check is what stops this
    ///         being an arbitrary-call escape hatch. It MUST NOT be relaxed.
    ///
    /// @dev    ⚠ IT BYPASSES EVERY `grantMandate` GUARD (Q1, Q12). An `enableSessions`
    ///         through here on an already-enabled pid is ADDITIVE on `policyList`
    ///         (`ConfigLib.enable` adds without clearing) and overwrites policy configs —
    ///         the exact silent merge `grantMandate` exists to prevent. This is
    ///         acceptable only because the owner already holds unlimited power over this
    ///         wallet, so it grants no new authority. It is session-unreachable: G2 blocks
    ///         SmartSession as an action target and ACP R2 pins session calls to the
    ///         gateway.
    ///
    ///         `grantMandate` / `reconfigureMandate` are the ONLY supported production
    ///         grant paths (S-14). CV-1 in ACPActionPolicy still fires here, so an
    ///         unpinned-approval config cannot be built through this path either.
    function callValidator(address smartSession, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory)
    {
        if (!_modules[MODULE_TYPE_VALIDATOR][smartSession]) {
            revert PushWalletErrors.ValidatorNotInstalled(smartSession);
        }
        (bool ok, bytes memory ret) = smartSession.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    // ==============================
    //     INTERNALS — GRANT GUARDS
    // ==============================

    /// @dev Must track `IdLib.toPermissionId` exactly — see the mirror-validity gate in
    ///      `grantMandate` and the fuzz test T-63.
    function _permissionId(Session calldata s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s.sessionValidator, s.sessionValidatorInitData, s.salt));
    }

    /**
     * @dev A-11. TimeFramePolicy must be present in `userOpPolicies` AND must actually
     *      expire.
     *
     *      `validUntil == 0` means NO EXPIRY in TimeFramePolicy — `_checkTimeFrame` only
     *      requires `validUntil != 0 || validAfter != 0`. Under Rule 2 that is a permanent
     *      unrevoked key on the user's ONLY wallet, so the convention has to become a
     *      guarantee (P-7).
     *
     *      ENCODING (verified, §0.4): initData is exactly
     *      `abi.encodePacked(uint48 validUntil, uint48 validAfter)` — 12 bytes. The policy
     *      reads `uint96(bytes12(initData[0:12]))` and takes `validUntil` as
     *      `unwrap >> 48`, i.e. the HIGH 6 bytes == `initData[0:6]`. T-16b pins our decode
     *      against the policy's own getter so a future pin cannot make this vacuous.
     */
    function _requireBoundedSession(Session calldata s) internal view {
        bool hasTime;
        uint256 len = s.userOpPolicies.length;
        for (uint256 i; i < len;) {
            if (s.userOpPolicies[i].policy == TIMEFRAME_POLICY) {
                bytes calldata d = s.userOpPolicies[i].initData;
                if (d.length < 12) revert PushWalletErrors.MalformedPolicyInitData();
                if (uint48(bytes6(d[0:6])) == 0) revert PushWalletErrors.NonExpiringSessionForbidden();
                hasTime = true;
            }
            unchecked {
                ++i;
            }
        }
        if (!hasTime) revert PushWalletErrors.MissingTimeFramePolicy();
    }

    /**
     * @dev A-14 + the PC term of the Mandate Bound. Closes W-1, W-2 and W-3 (§C.7).
     *
     *      Why this has to exist at all: SmartSession's action-policy floor is
     *      `minPolicies = 1`, satisfied by ANY single policy. So a session registered
     *      with only `TimeFramePolicy` on the gateway action would sail through upstream
     *      while `ACPActionPolicy` — every one of R1–R15 — never runs.
     */
    function _requireSafeActions(Session calldata s) internal view {
        // Q8 — exactly ONE action. Duplicate (target, selector) entries collapse to one
        // actionId and therefore one ConfigId, and ConfigLib calls
        // initializeWithMultiplexer per entry ("overwrites the config", upstream's own
        // words). A tight ACP entry followed by a loose one means the loose one silently
        // wins by array position. G3a already pins the only legal target, so exactly one
        // action is the only legal shape — forbid the ambiguity outright.
        uint256 len = s.actions.length;
        if (len != 1) revert PushWalletErrors.ExactlyOneActionRequired(len);

        for (uint256 i; i < len;) {
            address t = s.actions[i].actionTarget;

            // G1 (W-1) — blocks BOTH fallback ActionIds. They are configured with
            // actionTarget == FALLBACK_TARGET_FLAG (address(1)), differing only in the
            // selector flag. A fallback action's policies apply to EVERY unregistered
            // (target, selector); with SudoPolicy attached — and SudoPolicy is in the
            // adopted set — the session could call anything, and ACP never runs.
            if (t == address(1)) revert PushWalletErrors.FallbackActionForbidden();

            // G2 (W-2) — a session may never target the session engine. SmartSession maps
            // target == address(SmartSession) to FALLBACK_ACTIONID_SMARTSESSION_CALL
            // (PolicyLib.sol:210), which would expose enableSessions (self-grant) and
            // removeSession (kill the user's other mandates) to the session key.
            if (t == SMART_SESSION) revert PushWalletErrors.SmartSessionActionForbidden();

            // G3a (W-3) — v2.0 scope lock (P-5, F-25): the gateway is the ONLY permitted
            // session target. The standing PRC20 approval is an owner-path action, and
            // exits are owner-path. NOTE: the wallet is an immutable clone, so admitting a
            // second session action type later requires a new implementation AND factory.
            if (t != UNIVERSAL_GATEWAY_PC) revert PushWalletErrors.ActionTargetNotGateway(t);

            // G3b — ACP and ValueLimitPolicy must BOTH be attached. Policies INTERSECT
            // upstream (PolicyLib.sol:75), so adding a permissive policy cannot weaken
            // ACP; the hazards are substitution and omission, which is what this catches.
            bool hasACP;
            bool hasValueLimit;
            uint256 plen = s.actions[i].actionPolicies.length;
            for (uint256 j; j < plen;) {
                address p = s.actions[i].actionPolicies[j].policy;
                if (p == ACP_ACTION_POLICY) {
                    hasACP = true;
                } else if (p == VALUE_LIMIT_POLICY) {
                    bytes calldata vd = s.actions[i].actionPolicies[j].initData;
                    // ValueLimitPolicy reads uint256(bytes32(initData[0:32])) and reverts
                    // on zero itself — but from three calls deep inside SmartSession, as an
                    // opaque PolicyNotInitialized. Q9: reject it here with a clean
                    // grant-time error, the same treatment TimeFrame's validUntil gets.
                    if (vd.length < 32) revert PushWalletErrors.MalformedPolicyInitData();
                    if (uint256(bytes32(vd[0:32])) == 0) revert PushWalletErrors.ZeroValueLimit();
                    hasValueLimit = true;
                }
                unchecked {
                    ++j;
                }
            }
            if (!hasACP) revert PushWalletErrors.GatewayActionMissingACP();
            if (!hasValueLimit) revert PushWalletErrors.MissingValueLimitPolicy();

            unchecked {
                ++i;
            }
        }
    }

    // ==============================
    //          INTERNALS
    // ==============================

    /// @dev ⚠ REVIEW REQUIRED. Every omitted field is a replay class.
    function _computeOpHash(
        address validator,
        ModeCode mode,
        bytes calldata executionCalldata,
        uint192 nonceKey,
        uint64 nonceSeq
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                OP_HASH_DOMAIN, // scheme separation
                block.chainid, // cross-chain replay
                address(this), // cross-account replay
                validator, // validator substitution
                ModeCode.unwrap(mode), // single→batch substitution
                keccak256(executionCalldata), // payload integrity
                nonceKey, // 2D nonce
                nonceSeq
            )
        );
    }

    /**
     * @dev ⚠ REVIEW REQUIRED. The `validUntil == 0` case is a classic bug.
     *
     *      ValidationData packing (ERC-4337 v0.7):
     *        bits [0:160]   authorizer  — 0 = success, 1 = SIG_VALIDATION_FAILED, else aggregator
     *        bits [160:208] validUntil  — 0 means NO EXPIRY (not "expired at epoch 0")
     *        bits [208:256] validAfter
     *
     *      An authorizer other than 0 — including an aggregator address — MUST revert.
     *      We do not support aggregators.
     */
    function _requireValidationData(address validator, uint256 validationData) internal view {
        // Truncation is the specified unpacking: each field's width is defined by
        // the ERC-4337 ValidationData layout documented above.
        // forge-lint: disable-next-line(unsafe-typecast)
        address authorizer = address(uint160(validationData));
        if (authorizer != address(0)) {
            revert PushWalletErrors.SignatureValidationFailed(validator, validationData);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 validUntil = uint48(validationData >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 validAfter = uint48(validationData >> 208);

        // Session validity windows are minute-to-hour scale; a validator's few-second
        // timestamp latitude cannot meaningfully extend or shorten them.
        // forge-lint: disable-next-line(block-timestamp)
        if (validAfter != 0 && block.timestamp < validAfter) {
            revert PushWalletErrors.OperationNotYetValid(validAfter);
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (validUntil != 0 && block.timestamp > validUntil) {
            revert PushWalletErrors.OperationExpired(validUntil);
        }
    }

    function _execute(ModeCode mode, bytes calldata executionCalldata) internal {
        (CallType ct, ExecType et,,) = ModeLib.decode(mode);

        if (et != EXECTYPE_DEFAULT) revert PushWalletErrors.UnsupportedExecType(et);

        bytes memory hookData = _preHook(msg.sender, msg.value, executionCalldata);

        if (ct == CALLTYPE_SINGLE) {
            (address target, uint256 value, bytes calldata cd) = ExecutionLib.decodeSingle(executionCalldata);
            _call(target, value, cd);
        } else if (ct == CALLTYPE_BATCH) {
            Execution[] calldata execs = ExecutionLib.decodeBatch(executionCalldata);
            uint256 len = execs.length;
            // Reject an empty batch so "executed nothing" can never look like success.
            if (len == 0) revert PushWalletErrors.EmptyBatch();
            for (uint256 i; i < len;) {
                _call(execs[i].target, execs[i].value, execs[i].callData);
                unchecked {
                    ++i;
                }
            }
        } else if (ct == CALLTYPE_DELEGATECALL) {
            revert PushWalletErrors.DelegatecallNotSupported();
        } else {
            revert PushWalletErrors.UnsupportedCallType(ct);
        }

        _postHook(hookData);
    }

    function _call(address target, uint256 value, bytes calldata cd) internal {
        (bool ok, bytes memory ret) = target.call{ value: value }(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            } // bubble the original revert
        }
    }

    /// @dev NOTE: `executeWithSession` is not payable, so `value` is STRUCTURALLY ZERO
    ///      on the session path — the wallet spends its own PC balance through the
    ///      execution `value` field instead (D-15). A future hook doing native-value
    ///      accounting must not assume this reflects value actually moved.
    function _preHook(address sender, uint256 value, bytes calldata data) internal returns (bytes memory) {
        address h = _hook;
        if (h == address(0)) return "";
        return IERC7579Hook(h).preCheck(sender, value, data);
    }

    function _postHook(bytes memory hookData) internal {
        address h = _hook;
        if (h != address(0)) IERC7579Hook(h).postCheck(hookData);
    }

    // ==============================
    //     RECEIVERS / ERC-165
    // ==============================

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    /// @dev Reports only ERC-165 and the token-receiver interfaces. ERC-7579 defines
    ///      NO single account interfaceId — the spec splits the surface across several
    ///      interfaces and prescribes discovery via `accountId()`, which returns
    ///      "push.agentwallet.1.0.0". `IERC7579Account` in src/interfaces is a
    ///      deliberate local subset (no `executeFromExecutor`, D-04) and MUST NOT be
    ///      advertised as conformance we do not have.
    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return iid == type(IERC165).interfaceId || iid == type(IERC721Receiver).interfaceId
            || iid == type(IERC1155Receiver).interfaceId;
    }

    /// @dev D-09 — ERC-1271 is not supported in v1.
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return ERC1271_FAILED;
    }

    receive() external payable { }
}
