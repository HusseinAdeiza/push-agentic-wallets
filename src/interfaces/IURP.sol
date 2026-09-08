// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

/**
 * @title  IURP — the Universal Rules Policy's v3 surface.
 * @notice The engine-facing functions (`initializeWithMultiplexer`, `checkAction`) and
 *         `supportsInterface` are INHERITED from upstream `IActionPolicy`, never repeated here.
 *         Duplicating a signature across a trust boundary is the drift this project removes.
 *
 * @dev    INHERITANCE SHAPE, verified by compiled probe. `IActionPolicy is IPolicy is IERC165`,
 *         so IERC165 already arrives transitively and listing it again as
 *         `is IActionPolicy, IERC165` fails with `Error (5005): Linearization of inheritance
 *         graph impossible` — C3 linearization requires the most-derived base first. Single
 *         inheritance is both correct and sufficient; do not "complete" it by adding IERC165.
 *
 * @dev    Revert data truncates to 32 bytes through the engine (`PolicyLib.sol:139-152`,
 *         `_maxCopy: 32`, surfacing as `PolicyCheckReverted(bytes32)`). The 4-byte selector
 *         survives; multi-argument custom errors do not round-trip to the caller. Errors below
 *         still carry their arguments because URP is also called directly (owner path,
 *         executor module) where they do survive.
 */
interface IURP is IActionPolicy {
    // ──────────────────────────────── structs ────────────────────────────────

    /// @param target            far-chain contract
    /// @param selector          far-chain function
    /// @param beneficiaryOffset byte offset of the beneficiary word in the inner calldata
    /// @param hasBeneficiary    false for calls with no beneficiary argument
    /// @param maxValue          per-entry native ceiling, DESTINATION-chain units (0 = non-payable)
    struct AllowedCall {
        address target;
        bytes4 selector;
        uint16 beneficiaryOffset;
        bool hasBeneficiary;
        uint256 maxValue;
    }

    /// @param initialized      set once, at initialisation; re-initialisation is refused
    /// @param validUntil       non-zero always (enforced at init); "never" = type(uint48).max, explicit
    /// @param destChainHash    stored, NOT enforced. The destination chain is already pinned
    ///                         transitively by the asset, so this field exists for SDK assertions
    ///                         and indexing only — never as a gate.
    /// @param expectedCEA      the wallet's destination account, committed at grant
    /// @param asset            the one permitted PRC20
    /// @param maxAmountTotal   type(uint256).max = unlimited
    /// @param maxPCPerCall     Push-native per-call ceiling (protocol fee + gas swap budget)
    /// @param spent            lifetime BRIDGED, recorded before dispatch
    struct Config {
        bool initialized;
        uint48 validUntil;
        bytes32 destChainHash;
        address expectedCEA;
        address asset;
        uint256 maxAmountPerCall;
        uint256 maxAmountTotal;
        uint256 maxPCPerCall;
        uint256 spent;
        AllowedCall[] allowedCalls;
    }

    // ──────────────────────────────── events ────────────────────────────────

    event URPPolicySet(ConfigId indexed id, address indexed multiplexer, address indexed account);
    event OutboundMetered(ConfigId indexed id, address indexed multiplexer, address indexed account, uint256 amount);
    event RevertCredited(
        bytes32 indexed outboundTxId, ConfigId indexed id, address indexed account, uint256 amountApplied
    );

    // ──────────────────────────────── errors ────────────────────────────────

    error ZeroAddress();
    error NotInitialized(ConfigId id, address account);
    error AlreadyInitialized(ConfigId id);
    /// @dev init: zero, or not in the future.
    error InvalidExpiry(uint48 validUntil);
    /// @dev init: zero asset or zero expectedCEA.
    error InvalidConfigField();
    /// @dev init: 0 or > MAX_ALLOWED_CALLS.
    error AllowListOutOfRange(uint256 length);
    error MandateExpired(uint48 validUntil);
    error InvalidTarget(address target);
    /// @dev Gate 4a. Distinct from InvalidSelector: there is no selector to report, and a zero
    ///      sentinel would be indistinguishable from a genuine all-zero-selector payload.
    error CalldataTooShort(uint256 length);
    error InvalidSelector(bytes4 selector);
    /// @dev Gate 4c — body below MIN_OUTBOUND_BODY_LEN.
    error MalformedOutboundRequest(uint256 length);
    error AssetMismatch(address expected, address actual);
    error AmountExceedsCap(uint256 amount, uint256 cap);
    error TotalSpendCapExceeded(uint256 wouldBeTotal, uint256 cap);
    error PCValueExceedsCap(uint256 value, uint256 cap);
    error UncappedGasSwapRejected();
    error InvalidRevertRecipient(address expected, address actual);
    error RecipientMustBeEmpty();
    error PayloadNotMulticall();
    error BatchSizeOutOfRange(uint256 count);
    error ForbiddenInnerTarget(address target);
    error CallNotAllowed(address target, bytes4 selector);
    error BeneficiaryMismatch(address expected, address actual);
    error InnerValueExceedsAllowance(uint256 index, uint256 value, uint256 maxValue);
    error MalformedInnerCalldata();
    error SpentMismatch(uint256 expected, uint256 actual);
    error NotExecutorModule(address caller);
    error AlreadyCredited(bytes32 outboundTxId);

    // ───────────────────────────── v3 additions ─────────────────────────────

    /// @notice Exact-equality assertion on the spend counter — the change-flow race guard.
    /// @dev    Keyed on the SESSION_ENGINE immutable; there is no multiplexer argument to get wrong.
    function assertSpent(ConfigId id, address account, uint256 expectedSpent) external view;

    /// @notice Credit a confirmed far-side failure back to the spend counter.
    /// @dev    Executor-module-only, once per outboundTxId, saturating. Ships inert — Push core's
    ///         calling side is not yet landed.
    function creditRevert(ConfigId id, address account, bytes32 outboundTxId, uint256 amount) external;

    // ───────────────────────────────── views ─────────────────────────────────

    function getConfig(ConfigId id, address account) external view returns (Config memory);

    function isCredited(bytes32 outboundTxId) external view returns (bool);
}
