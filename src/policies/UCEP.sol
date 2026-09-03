// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";

import { IUCEP } from "../interfaces/IUCEP.sol";
import {
    UniversalOutboundTxRequest,
    Multicall,
    MULTICALL_SELECTOR,
    SEND_OUTBOUND_SELECTOR as GATEWAY_SEND_OUTBOUND_SELECTOR
} from "../libraries/PushWalletTypes.sol";

/**
 * @title  UCEP — Universal CrossChain Execution Policy
 * @notice The security boundary of the whole system: the only contract that ever inspects what an
 *         agent really does on the far chain. Everything else routes, stores, or signs.
 *
 * @dev    The engine identifies actions by hashing the PUSH-SIDE target and selector. Every agent
 *         action is the same Push-side call — the wallet calling the gateway's send function — so
 *         to the engine a market trade, a lending deposit and a theft are identical. Everything the
 *         user actually authorised lives inside the payload, two decode levels down. UCEP opens it.
 *
 * @dev    FAIL-CLOSED ANCHOR. The engine requires at least one action policy per action
 *         (`SmartSession.sol:285,299,334`; `PolicyLib.sol:71`). UCEP is that policy, so stripping
 *         it does not weaken the mandate — it kills every request.
 *
 * @dev    No admin, no owner, no setters, no pause, not upgradeable. Three immutables are its only
 *         trust anchors.
 */
contract UCEP is IUCEP {
    // ─────────────────────────────── constants ───────────────────────────────

    // IMPORTED, NOT REDECLARED — all three already exist elsewhere and duplicating a constant
    // across a trust boundary is exactly the drift this project has been eliminating.
    //   VALIDATION_SUCCESS      ← erc7579/interfaces/IERC7579Module.sol (via smartsessions/interfaces/IPolicy.sol)
    //   MULTICALL_SELECTOR      ← src/libraries/PushWalletTypes.sol  (value 0x2cc2842d, verified identical)
    //   SEND_OUTBOUND_SELECTOR  ← src/libraries/PushWalletTypes.sol, re-exposed below

    /// @dev The maximum number of actions one batched request may carry. Named, never inlined:
    ///      it is the ceiling gate 13 enforces and the bound on the inner validation loop.
    uint256 internal constant MAX_ACTIONS_PER_REQUEST = 10;

    /// @dev Bounds the allow-list loop, which was the last unbounded loop in this contract.
    uint256 internal constant MAX_ALLOWED_CALLS = 32;

    /// @notice The gateway selector every agent action must carry.
    /// @dev    PART OF THIS CONTRACT'S ABI — monitoring and the SDK read it, so it stays a public
    ///         constant. The VALUE is not defined here: it is the shared gateway constant, so the
    ///         wallet's grant-shape check and this policy's request gate cannot disagree.
    bytes4 public constant SEND_OUTBOUND_SELECTOR = GATEWAY_SEND_OUTBOUND_SELECTOR;

    // The smallest possible ABI encoding of a UniversalOutboundTxRequest argument list.
    // Derivation (PushWalletTypes.sol:9-18): 32 (outer offset word — the struct is dynamic, so
    // abi.encode prefixes a pointer) + 256 (eight head words) + 32 + 32 (length words for the two
    // empty dynamic `bytes` fields, `recipient` and `payload`) = 352.
    // DO NOT hand-maintain this number: a test pins it against abi.encode of an empty request, so
    // a future field added to the struct fails the build instead of silently loosening gate 4c.
    uint256 internal constant MIN_OUTBOUND_BODY_LEN = 352;

    // ─────────────────────────────── immutables ───────────────────────────────

    /// @notice The one Push-side target any agent action may reach (gate 3).
    address public immutable UNIVERSAL_GATEWAY_PC;

    /// @notice The sole caller permitted to credit a failed outbound.
    /// @dev    Address UNCONFIRMED against a live deployment — confirm before mainnet. It is a
    ///         constructor argument, so nothing about building or testing depends on the real one.
    address public immutable UNIVERSAL_EXECUTOR_MODULE;

    /// @notice The multiplexer this contract trusts on every non-engine-driven path.
    /// @dev    Never accepted as an argument: a wrong value would silently address an empty slice.
    address public immutable SESSION_ENGINE;

    // ──────────────────────────────── storage ────────────────────────────────

    /// configId => multiplexer (the engine) => account (the wallet) => config
    ///
    /// WHY THREE LEVELS, AND WHY THE MULTIPLEXER IS NEVER A PARAMETER
    /// `ConfigId` already binds the account and the permission:
    ///     permissionId   = keccak256(abi.encode(sessionValidator, sessionValidatorInitData, salt))  IdLib.sol:79
    ///     actionId       = keccak256(abi.encodePacked(target, selector))                            IdLib.sol:19
    ///     actionPolicyId = keccak256(abi.encodePacked(permissionId, actionId))                      IdLib.sol:30
    ///     configId       = keccak256(abi.encodePacked(account, actionPolicyId))                     IdLib.sol:41
    /// NOTE THE MIX: permissionId uses abi.encode (its inputs include a dynamic `bytes`, where
    /// encodePacked would be ambiguous); the three layers below it use abi.encodePacked over
    /// fixed-width values. An SDK that assumes one encoding throughout derives every id wrong.
    /// The middle level therefore isolates CALLERS, not permissions. On the two engine-driven
    /// entry points it is `msg.sender` — authenticated, correct. Every other function keys on the
    /// SESSION_ENGINE immutable.
    mapping(ConfigId => mapping(address => mapping(address => Config))) internal $configs;

    /// outbound tx id => credited already (idempotency for the refund path)
    mapping(bytes32 => bool) internal $credited;

    // ────────────────────────────── constructor ──────────────────────────────

    constructor(address universalGatewayPC, address universalExecutorModule, address sessionEngine) {
        if (universalGatewayPC == address(0)) revert ZeroAddress();
        if (universalExecutorModule == address(0)) revert ZeroAddress();
        if (sessionEngine == address(0)) revert ZeroAddress();

        UNIVERSAL_GATEWAY_PC = universalGatewayPC;
        UNIVERSAL_EXECUTOR_MODULE = universalExecutorModule;
        SESSION_ENGINE = sessionEngine;
    }

    // ──────────────────────────── initialisation ────────────────────────────

    /**
     * @notice Write one permission's configuration. Reached inside `enableSessions` during the
     *         wallet's `grantMandate`; `msg.sender` becomes the multiplexer key.
     * @dev    Anyone CAN call this with themselves as multiplexer — that writes into their own
     *         keyed slice and touches nothing the real engine reads. Harmless by keying.
     * @param  initData `abi.encode(Config)`.
     */
    function initializeWithMultiplexer(address account, ConfigId configId, bytes calldata initData) external {
        Config storage cfg = $configs[configId][msg.sender][account];

        // RE-INITIALISATION IS REFUSED — a deliberate, ruled deviation from the upstream IPolicy
        // comment "MAY be called again without deinit; MUST overwrite" (IPolicy.sol:22-24).
        // DO NOT restore overwrite semantics for interface fidelity.
        //
        // WHY THIS CANNOT BREAK A LEGITIMATE REGRANT, which is the question it raises: the wallet
        // supplies a fresh salt from its monotonic grant counter on every grant, so a regranted
        // mandate has a new permissionId, hence a new ConfigId, hence a genuinely untouched slot.
        // The refusal can therefore only ever fire on a path v3 does not use — which turns the
        // engine's owner-only in-place counter-reset lever into a wall.
        if (cfg.initialized) revert AlreadyInitialized(configId);

        Config memory incoming = abi.decode(initData, (Config));

        // The allow-list bound (RULED 2026-08-31). The gauntlet's cost is O(entries × allow-list);
        // entries are capped at ten by gate 13, so without this the allow-list was the one
        // unbounded loop left in the contract. An empty list is refused too: it can never
        // authorise anything, so it is a misconfiguration, not a valid ascetic config.
        uint256 listLength = incoming.allowedCalls.length;
        if (listLength == 0 || listLength > MAX_ALLOWED_CALLS) revert AllowListOutOfRange(listLength);

        // An owner consent term has no meaningful silence — "never expires" is written explicitly
        // as type(uint48).max, never left as zero.
        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert InvalidExpiry(incoming.validUntil);
        }
        if (incoming.asset == address(0) || incoming.expectedCEA == address(0)) revert InvalidConfigField();

        // NOT VALIDATED, DELIBERATELY: cap values (zero and max are both legal — a per-call cap of
        // zero is a valid redeploy-only mandate); `destChainHash` (informational); and
        // `beneficiaryOffset`. Allow-list LENGTH is validated above; its CONTENTS are not, and that
        // is an obligation this contract cannot enforce: offsets must be GENERATED from each
        // protocol's ABI by tooling and never hand-typed, and every newly supported protocol must
        // ship a test rejecting a wrong beneficiary and an oversized amount. A wrong offset fails
        // closed, per-rule, at validation time — it cannot widen a mandate, only break it.
        _store(cfg, incoming);
        cfg.initialized = true;

        emit UCEPPolicySet(configId, msg.sender, account);
        emit PolicySet(configId, msg.sender, account);
    }

    // ──────────────────────────────── the gauntlet ────────────────────────────────

    /**
     * @notice THE GAUNTLET. Sixteen gates; order is normative. Any failure reverts with nothing written.
     *
     * @dev    NOT `view` — gate 7's accumulation is the point. The engine invokes it with a real
     *         call, so the write persists.
     *
     * @dev    CALLDATA-SAFETY CONSTRAINT (standing). This runs BEFORE the session signature is
     *         verified (`SmartSession.sol:344-352`), on unauthenticated calldata from an arbitrary
     *         caller. It holds because: no external calls, all effects last, revert on every
     *         failure. Replayed signatures cannot burn budget through the open door — they die at
     *         the wallet's nonce gate first. Do not introduce an external call into this function.
     */
    function checkAction(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        external
        returns (uint256)
    {
        Config storage cfg = $configs[id][msg.sender][account];

        // ── gate 1 · configured ──
        if (!cfg.initialized) revert NotInitialized(id, account);

        // ── gate 2 · not expired · the permission expiry lives HERE, making UCEP the complete
        //    mandatory set: no other policy needs to exist for the user to be safe.
        if (block.timestamp > cfg.validUntil) revert MandateExpired(cfg.validUntil);

        // ── gate 3 · gateway only · the entire far-chain rulebook below is sound only because
        //    everything must pass through the gateway.
        if (target != UNIVERSAL_GATEWAY_PC) revert InvalidTarget(target);

        // ── gate 4a · a distinct error, NOT InvalidSelector(bytes4(0)). There is no selector to
        //    report, and a zero sentinel would be indistinguishable from a genuine all-zero-selector
        //    payload, which an attacker can send freely.
        if (data.length < 4) revert CalldataTooShort(data.length);

        // ── gate 4b · send function only ──
        if (bytes4(data[0:4]) != SEND_OUTBOUND_SELECTOR) revert InvalidSelector(bytes4(data[0:4]));

        // ── gate 4c · the length pre-check exists so the dominant malformed case is still NAMED.
        //    What remains un-named is a body of CORRECT length carrying malformed internal offsets:
        //    abi.decode reverts there with a compiler-generated Panic(0x41) or a bare ABI-decoder
        //    revert. It cannot be made to emit a named error without wrapping the call in
        //    `try this.decode(...)`, which would introduce an EXTERNAL CALL into checkAction —
        //    and the safety argument above rests on there being none. DO NOT WRAP IT.
        //
        //    abi.decode also IGNORES TRAILING BYTES, so this is not a canonical-encoding check —
        //    the suite characterises that explicitly. There is no exploit, for two independent
        //    reasons: the whole
        //    executionCalldata is bound into the wallet's operation hash, and the signature is
        //    verified LAST, so anything a policy wrote on garbage-appended calldata is unwound.
        if (data.length < 4 + MIN_OUTBOUND_BODY_LEN) revert MalformedOutboundRequest(data.length);
        UniversalOutboundTxRequest memory req = abi.decode(data[4:], (UniversalOutboundTxRequest));

        // ── gate 5 · the one token — and with it, transitively, the one chain ──
        if (req.token != cfg.asset) revert AssetMismatch(cfg.asset, req.token);

        // ── gate 6 · per-action cap. An amount of 0 passes trivially: zero-amount is the
        //    REDEPLOYMENT path (acting on capital already at the destination). There is no
        //    zero-amount gate in this design and one must not be restored.
        if (req.amount > cfg.maxAmountPerCall) revert AmountExceedsCap(req.amount, cfg.maxAmountPerCall);

        // ── gate 7 · lifetime cap. 0.8.x overflow-safe; max-cap configs never trip. ──
        uint256 newSpent = cfg.spent + req.amount;
        if (newSpent > cfg.maxAmountTotal) revert TotalSpendCapExceeded(newSpent, cfg.maxAmountTotal);

        // ── gate 8 · Push-native per-call ceiling (protocol fee + gas swap) ──
        if (value > cfg.maxPCPerCall) revert PCValueExceedsCap(value, cfg.maxPCPerCall);

        // ── gate 9 · at the gateway, zero means "no cap on the gas swap". The OWNER may set
        //    unlimited caps in config; an AGENT may not author an unlimited request field.
        if (req.maxPCForGas == 0) revert UncappedGasSwapRejected();

        // ── gate 10 · a deliberately failed outbound must refund the wallet, never the agent ──
        if (req.revertRecipient != account) revert InvalidRevertRecipient(account, req.revertRecipient);

        // ── gate 11 · funds may only travel with the instruction payload. Defence in depth: the
        //    far-side multicall branch discards this field today; the pin makes that safety local
        //    instead of inherited. NOT dead code.
        if (req.recipient.length != 0) revert RecipientMustBeEmpty();

        _checkInnerCalls(cfg, account, req.payload);

        // ── EFFECTS LAST, only after every gate on every entry ──
        //
        // ACCUMULATION IS OPTIMISTIC BUT ATOMIC: `spent` is written during validation, before
        // execution, and survives only because validation and dispatch share one transaction.
        // A future maintainer who splits them breaks the accounting silently.
        if (req.amount > 0) {
            cfg.spent = newSpent;
            emit OutboundMetered(id, msg.sender, account, req.amount); // the Push-core correlation record
        }
        // Zero-amount requests write nothing and emit nothing — there is nothing to meter and
        // nothing to ever credit back.

        return VALIDATION_SUCCESS;
    }

    /**
     * @dev Gates 12–16 — the inner multicall. Split out of `checkAction` for stack depth only;
     *      it performs no external calls and writes no storage, so the effects-last property of
     *      the caller is preserved.
     */
    function _checkInnerCalls(Config storage cfg, address account, bytes memory payload) internal view {
        // ── gate 12 · instruction list only.
        //
        //    THIS IS NOT MERELY A FORMAT CHECK — it is the gate that confines the agent to ONE of
        //    the destination account's three payload branches. The CEA dispatches on the payload
        //    prefix (push-chain-core-contracts/src/cea/CEA.sol:171-179):
        //      · MULTICALL_SELECTOR → _handleMulticall  — the only branch UCEP can police, because
        //        it is the only one whose entries gates 13-16 can walk;
        //      · MIGRATION_SELECTOR → _handleMigration  — re-targets the CEA itself;
        //      · anything else      → _handleSingleCall — which performs
        //        `recipient.call{value: msg.value}(payload)` (CEA.sol:244) against an ARBITRARY
        //        target with the RAW payload, bypassing the allow-list, the beneficiary pin and
        //        the per-entry value cap entirely.
        //    Gates 11 and 12 together are what make the far-chain rulebook reachable at all.
        //    Do not weaken or "simplify" this gate: without it, gates 13-16 are unreachable and
        //    the agent picks its own branch.
        if (payload.length < 4 || bytes4(_slice(payload, 0, 4)) != MULTICALL_SELECTOR) revert PayloadNotMulticall();

        //    UN-NAMED RESIDUAL, deliberate — the same situation as gate 4c, one level down. A
        //    payload that is exactly MULTICALL_SELECTOR (empty body), or the selector followed by
        //    structurally malformed bytes, reverts INSIDE the ABI decoder: a bare revert or a
        //    Panic, not PayloadNotMulticall. Verified by probe: both return empty returndata.
        //    No MIN_MULTICALL_BODY_LEN pre-check is added. Unlike gate 4c — which guards the
        //    dominant malformed case on unauthenticated calldata — this decode sits behind eleven
        //    gates on an already heavily-constrained request, so a second hand-derived constant
        //    would be more surface than the named error is worth. It fails closed either way.
        Multicall[] memory calls = abi.decode(_slice(payload, 4, payload.length - 4), (Multicall[]));

        // ── gate 13 · between one and ten instructions. Bounds the loop below. ──
        uint256 count = calls.length;
        if (count == 0 || count > MAX_ACTIONS_PER_REQUEST) revert BatchSizeOutOfRange(count);

        address expectedCEA = cfg.expectedCEA;

        for (uint256 i; i < count;) {
            Multicall memory entry = calls[i];

            // ── gate 14 · no loopbacks, FIRST. The ordering is load-bearing: this runs BEFORE the
            //    allow-list, so the forbidden-destination-account rule BEATS the allow-list — even
            //    an owner who allow-listed their own destination account cannot hand the agent
            //    direct control of everything it holds. The list "redundantly" includes addresses
            //    other layers also block; three independent defences are the design and none may
            //    be removed as redundant.
            //    `account` is the WALLET: the engine passes its own msg.sender through as this
            //    parameter (PolicyLib.sol:220,236), so it is the wallet and never the engine.
            if (
                entry.to == account || entry.to == address(this) || entry.to == UNIVERSAL_GATEWAY_PC
                    || entry.to == expectedCEA
            ) {
                revert ForbiddenInnerTarget(entry.to);
            }
            if (entry.data.length < 4) revert MalformedInnerCalldata();

            // ── gate 15 · the allow-list, and for the user only. The only place in the entire
            //    system that checks the far-chain destination.
            AllowedCall memory rule = _requireAllowed(cfg, entry.to, bytes4(_slice(entry.data, 0, 4)));
            if (rule.hasBeneficiary) {
                // Offset comes from CONFIG, never from the request; the read is bounds-checked.
                address beneficiary = _extractBeneficiary(entry.data, rule.beneficiaryOffset);
                if (beneficiary != expectedCEA) revert BeneficiaryMismatch(expectedCEA, beneficiary);
            }

            // ── gate 16 · per-entry value cap, DESTINATION-chain native units. NEVER compared
            //    against the Push-side `value` — two assets on two chains. Conflating the two is
            //    a real bug this design once carried; the comment is here to stop its return.
            if (entry.value > rule.maxValue) revert InnerValueExceedsAllowance(i, entry.value, rule.maxValue);

            unchecked {
                ++i;
            }
        }
    }

    // ────────────────────────── the owner + credit paths ──────────────────────────

    /**
     * @notice Exact-equality assertion on the spend counter — the change-flow race guard.
     * @dev    Its role is as the FIRST entry of the owner's atomic change batch:
     *         assert → stopMandate(old) → grantMandate(new). Mismatch ⇒ the whole change reverts.
     *         Callable by anyone; it is a pure read.
     */
    function assertSpent(ConfigId id, address account, uint256 expectedSpent) external view {
        Config storage cfg = $configs[id][SESSION_ENGINE][account];

        // Without this, a typo'd or wrong config reads spent == 0 and an assertion of zero PASSES,
        // letting an atomic revoke-and-regrant proceed on a belief about a mandate that does not
        // exist. Reading zero from a ghost is indistinguishable from reading zero from a real
        // unused mandate — and this function exists precisely to catch stale belief, so it must
        // not have a silent-pass mode.
        if (!cfg.initialized) revert NotInitialized(id, account);

        // Exact equality. A credit landing between read and submit also forces recomposition —
        // stale beliefs never silently become new budgets in EITHER direction.
        if (cfg.spent != expectedSpent) revert SpentMismatch(expectedSpent, cfg.spent);
    }

    /**
     * @notice Credit a confirmed far-side failure back to the spend counter.
     * @dev    STATUS: DESIGNED AND SHIPPED, NOT YET FUNCTIONAL. The Universal Executor Module does
     *         not yet call anything on outbound failure — that is open work in Push core. Until it
     *         lands, a failed far leg leaves `spent` inflated; the remedy is revoke-and-regrant.
     * @dev    NO GAS COUNTER EXISTS AND NONE MAY EVER BE TOUCHED BY THIS PATH — gas consumed on a
     *         failed outbound was genuinely consumed, and is never credited back.
     */
    function creditRevert(ConfigId id, address account, bytes32 outboundTxId, uint256 amount) external {
        // One trusted caller; nobody else can fabricate a failure.
        if (msg.sender != UNIVERSAL_EXECUTOR_MODULE) revert NotExecutorModule(msg.sender);

        Config storage cfg = $configs[id][SESSION_ENGINE][account];

        // THE CONFIG IS CHECKED BEFORE IDEMPOTENCY IS WRITTEN — ordering is normative. Under the
        // reverse ordering a misrouted call burned the outboundTxId in $credited while crediting
        // nothing, making AlreadyCredited permanent and destroying that transaction's credit
        // forever. A misrouted credit must be RETRYABLE, not fatal.
        if (!cfg.initialized) revert NotInitialized(id, account);

        if ($credited[outboundTxId]) revert AlreadyCredited(outboundTxId);
        $credited[outboundTxId] = true;

        // Saturating — the counter never goes below zero. UCEP cannot verify `amount`; it is
        // trusted from Push core. Idempotency + saturation bound a wrong value (accepted residual).
        uint256 applied = cfg.spent > amount ? amount : cfg.spent;
        cfg.spent -= applied;

        // The amount actually APPLIED, not the amount claimed — that is what lets monitoring
        // detect a divergence between the two.
        emit RevertCredited(outboundTxId, id, account, applied);
    }

    // ───────────────────────────────── views ─────────────────────────────────

    /// @notice The full config including the allow-list, keyed on SESSION_ENGINE.
    function getConfig(ConfigId id, address account) external view returns (Config memory) {
        return $configs[id][SESSION_ENGINE][account];
    }

    /// @notice Exposes the idempotency set for monitoring.
    function isCredited(bytes32 outboundTxId) external view returns (bool) {
        return $credited[outboundTxId];
    }

    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return
            iid == type(IActionPolicy).interfaceId || iid == type(IPolicy).interfaceId
                || iid == type(IERC165).interfaceId;
    }

    // ─────────────────────────────── internals ───────────────────────────────

    /// @dev Reads the 32-byte word at `offset` and returns its low 20 bytes.
    ///      MUST bounds-check: reading past the end of a short calldata blob would
    ///      return adjacent memory and could be manipulated to pass the check.
    function _extractBeneficiary(bytes memory data, uint16 offset) internal pure returns (address) {
        if (uint256(offset) + 32 > data.length) revert MalformedInnerCalldata();
        bytes32 word;
        assembly {
            word := mload(add(add(data, 0x20), offset))
        }
        return address(uint160(uint256(word)));
    }

    /// @dev The (target, selector) pair must appear in the allow-list.
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

    /// @dev Memory slice helper.
    ///
    ///      THE BOUNDS BRANCH IS UNREACHABLE FROM THE THREE CALL SITES AND IS EXPECTED TO SHOW AS
    ///      UNCOVERED: gate 12 checks `payload.length < 4` before both payload slices, and gate 14
    ///      checks `entry.data.length < 4` before the inner one, so `start + len > data.length`
    ///      never holds. The guard stays because this is a `pure` helper whose safety must not
    ///      depend on every future caller remembering to check first.
    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        if (start + len > data.length) revert MalformedInnerCalldata();
        out = new bytes(len);
        // MCOPY requires evm_version = "cancun". Lowering the EVM target breaks this
        // silently at deploy time rather than loudly at compile time.
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), start), len)
        }
    }

    /// @dev Copy a decoded config into storage. `initialized` is NOT set here — the caller sets it
    ///      immediately after this returns, so this function has exactly one job.
    ///      `spent` is forced to zero; any value supplied by the caller is ignored.
    function _store(Config storage cfg, Config memory incoming) internal {
        cfg.validUntil = incoming.validUntil;
        cfg.destChainHash = incoming.destChainHash;
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
}
