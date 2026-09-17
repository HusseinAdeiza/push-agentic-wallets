// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IURP, MAX_PINS } from "../interfaces/IURP.sol";
import { IPRC20Source } from "../interfaces/IPRC20Source.sol";
import { PushChainLib } from "../libraries/PushChainLib.sol";
import {
    UniversalOutboundTxRequest,
    Multicall,
    MandateType,
    MULTICALL_SELECTOR,
    VALUE_SELECTOR,
    SEND_OUTBOUND_SELECTOR as GATEWAY_SEND_OUTBOUND_SELECTOR
} from "../libraries/PushWalletTypes.sol";

/**
 * @title  URP — Universal Rules Policy
 * @notice The security boundary of the whole system: the only contract that ever inspects what an
 *         agent really does on the far chain. Everything else routes, stores, or signs.
 *
 * @dev    - The engine identifies actions by hashing the Push-side target and selector, and every
 *           agent action is the same Push-side call, so to the engine a trade, a deposit and a theft
 *           are identical. What the user actually authorised lives two decode levels down, inside
 *           the payload. This policy opens it.
 *         - It is the fail-closed anchor: the engine requires at least one action policy per action
 *           (`PolicyLib.check`), so removing this one does not weaken a mandate, it kills every
 *           request under it.
 *         - No owner, no setters, no pause. Its three trust anchors are written once, at
 *           initialisation, and there is no function that can change them afterwards.
 *         - It never makes an external call, and writes only after every gate has passed.
 *
 *         UPGRADEABLE, BEHIND A TRANSPARENT PROXY, AND THAT IS A DELIBERATE TRADE. This contract
 *         used to hold its trust anchors in immutables and describe itself as needing no trust at
 *         all. Immutables live in the implementation's bytecode, which a `delegatecall` never
 *         executes the constructor of, so upgradeability and immutables are mutually exclusive —
 *         they had to become storage. The consequence is worth stating plainly rather than
 *         discovering later: **URP's guarantees now hold subject to the proxy admin not being
 *         malicious.** An admin able to install new logic can rewrite every gate in this file.
 *
 *         What that means in practice, and what it does NOT mean:
 *         - No function here can move `SESSION_ENGINE`, the gateway or the executor module. The
 *           only route to changing them is a full implementation swap by the admin.
 *         - The admin cannot reach `$configs` or `$credited` directly; it can only replace the code
 *           that reads them. Existing mandates keep their caps until an upgrade says otherwise.
 *         - Storage layout is therefore load-bearing FOREVER. See the layout note on `__gap`.
 *
 *         THE IMPLEMENTATION MUST NEVER BE INITIALISED DIRECTLY. Its constructor disables the
 *         initialiser for exactly that reason; an initialised implementation is a contract with a
 *         live config that the proxy does not know about.
 */
contract URP is IURP, Initializable {
    /// @dev Maximum inner calls in one request. Bounds the gate-13 loop.
    uint256 internal constant MAX_ACTIONS_PER_REQUEST = 10;

    /// @dev Maximum allow-list entries per config. Bounds the allow-list scan.
    uint256 internal constant MAX_ALLOWED_CALLS = 32;

    /// @notice The gateway selector every agent action must carry.
    /// @dev    Part of this contract's ABI, so it stays a public constant. The value comes from the
    ///         shared gateway constant, so this policy and the wallet's grant-shape check cannot
    ///         disagree.
    bytes4 public constant SEND_OUTBOUND_SELECTOR = GATEWAY_SEND_OUTBOUND_SELECTOR;

    /// @dev Smallest valid ABI encoding of a UniversalOutboundTxRequest argument list:
    ///      32 (outer offset) + 256 (eight head words) + 32 + 32 (length words for the two empty
    ///      bytes fields). Do not hand-maintain: a test pins this against abi.encode of an empty
    ///      request, so a new struct field fails the build rather than loosening gate 4c.
    uint256 internal constant MIN_OUTBOUND_BODY_LEN = 352;

    // ───────────────────────────────── storage ─────────────────────────────────
    //
    // THE LAYOUT BELOW IS FROZEN. Behind a proxy, storage belongs to the proxy and outlives every
    // implementation, so a new version may only APPEND — never reorder, never remove, never change
    // a type. Doing so does not fail the build: it silently reinterprets live mandates, which is
    // the worst failure mode this system has.
    //
    // slot 0  UNIVERSAL_GATEWAY_PC
    // slot 1  UNIVERSAL_EXECUTOR_MODULE
    // slot 2  SESSION_ENGINE
    // slot 3  $configs
    // slot 4  $credited
    // slot 5  $mode      APPENDED 2026-09-09 (native mode)
    // slot 6  $native    APPENDED 2026-09-09 (native mode)
    // slots 7..49  __gap (uint256[43])
    //
    // THE 2026-09-09 APPEND, AND WHY IT IS SAFE. `$mode` and `$native` were added AFTER `$credited`
    // and `__gap` was shrunk 45 -> 43 in the same commit, so slots 0-4 are byte-identical to the
    // deployed layout and `__gap` still ends at slot 49. Nothing that holds data moved. The
    // alternative that was rejected — renaming `$configs` to `$universal` and inserting `$native`
    // beside it — would have shifted `$credited` and silently reinterpreted the live idempotency
    // set. Measured with `forge inspect` before the change, not assumed.
    //
    // `Initializable` adds nothing here: OZ 5.x keeps its initialisation flags in an ERC-7201
    // namespaced slot, not slot 0. A test pins this exact layout against solc's own output.

    /// @notice The one Push-side target any agent action may reach.
    /// @dev    Written once by `initialize`. No setter exists, here or anywhere.
    address public UNIVERSAL_GATEWAY_PC;

    /// @notice The sole caller permitted to credit a failed outbound.
    /// @dev    Address unconfirmed against a live deployment; confirm before mainnet. It is an
    ///         initialiser argument, so nothing about building or testing depends on the real one.
    address public UNIVERSAL_EXECUTOR_MODULE;

    /// @notice The multiplexer this contract trusts on every non-engine-driven path.
    /// @dev    Never accepted as a call argument: a wrong value would silently address an empty
    ///         slice. It is set once at initialisation and read from storage thereafter.
    address public SESSION_ENGINE;

    /// @dev configId => multiplexer (the engine) => account (the wallet) => config.
    /// @dev The configId already binds the account and the permission, so the middle level isolates
    ///      callers, not permissions.
    /// @dev On the two engine-driven entry points the multiplexer is msg.sender; every other
    ///      function keys on SESSION_ENGINE.
    mapping(ConfigId => mapping(address => mapping(address => Config))) internal $configs;

    /// @dev outbound tx id => credited already; idempotency for the refund path.
    mapping(bytes32 => bool) internal $credited;

    /// @dev configId => multiplexer => account => which rulebook this config uses.
    /// @dev THE MODE DISCRIMINATOR. Stored rather than derived from `$native[...].initialized`,
    ///      because a one-bit derived mode cannot grow: URP is upgradeable behind a proxy, and the
    ///      register's extensibility item points at MORE MODES. `ModeSlot.initialized` is
    ///      authoritative for emptiness; `mode` is meaningless when it is false.
    mapping(ConfigId => mapping(address => mapping(address => ModeSlot))) internal $mode;

    /// @dev configId => multiplexer => account => the native rulebook.
    /// @dev One entry per ACTION, not per mandate: a native mandate with eight actions writes eight
    ///      of these under eight distinct config ids.
    mapping(ConfigId => mapping(address => mapping(address => NativeConfig))) internal $native;

    /**
     * @dev Reserved so a later version can add state without shifting anything above.
     *
     *      Adding a variable means DECREMENTING this by exactly the number of slots consumed, in
     *      the same commit. A mapping or dynamic array costs one slot; a struct costs its packed
     *      size. `Config` itself lives inside a mapping, so APPENDING a field to that struct is
     *      safe and costs nothing here — reordering or removing one is not.
     *
     *      Was `uint256[45]` before the 2026-09-09 native-mode append; `$mode` and `$native` took
     *      two slots, so it is 43. `__gap` still ends at slot 49.
     */
    uint256[43] private __gap;

    /**
     * @notice Locks the implementation so it can never be initialised in its own context.
     *
     * @dev    An implementation left initialisable is a live contract holding a config the proxy
     *         has no knowledge of. This is the standard guard and it is not optional.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Pins the three addresses this policy trusts for its whole lifetime.
     *
     * @dev    Runs once, in the PROXY's context, immediately after deployment. Reverts with
     *         `ZeroAddress` if any argument is zero, and with `InvalidInitialization` on any
     *         second call.
     *
     *         Deploy and initialise atomically — pass this call as the TransparentUpgradeableProxy
     *         constructor's `_data`. A proxy deployed uninitialised is front-runnable: whoever
     *         calls `initialize` first chooses the engine this policy trusts.
     *
     * @param  universalGatewayPC        The one Push-side target agent actions may reach.
     * @param  universalExecutorModule   The only caller permitted to credit a failed outbound.
     * @param  sessionEngine             The multiplexer trusted on non-engine-driven paths.
     */
    function initialize(address universalGatewayPC, address universalExecutorModule, address sessionEngine)
        external
        initializer
    {
        if (universalGatewayPC == address(0)) revert ZeroAddress();
        if (universalExecutorModule == address(0)) revert ZeroAddress();
        if (sessionEngine == address(0)) revert ZeroAddress();

        UNIVERSAL_GATEWAY_PC = universalGatewayPC;
        UNIVERSAL_EXECUTOR_MODULE = universalExecutorModule;
        SESSION_ENGINE = sessionEngine;
    }

    /**
     * @dev The EFFECTIVE mode of a config — legacy-aware. A config written before native mode existed
     *      has an empty `$mode` slot but an initialised `$configs` entry, and it IS a universal
     *      config. Every mode-sensitive entry point that is not `checkAction` reads through this, so a
     *      pre-upgrade mandate is protected against re-initialisation and reported correctly by the
     *      getters, with no migration. `checkAction` keeps its direct routing: an empty `$mode` slot
     *      already falls through to `_checkUniversal`, which is the same answer one SLOAD cheaper.
     *
     * @return initialized  true if either rulebook has been written for this config
     * @return mode         the rulebook; meaningless when `initialized` is false
     */
    function _modeOf(ConfigId id, address mux, address account)
        internal
        view
        returns (bool initialized, MandateType mode)
    {
        ModeSlot storage slot = $mode[id][mux][account];
        if (slot.initialized) return (true, slot.mode);
        if ($configs[id][mux][account].initialized) return (true, MandateType.UNIVERSAL);
        return (false, MandateType.UNIVERSAL);
    }

    /**
     * @notice Writes one permission's configuration. Reached inside `enableSessions` during the
     *         wallet's `grantMandate`, where `msg.sender` becomes the multiplexer key.
     *
     * @dev    - Refuses re-initialisation, a deliberate deviation from the upstream policy
     *           interface, which says a repeat call must overwrite. Do not restore overwrite
     *           semantics for interface fidelity.
     *         - This cannot break a legitimate regrant: the wallet supplies a fresh salt on every
     *           grant, so a regranted mandate has a new permission id and therefore an untouched
     *           config slot. The refusal only ever fires on a path this system does not use.
     *         - Rejects an allow-list that is empty or longer than the cap, an expiry that is zero
     *           or already past, and a zero asset or expected destination account. An owner consent
     *           term has no meaningful silence, so "never expires" is written as the maximum value.
     *         - Deliberately does not validate cap values (zero and max are both legal, a zero
     *           per-call cap being a valid redeploy-only mandate), `beneficiaryOffset`, or
     *           allow-list contents. A wrong offset fails closed at validation time; it cannot widen
     *           a mandate, only break it. Offsets must be generated from each protocol's ABI by
     *           tooling rather than hand-typed, and each newly supported protocol must ship a test
     *           rejecting a wrong beneficiary and an oversized amount.
     *         - Anyone may call this with themselves as the multiplexer; that writes into their own
     *           keyed slice and the engine never reads it.
     *         - Writes the config, sets the initialised flag, and emits `URPPolicySet` and
     *           `PolicySet`.
     *
     *         - THE ENVELOPE. `initData` is `abi.encode(string chain, bytes body)` — IDENTICAL IN
     *           SHAPE FOR BOTH MODES, which is what lets the leading field be read before the mode
     *           is known. Nobody declares the mode: URP derives it from the chain with
     *           `PushChainLib.deriveMode`, and the wallet derived the same value from the same bytes
     *           at grant. There is no mode byte and therefore no `InvalidPolicyMode`.
     *         - Re-initialisation is refused ACROSS MODES, and the guard runs BEFORE the decode, so
     *           a malformed blob aimed at a live config still gets a named `AlreadyInitialized`.
     *         - MALFORMED ENVELOPES FAIL CLOSED, several of them NAMED. A v2 `(uint8 0, bytes)`
     *           wrapper and any bare struct decode to an EMPTY chain and revert `EmptyChain()`; a
     *           `(uint8, bytes32, bytes)` header and `(uint8 >= 2, bytes)` revert unnamed. Nothing
     *           mis-decodes into a live config — measured, one test per shape.
     *
     * @param  account   The wallet this config belongs to.
     * @param  configId  Engine-derived id binding the account and the permission.
     * @param  initData  `abi.encode(string chain, bytes body)`, body being `abi.encode(UniversalTerms)`
     *                   or `abi.encode(NativeTerms)` according to the DERIVED mode.
     */
    function initializeWithMultiplexer(address account, ConfigId configId, bytes calldata initData) external {
        ModeSlot storage slot = $mode[configId][msg.sender][account];

        // Legacy-aware: a pre-upgrade universal config has an empty `$mode` slot but MUST still refuse
        // re-initialisation — otherwise the owner door could reset its spend counter or flip its mode.
        (bool already,) = _modeOf(configId, msg.sender, account);
        if (already) revert AlreadyInitialized(configId);

        // THE ENVELOPE, decoded exactly as the wallet decoded it at grant — same expression, same
        // bytes. That identity is the whole consistency argument: there is no second author of the
        // discriminator, so there is nothing for the two contracts to disagree about.
        (string memory chain, bytes memory body) = abi.decode(initData, (string, bytes));
        if (bytes(chain).length == 0) revert EmptyChain();

        bytes32 chainHash = keccak256(bytes(chain));
        MandateType mode = PushChainLib.deriveMode(chainHash);

        if (mode == MandateType.UNIVERSAL) {
            _initUniversal($configs[configId][msg.sender][account], body, chainHash);
        } else {
            _initNative($native[configId][msg.sender][account], body);
        }

        slot.initialized = true;
        slot.mode = mode;
        slot.chainHash = chainHash;

        emit URPPolicySet(configId, msg.sender, account, mode, chainHash);
        emit PolicySet(configId, msg.sender, account);
    }

    /// @inheritdoc IURP
    function pushChainHash() external view returns (bytes32) {
        return PushChainLib.selfChainHash();
    }

    /**
     * @dev The universal init guards — unchanged from the single-mode contract, only relocated.
     * @param cfg   Storage slot to write.
     * @param body  `abi.encode(Config)`.
     */
    function _initUniversal(Config storage cfg, bytes memory body, bytes32 chainHash) internal {
        UniversalTerms memory incoming = abi.decode(body, (UniversalTerms));

        uint256 listLength = incoming.allowedCalls.length;
        if (listLength == 0 || listLength > MAX_ALLOWED_CALLS) revert AllowListOutOfRange(listLength);

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert InvalidExpiry(incoming.validUntil);
        }
        if (incoming.asset == address(0) || incoming.expectedCEA == address(0)) revert InvalidConfigField();

        // ─── THE TEETH ───
        //
        // After every decode and guard, before every write. Effects last, as everywhere else here.
        //
        // WHY THIS MAKES THE DECLARED CHAIN TRUE AT RUNTIME. `SOURCE_CHAIN_NAMESPACE()` is the exact
        // view the gateway reads on every outbound, through `UniversalCore.getOutboundTxGasAndFees`,
        // to decide where to route. Gate 5 pins `req.token == cfg.asset` on every request. So
        // asserting it here binds the owner's declared chain to the chain the gateway will actually
        // use — with no runtime change and no external call in `checkAction`.
        //
        // WHY AN EXTERNAL CALL IS SAFE HERE AND NOWHERE ELSE: this runs at INIT, inside the owner's
        // own grant transaction, never in `checkAction` and never on a removal path. A failure
        // blocks a grant; it can never block a revocation or an execution. The `try/catch` is
        // permitted because the external call ALREADY EXISTS — do not extend that reasoning to
        // `checkAction`'s decode, which has no external call to hide behind.
        //
        // A `view` call compiles to STATICCALL, so the callee cannot write state: reentrancy from a
        // hostile asset is structurally impossible, not merely unreachable.
        //
        // ⚠️ THE `code.length` GUARD IS NOT REDUNDANT WITH THE `catch`. MEASURED:
        //      callee reverts                 -> catch fires     -> named InvalidAsset
        //      no code at the address, or EOA -> catch does NOT  -> UNNAMED, empty revert
        //      answers with a non-string      -> catch does NOT  -> UNNAMED, empty revert
        //    Since solc 0.8.10 the compiler omits the extcodesize check when return data is
        //    expected; the call to a codeless address then SUCCEEDS with empty returndata and the
        //    failure happens when THIS frame tries to ABI-decode it — outside the try/catch. Without
        //    this line a typo'd asset address, the likeliest real mistake, reverts unnamed.
        if (incoming.asset.code.length == 0) revert InvalidAsset(incoming.asset);

        try IPRC20Source(incoming.asset).SOURCE_CHAIN_NAMESPACE() returns (string memory ns) {
            bytes32 assetChain = keccak256(bytes(ns));
            if (assetChain != chainHash) revert ChainMismatch(chainHash, assetChain);
        } catch {
            revert InvalidAsset(incoming.asset);
        }

        _store(cfg, incoming);
        cfg.initialized = true;
    }

    /**
     * @dev The native init guards.
     *
     *      - Refuses a zero target, and the GATEWAY as a target: the mirror of gate 3, and half of
     *        the consistency lock. A native config can never be written against the gateway.
     *      - Refuses a value-only config carrying pins or an amount rule. That combination can never
     *        authorise anything — every request under it would die at N7/N8 — so it is a
     *        misconfiguration the owner believes they granted, not a valid ascetic config. Same
     *        reasoning as the empty-allow-list refusal in universal mode.
     *      - Deliberately does NOT validate cap values (zero and max are both legal), pin offsets or
     *        `amount.offset` — they cannot be checked against calldata that does not exist yet, and a
     *        wrong offset fails closed at N7/N8 rather than widening anything. Nor the selector
     *        against the engine's fallback flags: the wallet refuses those at grant, and a
     *        stranger-slice config the engine never reads is harmless.
     *
     *      - MAKES NO EXTERNAL CALL. A native mandate has no asset, so there is nothing to verify the
     *        chain against — and nothing to verify: the chain IS this chain, which is what made the
     *        mode NATIVE in the first place. The universal branch's teeth have no native counterpart
     *        and must not acquire one.
     *
     * @param cfg   Storage slot to write.
     * @param body  `abi.encode(NativeTerms)`.
     */
    function _initNative(NativeConfig storage cfg, bytes memory body) internal {
        NativeTerms memory incoming = abi.decode(body, (NativeTerms));

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert InvalidExpiry(incoming.validUntil);
        }
        if (incoming.target == address(0)) revert NativeTargetZero();
        if (incoming.target == UNIVERSAL_GATEWAY_PC) revert NativeTargetIsGateway(incoming.target);
        if (incoming.pins.length > MAX_PINS) revert TooManyPins(incoming.pins.length);

        if (incoming.selector == VALUE_SELECTOR) {
            if (incoming.pins.length != 0) revert ValueOnlyWithPins();
            if (incoming.amount.enabled) revert ValueOnlyWithAmountRule();
        }

        _storeNative(cfg, incoming);
        cfg.initialized = true;
    }

    /**
     * @notice Runs every gate a cross-chain agent request must pass. Order is fixed; any failure
     *         reverts with nothing written.
     *
     * @dev    - Not `view`: gate 7 accumulates spend, and the engine invokes this with a real call
     *           so the write persists.
     *         - Runs before the session signature is verified, on unauthenticated calldata from an
     *           arbitrary caller. It is safe because it makes no external call, applies all effects
     *           last, and reverts on every failure. Do not introduce an external call here.
     *         - Replayed signatures cannot burn budget through this door; they die at the wallet's
     *           nonce gate first.
     *
     *         The gates, in order:
     *         1.  the config is initialised
     *         2.  the mandate has not expired
     *         3.  the target is the gateway
     *         4.  calldata is at least four bytes; the selector is the outbound send; the body is at
     *             least the minimum encoded length
     *         5.  the token matches the configured asset
     *         6.  the amount is within the per-call cap
     *         7.  the running total is within the lifetime cap
     *         8.  the Push-native value is within the per-call ceiling
     *         9.  the request does not ask for an uncapped gas swap
     *         10. the revert recipient is the wallet
     *         11. the recipient field is empty
     *         12. the payload is a multicall
     *         13. the inner call count is between one and the maximum
     *         14. no inner call targets the wallet, this policy, the gateway or the destination
     *             account
     *         15. each inner target and selector is allow-listed, and where the rule declares a
     *             beneficiary it matches the expected destination account
     *         16. each inner value is within its rule's allowance
     *
     *         - A zero amount passes gate 6 and writes nothing: zero-amount is the redeployment
     *           path, acting on capital already at the destination. There is no zero-amount gate and
     *           one must not be added.
     *         - `abi.decode` ignores trailing bytes, so gate 4c is a length floor and not a
     *           canonical-encoding check. There is no exploit: the whole execution calldata is bound
     *           into the wallet's operation hash, and the signature is verified last.
     *         - A body of correct length carrying malformed internal offsets reverts with a compiler
     *           panic rather than a named error. It cannot be given a named error without wrapping
     *           the decode in an external call, which this function must not have.
     *         - Spend accumulation is optimistic but atomic: it is written during validation and
     *           survives only because validation and dispatch share one transaction. Splitting them
     *           breaks the accounting silently.
     *         - Gate 14 runs before gate 15 on purpose, so a forbidden destination beats the
     *           allow-list: an owner who allow-listed their own destination account still cannot
     *           hand the agent direct control of it.
     *
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet. The engine passes its own caller through as this parameter, so it
     *                  is never the engine itself.
     * @param  target   Push-side call target; must be the gateway.
     * @param  value    Push-native value attached to the call.
     * @param  data     The gateway calldata, opened and walked by the gates above.
     * @return The engine's success sentinel.
     */
    function checkAction(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        external
        returns (uint256)
    {
        // MODE ROUTING. An EMPTY slot falls through to the universal path, whose gate 1 reverts
        // `NotInitialized` — fail-closed either way. The `initialized &&` conjunction is what makes
        // that safe: `MandateType.UNIVERSAL` is the zero value, so testing `mode` alone could not
        // tell an empty slot from a real universal one.
        //
        // This is also what lets pre-upgrade universal mandates keep working with no migration:
        // their `$mode` slot is empty, so they route to `_checkUniversal`, which is correct.
        ModeSlot storage slot = $mode[id][msg.sender][account];
        if (slot.initialized && slot.mode == MandateType.NATIVE) {
            return _checkNative(id, account, target, value, data);
        }
        return _checkUniversal(id, account, target, value, data);
    }

    /**
     * @dev The universal gauntlet — gates 1 to 16, unchanged from the single-mode contract. Only the
     *      function name and visibility changed; the body is byte-for-byte what `checkAction` was.
     *
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet.
     * @param  target   Push-side call target; must be the gateway.
     * @param  value    Push-native value attached to the call.
     * @param  data     The gateway calldata.
     * @return The engine's success sentinel.
     */
    function _checkUniversal(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        internal
        returns (uint256)
    {
        Config storage cfg = $configs[id][msg.sender][account];

        if (!cfg.initialized) revert NotInitialized(id, account);

        if (block.timestamp > cfg.validUntil) revert MandateExpired(cfg.validUntil);

        if (target != UNIVERSAL_GATEWAY_PC) revert InvalidTarget(target);

        if (data.length < 4) revert CalldataTooShort(data.length);

        if (bytes4(data[0:4]) != SEND_OUTBOUND_SELECTOR) revert InvalidSelector(bytes4(data[0:4]));

        if (data.length < 4 + MIN_OUTBOUND_BODY_LEN) revert MalformedOutboundRequest(data.length);
        UniversalOutboundTxRequest memory req = abi.decode(data[4:], (UniversalOutboundTxRequest));

        if (req.token != cfg.asset) revert AssetMismatch(cfg.asset, req.token);

        if (req.amount > cfg.maxAmountPerCall) revert AmountExceedsCap(req.amount, cfg.maxAmountPerCall);

        uint256 newSpent = cfg.spent + req.amount;
        if (newSpent > cfg.maxAmountTotal) revert TotalSpendCapExceeded(newSpent, cfg.maxAmountTotal);

        if (value > cfg.maxPCPerCall) revert PCValueExceedsCap(value, cfg.maxPCPerCall);

        if (req.maxPCForGas == 0) revert UncappedGasSwapRejected();

        if (req.revertRecipient != account) revert InvalidRevertRecipient(account, req.revertRecipient);

        if (req.recipient.length != 0) revert RecipientMustBeEmpty();

        _checkInnerCalls(cfg, account, req.payload);

        if (req.amount > 0) {
            cfg.spent = newSpent;
            emit OutboundMetered(id, msg.sender, account, req.amount);
        }

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev The native gauntlet — gates N1 to N9, then effects. The same discipline as the universal
     *      path and for the same reason: this runs BEFORE the session signature is verified, on
     *      unauthenticated calldata from an arbitrary caller.
     *
     *      - NO EXTERNAL CALLS. Pins and the metered amount are read by slicing `data` directly,
     *        never through `_slice` into memory and never through a helper that calls out.
     *      - ALL EFFECTS LAST. `newValueSpent` and `newAmountSpent` are computed at N6/N8 and
     *        assigned only after N9 passes, exactly as `_checkUniversal` handles `newSpent`. A
     *        request that fails at N7 leaves every counter untouched.
     *      - BOUNDS ARITHMETIC IS DONE IN `uint256`. `pin.offset` is `uint16`, so
     *        `uint256(offset) + 32` cannot wrap — but written as `uint16` arithmetic it would, and
     *        the check would pass on a crafted offset. Do not "simplify" the cast away.
     *      - `callsUsed` ALWAYS increments on success, including on a zero-value zero-amount call.
     *        A call is a use; mirroring universal's zero-amount rule (which writes nothing) would
     *        make `maxCalls` bypassable by zero-value calls, i.e. advisory. This is the one
     *        deliberate divergence between the two rulebooks.
     *      - Value-only configs carry no pins and no amount rule — init refuses that combination —
     *        so with `data.length == 0` the N7 loop does not execute and N8 is skipped.
     *
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet.
     * @param  target   Push-side call target; must be the configured native target.
     * @param  value    Push-native value attached to the call.
     * @param  data     The native calldata, read but never decoded as a structure.
     * @return The engine's success sentinel.
     */
    function _checkNative(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        internal
        returns (uint256)
    {
        NativeConfig storage cfg = $native[id][msg.sender][account];

        // N1
        if (!cfg.initialized) revert NotInitialized(id, account);

        // N2
        if (block.timestamp > cfg.validUntil) revert MandateExpired(cfg.validUntil);

        // N3 — the consistency lock, mirror of universal gate 3. Init refuses a gateway target, so
        // this can only fire on state the wallet's grant check makes unreachable. It is defence in
        // depth against a mis-wired grant, not dead code.
        if (target == UNIVERSAL_GATEWAY_PC) revert NativeTargetIsGateway(target);

        // N4
        if (target != cfg.target) revert TargetMismatch(target, cfg.target);

        // N5 — under four bytes is the engine's value-only selector; four or more is a real one.
        bytes4 sel = data.length < 4 ? VALUE_SELECTOR : bytes4(data[0:4]);
        if (sel != cfg.selector) revert SelectorMismatch(sel, cfg.selector);
        // Value-only means EMPTY calldata (register N-46). The engine buckets 1..3 bytes under the
        // same actionId, so URP is the layer that makes the documented meaning true.
        if (sel == VALUE_SELECTOR && data.length != 0) revert ValueOnlyCalldataNotEmpty(data.length);

        // N6
        if (value > cfg.maxValuePerCall) revert ValueExceedsCap(value, cfg.maxValuePerCall);
        uint256 newValueSpent = cfg.valueSpent + value;
        if (newValueSpent > cfg.maxValueTotal) revert TotalValueExceeded(newValueSpent, cfg.maxValueTotal);

        // N7
        uint256 pinCount = cfg.pins.length;
        for (uint256 i; i < pinCount;) {
            ArgPin storage pin = cfg.pins[i];
            uint256 needed = uint256(pin.offset) + 32;
            if (data.length < needed) revert CalldataTooShortForPin(data.length, i, needed);

            bytes32 actual = bytes32(data[pin.offset:needed]);
            if (actual != pin.expected) revert ArgPinMismatch(actual, i, pin.expected);

            unchecked {
                ++i;
            }
        }

        // N8
        uint256 amt;
        uint256 newAmountSpent = cfg.amountSpent;
        if (cfg.amount.enabled) {
            uint256 neededAmt = uint256(cfg.amount.offset) + 32;
            if (data.length < neededAmt) revert CalldataTooShortForAmount(data.length, neededAmt);

            amt = uint256(bytes32(data[cfg.amount.offset:neededAmt]));
            if (amt > cfg.amount.maxPerCall) revert NativeAmountExceedsCap(amt, cfg.amount.maxPerCall);

            newAmountSpent = cfg.amountSpent + amt;
            if (newAmountSpent > cfg.amount.maxTotal) {
                revert TotalNativeAmountExceeded(newAmountSpent, cfg.amount.maxTotal);
            }
        }

        // N9
        if (cfg.maxCalls != 0 && cfg.callsUsed >= cfg.maxCalls) {
            revert CallLimitReached(cfg.callsUsed, cfg.maxCalls);
        }

        // Effects, last.
        cfg.valueSpent = newValueSpent;
        cfg.amountSpent = newAmountSpent;
        unchecked {
            // Bounded by N9 when maxCalls != 0; when it is 0 the counter is informational and a
            // uint32 overflow is unreachable at any realistic call volume.
            cfg.callsUsed = cfg.callsUsed + 1;
        }
        emit NativeCallMetered(id, msg.sender, account, value, amt);

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev Implements gates 12 to 16 of `checkAction`'s list.
     *
     *      - Split out for stack depth only. It makes no external call and writes no storage, so the
     *        caller's effects-last property holds.
     *      - Gate 12 is not merely a format check: the destination account dispatches on the payload
     *        prefix, and only the multicall branch has entries that gates 13 to 16 can walk. Its
     *        other branches re-target the account itself or call an arbitrary target with the raw
     *        payload, bypassing the allow-list, the beneficiary pin and the per-entry value cap.
     *        Do not weaken this gate, or the agent picks its own branch.
     *      - A payload that is exactly the multicall selector, or the selector followed by malformed
     *        bytes, reverts inside the ABI decoder rather than with a named error. No minimum-length
     *        pre-check is added: unlike gate 4c, this decode sits behind eleven gates on an already
     *        constrained request, so a second hand-derived constant would be more surface than the
     *        named error is worth. It fails closed either way.
     *
     * @param cfg      Config to validate against.
     * @param account  The wallet, used as the forbidden self-target and the refund destination.
     * @param payload  The multicall payload carried by the outbound request.
     */
    function _checkInnerCalls(Config storage cfg, address account, bytes memory payload) internal view {
        if (payload.length < 4 || bytes4(_slice(payload, 0, 4)) != MULTICALL_SELECTOR) revert PayloadNotMulticall();

        Multicall[] memory calls = abi.decode(_slice(payload, 4, payload.length - 4), (Multicall[]));

        uint256 count = calls.length;
        if (count == 0 || count > MAX_ACTIONS_PER_REQUEST) revert BatchSizeOutOfRange(count);

        address expectedCEA = cfg.expectedCEA;

        for (uint256 i; i < count;) {
            Multicall memory entry = calls[i];

            if (
                entry.to == account || entry.to == address(this) || entry.to == UNIVERSAL_GATEWAY_PC
                    || entry.to == expectedCEA
            ) {
                revert ForbiddenInnerTarget(entry.to);
            }
            if (entry.data.length < 4) revert MalformedInnerCalldata();

            AllowedCall memory rule = _requireAllowed(cfg, entry.to, bytes4(_slice(entry.data, 0, 4)));
            if (rule.hasBeneficiary) {
                address beneficiary = _extractBeneficiary(entry.data, rule.beneficiaryOffset);
                if (beneficiary != expectedCEA) revert BeneficiaryMismatch(expectedCEA, beneficiary);
            }

            // Destination-chain native units, never the Push-side value: two assets on two chains.
            if (entry.value > rule.maxValue) revert InnerValueExceedsAllowance(i, entry.value, rule.maxValue);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Exact-equality assertion on the spend counter; the change-flow race guard.
     *
     * @dev    - Intended as the first entry of the owner's atomic change batch: assert, revoke,
     *           grant. A mismatch reverts the whole change.
     *         - Reverts if the config is not initialised. Reading zero from a ghost config is
     *           indistinguishable from reading zero from a real unused mandate, and this function
     *           exists to catch stale belief, so it must not have a silent-pass mode.
     *         - Exact equality in both directions, so a credit landing between read and submit also
     *           forces recomposition.
     *         - Callable by anyone; it is a pure read.
     *
     * @param  id             Config id identifying the mandate.
     * @param  account        The wallet the mandate belongs to.
     * @param  expectedSpent  The spend total the caller composed its change against.
     */
    function assertSpent(ConfigId id, address account, uint256 expectedSpent) external view {
        (bool init, MandateType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == MandateType.NATIVE) revert WrongModeForCall(MandateType.NATIVE);

        Config storage cfg = $configs[id][SESSION_ENGINE][account];

        if (!cfg.initialized) revert NotInitialized(id, account);

        if (cfg.spent != expectedSpent) revert SpentMismatch(expectedSpent, cfg.spent);
    }

    /**
     * @notice The native change-flow race guard: exact equality on all three counters.
     *
     * @dev    - The native counterpart of the universal `assertSpent`, and the same intent: the
     *           first entry of the owner's atomic change batch — assert, revoke, grant.
     *         - Reverts `WrongModeForCall(UNIVERSAL)` on a universal config and `NotInitialized` on
     *           a ghost. It must not have a silent-pass mode: reading zero from a ghost config is
     *           indistinguishable from reading zero from a real unused mandate, and this function
     *           exists to catch stale belief.
     *         - Exact equality on every counter, in both directions.
     *         - Callable by anyone; it is a pure read.
     *
     * @param  id                   Config id identifying the mandate.
     * @param  account              The wallet the mandate belongs to.
     * @param  expectedValueSpent   Native value total the caller composed against.
     * @param  expectedAmountSpent  Metered calldata-amount total the caller composed against.
     * @param  expectedCalls        Call count the caller composed against.
     */
    function assertSpent(
        ConfigId id,
        address account,
        uint256 expectedValueSpent,
        uint256 expectedAmountSpent,
        uint32 expectedCalls
    ) external view {
        (bool init, MandateType mode) = _modeOf(id, SESSION_ENGINE, account);

        if (!init) revert NotInitialized(id, account);
        if (mode != MandateType.NATIVE) revert WrongModeForCall(MandateType.UNIVERSAL);

        NativeConfig storage cfg = $native[id][SESSION_ENGINE][account];

        if (cfg.valueSpent != expectedValueSpent) revert SpentMismatch(expectedValueSpent, cfg.valueSpent);
        if (cfg.amountSpent != expectedAmountSpent) revert SpentMismatch(expectedAmountSpent, cfg.amountSpent);
        if (cfg.callsUsed != expectedCalls) revert SpentMismatch(expectedCalls, cfg.callsUsed);
    }

    /**
     * @notice Credits a confirmed far-side failure back to the spend counter.
     *
     * @dev    - Callable only by the executor module; nobody else can fabricate a failure.
     *         - Reverts if the config is not initialised, checked before the idempotency flag is
     *           written so a misrouted credit stays retryable rather than burning the outbound id
     *           forever.
     *         - Reverts if the id was already credited.
     *         - Subtracts saturating, since the amount is trusted from Push core and cannot be
     *           verified here. Idempotency and saturation bound a wrong value.
     *         - Emits the amount actually applied, not the amount claimed, so monitoring can detect
     *           divergence between the two.
     *         - Not yet functional: the executor module does not yet call this on outbound failure,
     *           so until that lands a failed far leg leaves `spent` inflated and the remedy is
     *           revoke-and-regrant.
     *         - There is no gas counter and this path must never introduce one, because gas consumed
     *           on a failed outbound was genuinely consumed.
     *
     * @param  id            Config id identifying the mandate.
     * @param  account       The wallet the mandate belongs to.
     * @param  outboundTxId  Push-core transaction id, the idempotency key.
     * @param  amount        Amount claimed as failed, credited saturating.
     */
    function creditRevert(ConfigId id, address account, bytes32 outboundTxId, uint256 amount) external {
        if (msg.sender != UNIVERSAL_EXECUTOR_MODULE) revert NotExecutorModule(msg.sender);

        Config storage cfg = $configs[id][SESSION_ENGINE][account];

        if (!cfg.initialized) revert NotInitialized(id, account);

        if ($credited[outboundTxId]) revert AlreadyCredited(outboundTxId);
        $credited[outboundTxId] = true;

        uint256 applied = cfg.spent > amount ? amount : cfg.spent;
        cfg.spent -= applied;

        emit RevertCredited(outboundTxId, id, account, applied);
    }

    /**
     * @notice The full universal config including the allow-list, keyed on the session engine.
     *
     * @dev    Reverts `WrongModeForCall(NATIVE)` on a native slot. An EMPTY slot returns the zeroed
     *         struct exactly as it always has — an empty slot is a STATE, a wrong-mode read is a
     *         CALLER BUG, and only the second is worth a revert. `getMode` is the documented first
     *         call for anything that does not already know a mandate's mode.
     *
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet the mandate belongs to.
     * @return The stored config.
     */
    function getConfig(ConfigId id, address account) external view returns (Config memory) {
        (bool init, MandateType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == MandateType.NATIVE) revert WrongModeForCall(MandateType.NATIVE);

        return $configs[id][SESSION_ENGINE][account];
    }

    /**
     * @notice The full native config including its pins, keyed on the session engine.
     * @dev    Reverts `WrongModeForCall(UNIVERSAL)` on a universal slot; an empty slot returns the
     *         zeroed struct. See `getConfig`.
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet the mandate belongs to.
     * @return The stored native config.
     */
    function getNativeConfig(ConfigId id, address account) external view returns (NativeConfig memory) {
        (bool init, MandateType mode) = _modeOf(id, SESSION_ENGINE, account);
        if (init && mode == MandateType.UNIVERSAL) revert WrongModeForCall(MandateType.UNIVERSAL);

        return $native[id][SESSION_ENGINE][account];
    }

    /**
     * @notice Which rulebook a config uses, and which chain it was granted for. NEVER REVERTS.
     * @dev    The documented first call for any integrator that does not already know a mandate's
     *         mode. An empty slot returns `(initialized: false, mode: UNIVERSAL, chainHash: 0)` — and
     *         the mode value is MEANINGLESS when `initialized` is false, because `UNIVERSAL` is the
     *         enum's zero value. Read `initialized` first, always.
     *
     *         `chainHash` IS READ RAW, not through `_modeOf`. A pre-envelope config has a populated
     *         `$configs` entry and an empty `$mode` slot: `_modeOf` correctly reports it as an
     *         initialised UNIVERSAL mandate, but no chain was ever recorded for it, so the zero it
     *         returns here is the honest answer — "unverified", not "chain zero". Deriving a chain
     *         for such a config would be inventing one.
     *
     *         THE TWO FIELDS ANSWER DIFFERENT QUESTIONS, deliberately: `initialized`/`mode` is "is
     *         there a rulebook, and which one" — legacy-aware, so pre-envelope configs still answer;
     *         `chainHash` is "was a chain declared and verified" — zero means no.
     *
     *         AND FOR SUCH A CONFIG, DO NOT GO LOOKING IN `getConfig(...).destChainHash` INSTEAD. It
     *         may hold a value the SDK wrote before the envelope existed, under any of the four
     *         conventions that field accumulated, and NOTHING EVER VERIFIED IT. A zero here is more
     *         truthful than a number there.
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet the mandate belongs to.
     * @return The stored mode record.
     */
    function getMode(ConfigId id, address account) external view returns (ModeSlot memory) {
        (bool init, MandateType mode) = _modeOf(id, SESSION_ENGINE, account);
        return ModeSlot({ initialized: init, mode: mode, chainHash: $mode[id][SESSION_ENGINE][account].chainHash });
    }

    /**
     * @notice Exposes the idempotency set for monitoring.
     * @param  outboundTxId  Push-core transaction id to query.
     * @return Whether that id has already been credited.
     */
    function isCredited(bytes32 outboundTxId) external view returns (bool) {
        return $credited[outboundTxId];
    }

    /**
     * @notice The implementation's version, readable THROUGH the proxy.
     *
     * @dev    The proxy has no version of its own — it delegates, so this answers with whichever
     *         implementation is currently installed. That makes it the cheapest possible check that
     *         an upgrade actually took effect: read it before, upgrade, read it again.
     *
     *         A `constant` in bytecode, deliberately not storage: it must change with the CODE, and
     *         a storage value could drift from the logic it claims to describe.
     *
     *         BUMP THIS IN THE SAME COMMIT AS ANY LOGIC CHANGE.
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice ERC-165 support check.
     * @param  iid  Interface id to query.
     * @return True for the action-policy, policy and ERC-165 interfaces.
     */
    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return
            iid == type(IActionPolicy).interfaceId || iid == type(IPolicy).interfaceId
                || iid == type(IERC165).interfaceId;
    }

    /**
     * @dev Reads the 32-byte word at `offset` and returns its low 20 bytes. Bounds-checked because
     *      reading past the end of a short blob would return adjacent memory, which could be
     *      manipulated to pass the beneficiary check.
     *
     * @param  data    Inner call calldata to read from.
     * @param  offset  Byte offset of the beneficiary word, taken from config and never the request.
     * @return The address encoded at that offset.
     */
    function _extractBeneficiary(bytes memory data, uint16 offset) internal pure returns (address) {
        if (uint256(offset) + 32 > data.length) revert MalformedInnerCalldata();
        bytes32 word;
        assembly {
            word := mload(add(add(data, 0x20), offset))
        }
        return address(uint160(uint256(word)));
    }

    /**
     * @dev The target and selector pair must appear in the allow-list.
     * @param  cfg       Config whose allow-list is scanned.
     * @param  to        Inner call target.
     * @param  selector  Inner call selector.
     * @return The matching rule; reverts with `CallNotAllowed` if there is none.
     */
    function _requireAllowed(Config storage cfg, address to, bytes4 selector)
        internal
        view
        returns (AllowedCall memory)
    {
        uint256 len = cfg.allowedCalls.length;
        for (uint256 i; i < len;) {
            AllowedCall storage rule = cfg.allowedCalls[i];
            if (rule.target == to && rule.selector == selector) {
                return
                    AllowedCall(rule.target, rule.selector, rule.beneficiaryOffset, rule.hasBeneficiary, rule.maxValue);
            }
            unchecked {
                ++i;
            }
        }
        revert CallNotAllowed(to, selector);
    }

    /**
     * @dev Memory slice helper. The bounds branch is unreachable from the three call sites, which
     *      are all length-guarded by gates 12 and 14, and is expected to show as uncovered. It stays
     *      because this is a `pure` helper whose safety must not depend on every future caller.
     *
     * @param  data   Blob to slice.
     * @param  start  Byte offset to start at.
     * @param  len    Number of bytes to copy.
     * @return out    The requested slice.
     */
    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        if (start + len > data.length) revert MalformedInnerCalldata();
        out = new bytes(len);
        // MCOPY requires evm_version = "cancun"; lowering the EVM target breaks this silently at
        // deploy time rather than loudly at compile time.
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), start), len)
        }
    }

    /**
     * @dev Copies decoded WIRE terms into the STORAGE config. The two are deliberately different
     *      types: the wire shape is free to change, the storage layout is frozen forever
     *      (see the layout note on `__gap`).
     *
     *      - Forces `spent` to zero. It is not a wire field at all — URP owns it.
     *      - DOES NOT WRITE `destChainHash`. That slot is a v2 relic, kept only so the layout never
     *        moves; the chain of every mandate now lives on `ModeSlot.chainHash`, where it has been
     *        verified against the asset. Writing it here would recreate the second source of truth
     *        this change exists to remove.
     *      - Clears and repopulates the allow-list.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     *
     * @param cfg       Storage slot to write into.
     * @param incoming  Decoded wire terms to copy from.
     */
    function _store(Config storage cfg, UniversalTerms memory incoming) internal {
        cfg.validUntil = incoming.validUntil;
        cfg.expectedCEA = incoming.expectedCEA;
        cfg.asset = incoming.asset;
        cfg.maxAmountPerCall = incoming.maxAmountPerCall;
        cfg.maxAmountTotal = incoming.maxAmountTotal;
        cfg.maxPCPerCall = incoming.maxPCPerCall;
        cfg.spent = 0;

        // Re-initialisation is refused, so in production this array is always empty here. The
        // delete is kept for the stranger-slice path and for tests.
        delete cfg.allowedCalls;
        uint256 len = incoming.allowedCalls.length;
        for (uint256 i; i < len;) {
            cfg.allowedCalls.push(incoming.allowedCalls[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Copies a decoded native config into storage. The native counterpart of `_store`.
     *
     *      - Forces `valueSpent`, `amountSpent` and `callsUsed` to zero, ignoring anything the
     *        caller supplied. A caller-set counter would be a granted head start on every cap.
     *      - `amount` is a value struct with no dynamic members, so it assigns wholesale.
     *      - `pins` must be copied ELEMENT BY ELEMENT: Solidity cannot assign a memory dynamic array
     *        into a storage struct field. Same shape as `allowedCalls` above, same reason.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     *
     * @param cfg       Storage slot to write into.
     * @param incoming  Decoded native wire terms to copy from.
     */
    function _storeNative(NativeConfig storage cfg, NativeTerms memory incoming) internal {
        cfg.validUntil = incoming.validUntil;
        cfg.target = incoming.target;
        cfg.selector = incoming.selector;
        cfg.maxValuePerCall = incoming.maxValuePerCall;
        cfg.maxValueTotal = incoming.maxValueTotal;
        cfg.valueSpent = 0;
        cfg.amount = incoming.amount;
        cfg.amountSpent = 0;
        cfg.maxCalls = incoming.maxCalls;
        cfg.callsUsed = 0;

        // Re-initialisation is refused, so in production this array is always empty here. The
        // delete is kept for the stranger-slice path and for tests.
        delete cfg.pins;
        uint256 len = incoming.pins.length;
        for (uint256 i; i < len;) {
            cfg.pins.push(incoming.pins[i]);
            unchecked {
                ++i;
            }
        }
    }
}
