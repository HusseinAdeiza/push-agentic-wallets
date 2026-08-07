// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { UniversalOutboundTxRequest, Multicall } from "../libraries/PushWalletTypes.sol";

uint256 constant VALIDATION_SUCCESS = 0;

/// @notice One permitted inner call within the cross-chain multicall payload.
struct AllowedCall {
    address target; // e.g. Morpho Blue pool on Ethereum
    bytes4 selector; // e.g. supply(...)
    uint16 beneficiaryOffset; // byte offset of the pinned address word within the inner calldata
    bool hasBeneficiary; // false only for calls with no address argument worth pinning
    /// @dev Ceiling on this entry's native `value`, denominated in DESTINATION-chain
    ///      native token. Zero means no native value may be attached, which is correct
    ///      for every v1 target (all are non-payable). A future payable target — e.g.
    ///      the CEA attestation callback, which must fund an inbound protocol fee — is
    ///      then a config change rather than a contract change.
    uint256 maxValue;
    /// @dev R9-ext (A-15). The address the word at `beneficiaryOffset` MUST equal.
    ///
    ///      `address(0)` is a SENTINEL meaning "the wallet's own CEA", which preserves the
    ///      original semantics for every deposit-style entry (supply / withdraw / repay)
    ///      unchanged — those must land in the user's own CEA.
    ///
    ///      A non-zero value pins the argument to that exact address, which is what an
    ///      ERC-20 `approve` spender needs: it must be the PROTOCOL, never the CEA. Without
    ///      this, an approve entry could only ship with `hasBeneficiary = false` and its
    ///      spender was completely unchecked — see CV-1.
    address expectedArg;
}

/// @notice Per-(configId, multiplexer, account) mandate configuration.
struct Config {
    bool initialized;
    /// @dev NOT ENFORCED ON-CHAIN. The destination chain is pinned transitively by
    ///      `asset` (R4) — UniversalGatewayPC derives the destination from the PRC20,
    ///      and P-05 pins that dependency. This field is asserted by the SDK at grant
    ///      time and exists for off-chain verification and event indexing only.
    bytes32 destChainHash;
    address expectedCEA; // D-13 — committed at grant time
    address asset; // PRC20 token permitted as req.token
    /// @dev Per-call ceiling. Bounds single-transaction blast radius: without it a
    ///      compromised key drains the whole mandate in ONE transaction, before any
    ///      monitor can react. Deliberately redundant with `maxAmountTotal`.
    uint256 maxAmountPerCall;
    /// @dev Cumulative mandate ceiling across the session's whole lifetime.
    uint256 maxAmountTotal;
    /// @dev Ceiling on the PUSH CHAIN native value forwarded to the gateway on each
    ///      call — the protocol fee plus the destination-gas swap budget.
    ///
    ///      Distinct from `AllowedCall.maxValue`, which bounds DESTINATION-chain native
    ///      value on inner entries. Without this, a session key could drain the wallet's
    ///      PC balance through repeated zero-amount (GAS_AND_PAYLOAD) outbounds: the
    ///      gateway takes `protocolFee` from msg.value unconditionally but skips
    ///      `_burnPRC20` when `req.amount == 0`, so the amount caps never see it.
    uint256 maxPCPerCall;
    /// @dev Running total of `req.amount` authorised so far. Reset on re-initialization.
    uint256 spent;
    AllowedCall[] allowedCalls; // exhaustive allowlist of inner multicall entries
}

/**
 * @title  ACPActionPolicy
 * @notice An IActionPolicy that authorises exactly one action: the wallet calling
 *         `UniversalGatewayPC.sendUniversalTxOutbound`. It decodes the outbound
 *         request, walks the nested multicall payload, and enforces that every
 *         inner call is permitted and that the beneficiary of any deposit is the
 *         wallet's own CEA (PRD §8).
 *
 * @dev    This contract is the security boundary that makes provider custody
 *         structurally impossible.
 */
contract ACPActionPolicy is IActionPolicy {
    /// @dev bytes4(keccak256("UEA_MULTICALL")) — must match Push Chain Types.sol
    bytes4 public constant MULTICALL_SELECTOR = bytes4(keccak256("UEA_MULTICALL"));

    bytes4 public constant SEND_OUTBOUND_SELECTOR =
        bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

    /// @dev ERC-20 approval selectors for CV-1, hardcoded rather than imported.
    ///      `IERC20.approve.selector` would work, but `increaseAllowance` has never been
    ///      part of OpenZeppelin's `IERC20` interface — it lived on the ERC20
    ///      implementation and was removed in OZ v5 — so importing would cover only one
    ///      of the two and leave them asymmetric. Hardcoding both keeps the pair
    ///      symmetric and drops the dependency. Recomputed from their signatures by T-67:
    ///      a hardcoded magic value in a security check must always carry a drift test.
    bytes4 internal constant APPROVE_SELECTOR = 0x095ea7b3; // approve(address,uint256)
    bytes4 internal constant INCREASE_ALLOWANCE_SELECTOR = 0x39509351; // increaseAllowance(address,uint256)

    address public immutable UNIVERSAL_GATEWAY_PC;

    /// @dev configId => multiplexer (SmartSession) => account (wallet) => config
    mapping(ConfigId => mapping(address => mapping(address => Config))) internal $configs;

    event ACPPolicySet(ConfigId indexed id, address indexed multiplexer, address indexed account);

    /// @notice F-11 — emitted for every authorised action. `payloadHash` joins to the
    ///         `subTxId` preimage, so an indexer can attribute a destination-chain
    ///         execution back to the exact mandate config that permitted it.
    event MandateActionAuthorized(
        ConfigId indexed configId, address indexed account, bytes32 payloadHash, uint256 amount
    );

    error NotInitialized(ConfigId id, address multiplexer, address account);
    error InvalidTarget(address target);
    error InvalidSelector(bytes4 selector);
    error AssetMismatch(address expected, address actual);
    error AmountExceedsCap(uint256 amount, uint256 cap);
    error TotalSpendCapExceeded(uint256 wouldBeTotal, uint256 cap);
    error PCValueExceedsCap(uint256 value, uint256 cap);
    error ZeroAmountNotPermitted();
    error InnerValueExceedsAllowance(uint256 index, uint256 value, uint256 maxValue);
    error PayloadNotMulticall();
    error ForbiddenInnerTarget(address target);
    error CallNotAllowed(address target, bytes4 selector);
    error BeneficiaryMismatch(address expected, address actual);
    error InvalidRevertRecipient(address expected, address actual);
    error MalformedInnerCalldata();
    /// @dev R14 — the destination recipient must be empty on the session path.
    error NonEmptyRecipient(uint256 length);
    /// @dev CV-1 (A-15) — an approval-shaped entry whose spender is not pinned.
    error UnpinnedApprovalEntry(address target, bytes4 selector);
    /// @dev CV-2 — a config committing a zero CEA, which would collapse R9-ext's sentinel.
    error ZeroExpectedCEA();

    constructor(address universalGatewayPC_) {
        UNIVERSAL_GATEWAY_PC = universalGatewayPC_;
    }

    /// @notice Initialize (or overwrite) the mandate config for an account.
    /// @dev    Per IPolicy doc: MAY be called again without deinit; MUST overwrite.
    function initializeWithMultiplexer(address account, ConfigId configId, bytes calldata initData) external override {
        Config storage cfg = $configs[configId][msg.sender][account];
        Config memory incoming = abi.decode(initData, (Config));
        _store(cfg, incoming);
        cfg.initialized = true;
        emit ACPPolicySet(configId, msg.sender, account);
        emit PolicySet(configId, msg.sender, account);
    }

    /**
     * @notice Authorise a single action the wallet is about to perform.
     *
     * @dev Not `view` — `IActionPolicy` declares this state-mutating precisely so
     *      policies can accumulate. We use that for the cumulative spend cap (R5b).
     *
     * @dev ACCUMULATION IS OPTIMISTIC BUT ATOMIC. `spent` is incremented during
     *      *validation*, before execution. If execution later reverts, the increment
     *      reverts with it — but ONLY because validation and execution happen in one
     *      transaction. A future maintainer who splits them across transactions would
     *      silently break this accounting.
     *
     * @dev SmartSession invokes policies with a real `call` (PolicyLib.callPolicy uses
     *      excessivelySafeCall, not staticcall), so these writes genuinely persist.
     *
     * @dev No griefing vector via the open `executeWithSession`: a replayed signature
     *      carries a stale `nonceSeq` and reverts at the nonce gate before reaching
     *      this function, so a third party cannot burn mandate budget (see S-04).
     *
     * @dev REVERT DATA IS TRUNCATED. PolicyLib copies at most 32 bytes of revert data
     *      and rewraps it as `PolicyCheckReverted(bytes32)`. The 4-byte selector
     *      survives; multi-argument errors such as `BeneficiaryMismatch(address,address)`
     *      do NOT round-trip to the caller.
     */
    function checkAction(ConfigId id, address account, address target, uint256 value, bytes calldata data)
        external
        override
        returns (uint256)
    {
        Config storage cfg = $configs[id][msg.sender][account];
        if (!cfg.initialized) revert NotInitialized(id, msg.sender, account); // R1

        if (target != UNIVERSAL_GATEWAY_PC) revert InvalidTarget(target); // R2
        if (data.length < 4) revert InvalidSelector(bytes4(0));
        if (bytes4(data[0:4]) != SEND_OUTBOUND_SELECTOR) {
            revert InvalidSelector(bytes4(data[0:4])); // R3
        }

        UniversalOutboundTxRequest memory req = abi.decode(data[4:], (UniversalOutboundTxRequest));

        if (req.token != cfg.asset) revert AssetMismatch(cfg.asset, req.token); // R4

        // R14 — the destination recipient must be empty.
        //
        // SESSION PATH ONLY (Q5). `checkAction` never runs on the owner path, and the
        // owner path DELIBERATELY permits a non-empty recipient: FUNDS-type withdrawals to
        // an external address and exit-leg composition depend on it. Do NOT "harden"
        // `execute()` with this rule — it would break owner withdrawals.
        //
        // bytes("") is the gateway's own documented "park funds in the caller's CEA"
        // convention, so this is the canonical encoding, not a hack. It is also a
        // FAIL-CLOSED backstop for R6 (P-4): if the multicall prefix check were ever
        // bypassed, `CEA._handleSingleCall` would receive recipient == address(0) with a
        // non-empty payload and revert `CEAErrors.InvalidRecipient()` (CEA.sol:237)
        // instead of executing `recipient.call{value: msg.value}(payload)` — which would
        // be direct theft (A-02).
        if (req.recipient.length != 0) revert NonEmptyRecipient(req.recipient.length);

        // R13 — zero-amount outbounds are rejected outright.
        //
        // With `req.amount == 0` the gateway infers TX_TYPE.GAS_AND_PAYLOAD and skips
        // `_burnPRC20`, so `spent` never increases and the cumulative cap is
        // STRUCTURALLY BLIND to the call — while `protocolFee` is still taken from
        // msg.value. Rejecting the shape closes that class rather than merely capping
        // it. The v1 lending flow always carries a non-zero amount; revisit only if a
        // CEA-balance-only flow is ever required.
        if (req.amount == 0) revert ZeroAmountNotPermitted();

        if (req.amount > cfg.maxAmountPerCall) {
            revert AmountExceedsCap(req.amount, cfg.maxAmountPerCall); // R5
        }

        // R5b — cumulative mandate ceiling. Solidity 0.8.x reverts on overflow.
        uint256 newSpent = cfg.spent + req.amount;
        if (newSpent > cfg.maxAmountTotal) {
            revert TotalSpendCapExceeded(newSpent, cfg.maxAmountTotal);
        }

        // R12 — ceiling on the PUSH CHAIN native value forwarded to the gateway.
        // Defence in depth with R13: bounds the per-call PC outflow even for the
        // non-zero-amount shapes that R13 permits.
        if (value > cfg.maxPCPerCall) revert PCValueExceedsCap(value, cfg.maxPCPerCall);

        if (req.revertRecipient != account) {
            revert InvalidRevertRecipient(account, req.revertRecipient); // R10
        }

        _validateMulticallPayload(cfg, account, req.payload); // R6–R9, R11

        // EFFECTS LAST — every check above has passed before any state is written.
        cfg.spent = newSpent;

        // F-11 — attribution. The contract that AUTHORIZED the action names the config
        // that authorized it, with zero gateway footprint (P-6: the outbound stays
        // byte-indistinguishable from an ordinary UEA outbound).
        //
        // Why the event cannot outlive a failed op (Q11): if any later policy in the
        // intersection returns VALIDATION_FAILED, the failed bit propagates through
        // `vd.intersect` and the wallet's own `_requireValidationData` reverts
        // `SignatureValidationFailed` — the whole transaction reverts and this emit is
        // erased, because events are transaction state. A policy that REVERTS becomes
        // `PolicyCheckReverted`; execution failure bubbles. Same outcome in all three.
        // So: event present in a mined tx ⟹ every policy passed AND the gateway call
        // executed, including the ACP-passes-then-ValueLimit-fails case.
        emit MandateActionAuthorized(id, account, keccak256(req.payload), req.amount);

        return VALIDATION_SUCCESS;
    }

    function supportsInterface(bytes4 iid) external pure returns (bool) {
        return
            iid == type(IActionPolicy).interfaceId || iid == type(IPolicy).interfaceId
                || iid == type(IERC165).interfaceId;
    }

    /// @notice Read back a stored config (for tests and off-chain verification).
    function getConfig(ConfigId id, address multiplexer, address account)
        external
        view
        returns (
            bool initialized,
            bytes32 destChainHash,
            address expectedCEA,
            address asset,
            uint256 maxAmountPerCall,
            uint256 maxAmountTotal,
            uint256 maxPCPerCall,
            uint256 spent,
            AllowedCall[] memory allowedCalls
        )
    {
        Config storage cfg = $configs[id][multiplexer][account];
        return (
            cfg.initialized,
            cfg.destChainHash,
            cfg.expectedCEA,
            cfg.asset,
            cfg.maxAmountPerCall,
            cfg.maxAmountTotal,
            cfg.maxPCPerCall,
            cfg.spent,
            cfg.allowedCalls
        );
    }

    // ==============================
    //          INTERNALS
    // ==============================

    /**
     * @dev Walks the nested multicall payload enforcing R6–R9 and R11.
     *
     *      ⚠ R7 — forbidding `to == account` stops a session key routing a call back
     *      into the wallet to reach `installModule`. A-04 has three independent
     *      defences: SmartSession's own `InvalidSelfCall` check, this rule, and the
     *      wallet's `onlyOwner` modifier. R7 MUST NOT be removed as "redundant" — it
     *      must not depend on either of the others for its safety property.
     */
    function _validateMulticallPayload(Config storage cfg, address account, bytes memory payload) internal view {
        if (payload.length < 4) revert PayloadNotMulticall();
        bytes4 sel;
        assembly {
            sel := mload(add(payload, 0x20))
        }
        if (sel != MULTICALL_SELECTOR) revert PayloadNotMulticall(); // R6

        bytes memory inner = _slice(payload, 4, payload.length - 4);
        Multicall[] memory calls = abi.decode(inner, (Multicall[]));

        for (uint256 i; i < calls.length;) {
            address to = calls[i].to;

            // R7 — forbidden inner targets.
            //
            // The first three are defence-in-depth for A-04 and MUST be retained.
            // `cfg.expectedCEA` is the load-bearing v2 addition (A-03, P-5): an inner entry
            // targeting the CEA executes with `msg.sender == CEA`, which SATISFIES
            // `CEA.sendUniversalTxToUEA`'s self-call check (CEA.sol:114), and
            // `CEA._handleMulticall` explicitly permits value-0 self-calls (CEA.sol:196).
            // The inner CEA self-call IS the exit mechanism — it would let a compromised
            // key bridge value out with an agent-controlled `revertRecipient`. Sessions are
            // ENTRY-ONLY in v2.0 (P-5); exits are owner-path.
            if (to == account || to == address(this) || to == UNIVERSAL_GATEWAY_PC || to == cfg.expectedCEA) {
                revert ForbiddenInnerTarget(to);
            }
            if (calls[i].data.length < 4) revert MalformedInnerCalldata();
            bytes4 innerSel = bytes4(calls[i].data);

            // R8 + R9 / R9-ext
            AllowedCall memory rule = _requireAllowed(cfg, to, innerSel);
            if (rule.hasBeneficiary) {
                // R9-ext (A-15) — `expectedArg == address(0)` is the sentinel for "the
                // wallet's own CEA", preserving deposit-entry semantics. A non-zero value
                // pins the argument exactly, which is what an approve spender requires.
                address expected = rule.expectedArg == address(0) ? cfg.expectedCEA : rule.expectedArg;
                address actual = _extractBeneficiary(calls[i].data, rule.beneficiaryOffset);
                if (actual != expected) revert BeneficiaryMismatch(expected, actual);
            }

            // R11 — per-entry native value ceiling, denominated in DESTINATION-chain
            // native token. The previous rule summed these and compared against the
            // Push Chain `value` forwarded to the gateway: two different assets on two
            // different chains, so the comparison was meaningless (and a silent no-op,
            // since ERC-20 flows carry value == 0 on every entry).
            if (calls[i].value > rule.maxValue) {
                revert InnerValueExceedsAllowance(i, calls[i].value, rule.maxValue);
            }

            unchecked {
                ++i;
            }
        }
    }

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

    /// @dev R8 — the (target, selector) pair must appear in the allowlist.
    function _requireAllowed(Config storage cfg, address to, bytes4 selector)
        internal
        view
        returns (AllowedCall memory)
    {
        uint256 len = cfg.allowedCalls.length;
        for (uint256 i; i < len;) {
            AllowedCall storage rule = cfg.allowedCalls[i];
            if (rule.target == to && rule.selector == selector) {
                // NAMED-FIELD construction, deliberately (N2). Solidity requires every
                // field to be present in named form, so adding a field to `AllowedCall`
                // later breaks the build here instead of silently defaulting the new field
                // to zero. For a struct where a zero field can mean "check disabled", that
                // is the difference between a loud failure and a silent one.
                return AllowedCall({
                    target: rule.target,
                    selector: rule.selector,
                    beneficiaryOffset: rule.beneficiaryOffset,
                    hasBeneficiary: rule.hasBeneficiary,
                    maxValue: rule.maxValue,
                    expectedArg: rule.expectedArg
                });
            }
            unchecked {
                ++i;
            }
        }
        revert CallNotAllowed(to, selector);
    }

    /// @dev Copy a decoded config into storage, replacing any prior allowlist.
    ///      `spent` is RESET to zero: `initializeWithMultiplexer` represents a fresh
    ///      grant by the owner, so carrying a stale counter forward would either brick
    ///      a new mandate or silently preserve a cap the owner meant to reset.
    ///      Any value supplied in `incoming.spent` is deliberately ignored.
    function _store(Config storage cfg, Config memory incoming) internal {
        // CV-2 (L-2) — the committed CEA must be a real address.
        //
        // `AllowedCall.expectedArg == address(0)` is the R9-ext SENTINEL for "the wallet's
        // own CEA", so every deposit-style entry resolves its pin through `cfg.expectedCEA`.
        // If that field were itself zero the sentinel would collapse: R9-ext would compare
        // the extracted beneficiary against address(0), and an inner
        // `supply(..., onBehalf = 0, ...)` would pass the beneficiary check entirely.
        //
        // Same reasoning as CV-1: the SDK is supposed to commit a correct CEA (S-8), but
        // "supposed to" is not a guarantee. P-7 — validate on-chain at grant time what the
        // SDK could otherwise get silently wrong.
        if (incoming.expectedCEA == address(0)) revert ZeroExpectedCEA();

        cfg.destChainHash = incoming.destChainHash;
        cfg.expectedCEA = incoming.expectedCEA;
        cfg.asset = incoming.asset;
        cfg.maxAmountPerCall = incoming.maxAmountPerCall;
        cfg.maxAmountTotal = incoming.maxAmountTotal;
        cfg.maxPCPerCall = incoming.maxPCPerCall;
        cfg.spent = 0;

        delete cfg.allowedCalls;
        uint256 len = incoming.allowedCalls.length;
        for (uint256 i; i < len;) {
            AllowedCall memory entry = incoming.allowedCalls[i];

            // CV-1 (A-15, F-29) — config-time validation. Runs once per grant; zero
            // hot-path gas.
            //
            // Without it, an ERC-20 approval entry could ship with
            // `hasBeneficiary = false` and its spender COMPLETELY UNCHECKED. A compromised
            // key then bridges 1 wei (satisfying R13) carrying an inner
            // `USDC.approve(attacker, type(uint256).max)` and drains the CEA directly on
            // the destination chain via `transferFrom`. The approve entry is MANDATORY for
            // any Aave/Morpho flow, so this was not hypothetical.
            //
            // P-7 applied: the pin is now a contract guarantee, not SDK discipline. The
            // mis-configured shape is UNREPRESENTABLE — and because this guard lives in the
            // policy rather than the wallet, it fires identically via `grantMandate`,
            // `reconfigureMandate`, and the `callValidator(enableSessions)` escape hatch.
            //
            // A GENERAL rule is impossible: ACP cannot know which argument of an arbitrary
            // selector grants authority (`permit`, `setAuthorizationWithSig`,
            // `setApprovalForAll` all differ). That exotic class stays S-10's job.
            if (entry.selector == APPROVE_SELECTOR || entry.selector == INCREASE_ALLOWANCE_SELECTOR) {
                if (!entry.hasBeneficiary || entry.beneficiaryOffset != 4 || entry.expectedArg == address(0)) {
                    revert UnpinnedApprovalEntry(entry.target, entry.selector);
                }
            }

            cfg.allowedCalls.push(entry);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Memory slice helper.
    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        if (start + len > data.length) revert MalformedInnerCalldata();
        out = new bytes(len);
        // MCOPY requires evm_version = "cancun". Lowering the EVM target breaks this
        // silently at deploy time rather than loudly at compile time — see README.
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(data, 0x20), start), len)
        }
    }
}
