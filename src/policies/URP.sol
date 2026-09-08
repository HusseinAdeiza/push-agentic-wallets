// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { IERC165 } from "forge-std/interfaces/IERC165.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IURP } from "../interfaces/IURP.sol";
import {
    UniversalOutboundTxRequest,
    Multicall,
    MULTICALL_SELECTOR,
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
    // slots 5..49  __gap
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

    /**
     * @dev Reserved so a later version can add state without shifting `$configs` or `$credited`.
     *
     *      Adding a variable means DECREMENTING this by exactly the number of slots consumed, in
     *      the same commit. A mapping or dynamic array costs one slot; a struct costs its packed
     *      size. `Config` itself lives inside a mapping, so APPENDING a field to that struct is
     *      safe and costs nothing here — reordering or removing one is not.
     */
    uint256[45] private __gap;

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
     *           per-call cap being a valid redeploy-only mandate), `destChainHash`,
     *           `beneficiaryOffset`, or allow-list contents. A wrong offset fails closed at
     *           validation time; it cannot widen a mandate, only break it. Offsets must be generated
     *           from each protocol's ABI by tooling rather than hand-typed, and each newly supported
     *           protocol must ship a test rejecting a wrong beneficiary and an oversized amount.
     *         - Anyone may call this with themselves as the multiplexer; that writes into their own
     *           keyed slice and the engine never reads it.
     *         - Writes the config, sets the initialised flag, and emits `URPPolicySet` and
     *           `PolicySet`.
     *
     * @param  account   The wallet this config belongs to.
     * @param  configId  Engine-derived id binding the account and the permission.
     * @param  initData  `abi.encode(Config)`.
     */
    function initializeWithMultiplexer(address account, ConfigId configId, bytes calldata initData) external {
        Config storage cfg = $configs[configId][msg.sender][account];

        if (cfg.initialized) revert AlreadyInitialized(configId);

        Config memory incoming = abi.decode(initData, (Config));

        uint256 listLength = incoming.allowedCalls.length;
        if (listLength == 0 || listLength > MAX_ALLOWED_CALLS) revert AllowListOutOfRange(listLength);

        if (incoming.validUntil == 0 || incoming.validUntil <= block.timestamp) {
            revert InvalidExpiry(incoming.validUntil);
        }
        if (incoming.asset == address(0) || incoming.expectedCEA == address(0)) revert InvalidConfigField();

        _store(cfg, incoming);
        cfg.initialized = true;

        emit URPPolicySet(configId, msg.sender, account);
        emit PolicySet(configId, msg.sender, account);
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
        Config storage cfg = $configs[id][SESSION_ENGINE][account];

        if (!cfg.initialized) revert NotInitialized(id, account);

        if (cfg.spent != expectedSpent) revert SpentMismatch(expectedSpent, cfg.spent);
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
     * @notice The full config including the allow-list, keyed on the session engine.
     * @param  id       Config id identifying the mandate.
     * @param  account  The wallet the mandate belongs to.
     * @return The stored config.
     */
    function getConfig(ConfigId id, address account) external view returns (Config memory) {
        return $configs[id][SESSION_ENGINE][account];
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
     * @dev Copies a decoded config into storage.
     *
     *      - Forces `spent` to zero, ignoring any value supplied by the caller.
     *      - Clears and repopulates the allow-list.
     *      - Does not set `initialized`; the caller does, immediately after this returns.
     *
     * @param cfg       Storage slot to write into.
     * @param incoming  Decoded config to copy from.
     */
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
