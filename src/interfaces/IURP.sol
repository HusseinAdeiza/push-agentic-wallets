// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IActionPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

import { MandateType } from "../libraries/PushWalletTypes.sol";

/**
 * @dev Maximum pinned arguments per native action. Bounds the N7 loop.
 *
 *      FILE-LEVEL, NOT INSIDE THE INTERFACE — Solidity forbids variables in interfaces (solc 8274),
 *      and unlike `MAX_ACTIONS_PER_REQUEST` / `MAX_ALLOWED_CALLS` (which are `internal` to URP
 *      because they bound loops nobody off-chain constructs) this one bounds an array THE SDK
 *      BUILDS, so an encoder has to be able to see it. Parallel to `MULTICALL_SELECTOR` in
 *      `PushWalletTypes.sol`.
 */
uint256 constant MAX_PINS = 8;

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

    /**
     * @notice WIRE TYPE — what a UNIVERSAL envelope's body encodes. Not a storage type.
     *
     * @dev    ABSENT BY DESIGN, and each absence is the point: `initialized` (URP sets it), `spent`
     *         (URP owns it), and the chain (the envelope carries it, exactly once). The SDK used to
     *         type all three and URP overwrote them — a field whose only legal value is a
     *         placeholder is a field the caller fills in believing it matters.
     *
     *         Mapped field-by-field onto the storage `Config` by `_store`. The storage struct's
     *         layout never moves; this one is free to change with the wire format.
     */
    struct UniversalTerms {
        uint48 validUntil;
        address expectedCEA;
        address asset;
        uint256 maxAmountPerCall;
        uint256 maxAmountTotal;
        uint256 maxPCPerCall;
        AllowedCall[] allowedCalls;
    }

    /// @param initialized      set once, at initialisation; re-initialisation is refused
    /// @param validUntil       non-zero always (enforced at init); "never" = type(uint48).max, explicit
    /// @param destChainHash    v2 RELIC — slot 1, kept so the struct's layout never moves. Written by
    ///                         pre-envelope grants from the SDK's value; NEVER WRITTEN SINCE. The
    ///                         chain of every mandate, in both modes, is
    ///                         `getMode(id, account).chainHash`. Do not read this field; do not
    ///                         resurrect it as an input.
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

    // ───────────────────────── native mode structs ─────────────────────────

    /**
     * @dev Per-config mode record. THE MODE DISCRIMINATOR, and the reason it is a struct rather than
     *      a bare enum: `MandateType.UNIVERSAL` is the zero value, so an empty storage slot reads as
     *      `UNIVERSAL` and could not be told apart from a real universal mandate. `initialized` is
     *      authoritative; `mode` is MEANINGLESS when it is false.
     * @param initialized  true once either rulebook has been written for this config
     * @param mode         which rulebook; only meaningful when `initialized`
     */
    struct ModeSlot {
        bool initialized;
        MandateType mode;
        /// @dev keccak256(bytes(chain)) as declared in the policy envelope. THE single chain record
        ///      for BOTH modes — universal stores the destination chain, native stores this chain's
        ///      own hash. Zero on entries written before the envelope carried a chain; treat that as
        ///      "unverified", not as "no chain".
        bytes32 chainHash;
    }

    /**
     * @dev One pinned argument of a native call.
     * @param offset    ABSOLUTE byte offset from byte 0 of the calldata, SELECTOR INCLUDED — so 4 is
     *                  the first argument word, 36 the second, and so on.
     * @param expected  The full 32-byte word that must appear there. An address argument is
     *                  left-padded by the ABI, so a non-zero high half is a MISMATCH, deliberately:
     *                  full-word equality also proves the padding is clean, which masking would
     *                  silently accept.
     */
    struct ArgPin {
        uint16 offset;
        bytes32 expected;
    }

    /**
     * @dev Optional metering of a `uint256` argument read out of native calldata.
     * @param enabled     Whether to meter at all. A BOOL rather than "offset 0 means off", because
     *                    offset 0 is a legal position — it just points inside the selector.
     * @param offset      Absolute byte offset of the amount word, selector included.
     * @param maxPerCall  Per-call ceiling. Zero is legal (a call that must carry amount zero).
     * @param maxTotal    Lifetime ceiling; `type(uint256).max` = unlimited, with no special branch.
     */
    struct AmountRule {
        bool enabled;
        uint16 offset;
        uint256 maxPerCall;
        uint256 maxTotal;
    }

    /**
     * @dev The native rulebook for ONE (target, selector) action. One of these per action, so a
     *      mandate with eight actions holds eight of them under eight distinct config ids.
     *
     * @param initialized      set once; re-initialisation is refused, as in universal mode
     * @param validUntil       non-zero and future (enforced at init); "never" = type(uint48).max
     * @param target           defensive copy of the action target, asserted at N4
     * @param selector         defensive copy, asserted at N5. `0xFFFFFFFF` = value-only, which means
     *                         EMPTY calldata — a no-argument function still carries four bytes
     * @param maxValuePerCall  Push-native per-call ceiling
     * @param maxValueTotal    Push-native lifetime ceiling; type(uint256).max = unlimited
     * @param valueSpent       lifetime native value metered, written effects-last
     * @param amount           optional calldata-amount metering
     * @param amountSpent      lifetime metered amount, written effects-last
     * @param maxCalls         0 = unlimited; otherwise the lifetime call ceiling
     * @param callsUsed        calls consumed. ALWAYS increments on a successful check, including a
     *                         zero-value zero-amount call — a call is a use, and the alternative
     *                         makes `maxCalls` bypassable
     * @param pins             0..MAX_PINS pinned argument words
     */
    struct NativeConfig {
        bool initialized;
        uint48 validUntil;
        address target;
        bytes4 selector;
        uint256 maxValuePerCall;
        uint256 maxValueTotal;
        uint256 valueSpent;
        AmountRule amount;
        uint256 amountSpent;
        uint32 maxCalls;
        uint32 callsUsed;
        ArgPin[] pins;
    }

    /**
     * @notice WIRE TYPE — what a NATIVE envelope's body encodes. Not a storage type.
     *
     * @dev    ABSENT BY DESIGN: `initialized`, `valueSpent`, `amountSpent` and `callsUsed` are all
     *         URP's own counters, zeroed at init. The SDK had to type four zeroes it did not own.
     *
     *         SPLIT EVEN THOUGH ONLY THE UNIVERSAL SIDE FORCES IT. The SDK builds both; one struct
     *         with dead input fields sitting beside one without is precisely the inconsistency that
     *         let `destChainHash` acquire four different conventions in one repository.
     */
    struct NativeTerms {
        uint48 validUntil;
        address target;
        bytes4 selector;
        uint256 maxValuePerCall;
        uint256 maxValueTotal;
        AmountRule amount;
        uint32 maxCalls;
        ArgPin[] pins;
    }

    // ──────────────────────────────── events ────────────────────────────────

    /// @dev `mode` and `chainHash` are both DERIVED from the envelope's chain string, not declared.
    ///      For a universal config `chainHash` has additionally been verified against the asset's own
    ///      `SOURCE_CHAIN_NAMESPACE()`.
    event URPPolicySet(
        ConfigId indexed id, address indexed multiplexer, address indexed account, MandateType mode, bytes32 chainHash
    );
    /// @dev Emitted on every successful native check. Mirrors the effects: `value` and `amount` may
    ///      both be zero, and the event still fires, because `callsUsed` still moved.
    event NativeCallMetered(
        ConfigId indexed id, address indexed multiplexer, address indexed account, uint256 value, uint256 amount
    );
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

    // ───────────────────────── native mode errors ─────────────────────────
    //
    // DIAGNOSTIC VALUE FIRST. The engine truncates policy revert data to 32 bytes
    // (`PolicyLib.sol:145`), so a caller sees the 4-byte selector plus only the first 28 bytes of
    // the FIRST argument. Putting an index or a length first would surface 28 zero bytes and tell
    // nobody anything; putting the offending value first surfaces the thing you debug with.
    // This ordering applies to URP errors only — wallet errors are never truncated.

    // init
    //
    // NOT TRUNCATED. The 28-byte rule above applies to `checkAction`, which the engine wraps in
    // `PolicyCheckReverted`. `initializeWithMultiplexer` is a plain high-level call from
    // `ConfigLib.sol:98-101` inside `enableSessions`, so init reverts BUBBLE WITH FULL DATA. Tests
    // assert these with a plain `vm.expectRevert(abi.encodeWithSelector(...))` carrying every
    // argument — never `expectUrpGate`.

    /// @dev init: the envelope's `chain` string is empty. The only validation URP performs on the
    ///      string itself; a malformed non-empty string derives UNIVERSAL and is caught by the
    ///      asset check instead.
    error EmptyChain();

    /// @dev init, universal: the asset reports a different source chain than the envelope declares.
    ///      `declared` first because it is the value the owner can act on.
    error ChainMismatch(bytes32 declared, bytes32 assetChain);

    /// @dev init, universal: the asset has no code, is an EOA, or REVERTED when asked for
    ///      `SOURCE_CHAIN_NAMESPACE()`.
    ///
    ///      AN ASSET THAT *ANSWERS* WITH A NON-STRING, OR WITH NOTHING, REVERTS UNNAMED INSTEAD —
    ///      the returndata fails ABI decoding in URP's own frame, which `catch` does not see. The
    ///      no-code and EOA cases are named only because an explicit `code.length` guard runs first;
    ///      since solc 0.8.10 the compiler omits the `extcodesize` check when return data is
    ///      expected, so `try/catch` alone would let both through as unnamed reverts. Measured.
    error InvalidAsset(address asset);
    /// @dev init: native config with a zero target.
    error NativeTargetZero();
    /// @dev init AND gate N3. A native config may never name the gateway, and a native config may
    ///      never be reached by a gateway-targeted request. The mirror of universal gate 3.
    error NativeTargetIsGateway(address target);
    /// @dev init: a value-only config (`selector == 0xFFFFFFFF`) carrying pins. Refused rather than
    ///      left to fail closed at N7: such a config can NEVER authorise anything, so it is a
    ///      misconfiguration the owner believes they granted, not a valid ascetic config.
    error ValueOnlyWithPins();
    /// @dev init: a value-only config carrying an amount rule. Same reasoning.
    error ValueOnlyWithAmountRule();
    /// @dev init: pins.length > MAX_PINS.
    error TooManyPins(uint256 count);

    // check
    error TargetMismatch(address actual, address expected);
    error SelectorMismatch(bytes4 actual, bytes4 expected);
    /// @dev N5: a value-only action carrying 1..3 bytes of calldata. The engine buckets those under
    ///      `VALUE_SELECTOR` too; URP is where "value-only means empty calldata" becomes true.
    error ValueOnlyCalldataNotEmpty(uint256 length);
    error ValueExceedsCap(uint256 value, uint256 cap);
    error TotalValueExceeded(uint256 newSpent, uint256 cap);
    error CalldataTooShortForPin(uint256 actualLength, uint256 index, uint256 needed);
    error ArgPinMismatch(bytes32 actual, uint256 index, bytes32 expected);
    error CalldataTooShortForAmount(uint256 actualLength, uint256 needed);
    error NativeAmountExceedsCap(uint256 amount, uint256 cap);
    error TotalNativeAmountExceeded(uint256 newSpent, uint256 cap);
    error CallLimitReached(uint32 callsUsed, uint32 maxCalls);

    // views / assertions
    /// @dev A getter or assertion was called against the wrong rulebook — `getConfig` on a native
    ///      slot, or the five-argument `assertSpent` on a universal one. Carries the mode the config
    ///      ACTUALLY is. An EMPTY slot is not this error: it returns a zeroed struct exactly as
    ///      before, because an empty slot is a state while a wrong-mode read is a caller bug.
    error WrongModeForCall(MandateType actual);

    // ───────────────────────────── v3 additions ─────────────────────────────

    /// @notice Exact-equality assertion on the spend counter — the change-flow race guard.
    /// @dev    Keyed on the SESSION_ENGINE immutable; there is no multiplexer argument to get wrong.
    function assertSpent(ConfigId id, address account, uint256 expectedSpent) external view;

    /// @notice Credit a confirmed far-side failure back to the spend counter.
    /// @dev    Executor-module-only, once per outboundTxId, saturating. Ships inert — Push core's
    ///         calling side is not yet landed.
    function creditRevert(ConfigId id, address account, bytes32 outboundTxId, uint256 amount) external;

    // ───────────────────────────────── views ─────────────────────────────────

    /// @notice The universal config. Reverts `WrongModeForCall(NATIVE)` on a native slot; returns a
    ///         zeroed struct on an EMPTY slot, exactly as it always has.
    function getConfig(ConfigId id, address account) external view returns (Config memory);

    /// @notice The native config. Reverts `WrongModeForCall(UNIVERSAL)` on a universal slot; returns
    ///         a zeroed struct on an empty slot.
    function getNativeConfig(ConfigId id, address account) external view returns (NativeConfig memory);

    /// @notice The mode record. NEVER REVERTS — the documented first call for any integrator that
    ///         does not already know a mandate's mode. An empty slot returns
    ///         `(initialized: false, mode: UNIVERSAL, chainHash: 0)`, where the mode value is
    ///         meaningless. A `chainHash` of zero on an INITIALISED entry means the config predates
    ///         the envelope carrying a chain — unverified, not "no chain".
    function getMode(ConfigId id, address account) external view returns (ModeSlot memory);

    /// @notice The hash this URP derives NATIVE from: `keccak256("eip155:" ‖ decimal(block.chainid))`.
    /// @dev    Exposed so the deploy script asserts what URP will ACTUALLY derive rather than
    ///         recomputing the formula and agreeing with itself, and so an SDK can confirm the exact
    ///         native chain string it should emit. Computed, never stored.
    function pushChainHash() external view returns (bytes32);

    /// @notice The native change-flow race guard: exact equality on all three counters.
    /// @dev    Reverts `WrongModeForCall(UNIVERSAL)` on a universal config and `NotInitialized` on a
    ///         ghost, for the same reason the universal overload does — this exists to catch stale
    ///         belief, so it must not have a silent-pass mode.
    function assertSpent(
        ConfigId id,
        address account,
        uint256 expectedValueSpent,
        uint256 expectedAmountSpent,
        uint32 expectedCalls
    ) external view;

    function isCredited(bytes32 outboundTxId) external view returns (bool);
}
