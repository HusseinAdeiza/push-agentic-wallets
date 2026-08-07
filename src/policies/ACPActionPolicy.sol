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
    uint16 beneficiaryOffset; // byte offset of the beneficiary word within the inner calldata
    bool hasBeneficiary; // false for calls with no beneficiary arg (e.g. approve)
    /// @dev Ceiling on this entry's native `value`, denominated in DESTINATION-chain
    ///      native token. Zero means no native value may be attached, which is correct
    ///      for every v1 target (all are non-payable). A future payable target — e.g.
    ///      the CEA attestation callback, which must fund an inbound protocol fee — is
    ///      then a config change rather than a contract change.
    uint256 maxValue;
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

    address public immutable UNIVERSAL_GATEWAY_PC;

    /// @dev configId => multiplexer (SmartSession) => account (wallet) => config
    mapping(ConfigId => mapping(address => mapping(address => Config))) internal $configs;

    event ACPPolicySet(ConfigId indexed id, address indexed multiplexer, address indexed account);

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

            // R7 — forbidden inner targets
            if (to == account || to == address(this) || to == UNIVERSAL_GATEWAY_PC) {
                revert ForbiddenInnerTarget(to);
            }
            if (calls[i].data.length < 4) revert MalformedInnerCalldata();
            bytes4 innerSel = bytes4(calls[i].data);

            // R8 + R9
            AllowedCall memory rule = _requireAllowed(cfg, to, innerSel);
            if (rule.hasBeneficiary) {
                address beneficiary = _extractBeneficiary(calls[i].data, rule.beneficiaryOffset);
                if (beneficiary != cfg.expectedCEA) {
                    revert BeneficiaryMismatch(cfg.expectedCEA, beneficiary);
                }
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
                return
                    AllowedCall(rule.target, rule.selector, rule.beneficiaryOffset, rule.hasBeneficiary, rule.maxValue);
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
            cfg.allowedCalls.push(incoming.allowedCalls[i]);
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
