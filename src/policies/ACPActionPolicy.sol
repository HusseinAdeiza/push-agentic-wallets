// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IActionPolicy, IPolicy } from "smartsessions/interfaces/IPolicy.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { UniversalOutboundTxRequest, Multicall } from "../libraries/PushWalletTypes.sol";

uint256 constant VALIDATION_SUCCESS = 0;
uint256 constant VALIDATION_FAILED = 1;

/// @notice One permitted inner call within the cross-chain multicall payload.
struct AllowedCall {
    address target; // e.g. Morpho Blue pool on Ethereum
    bytes4 selector; // e.g. supply(...)
    uint16 beneficiaryOffset; // byte offset of the beneficiary word within the inner calldata
    bool hasBeneficiary; // false for calls with no beneficiary arg (e.g. approve)
}

/// @notice Per-(configId, multiplexer, account) mandate configuration.
struct Config {
    bool initialized;
    bytes32 destChainHash; // keccak256("eip155:1")
    address expectedCEA; // D-13 — committed at grant time
    address asset; // PRC20 token permitted as req.token
    uint256 maxAmountPerCall; // ceiling on req.amount
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
    error AlreadyInitialized(ConfigId id, address multiplexer, address account);
    error InvalidTarget(address target);
    error InvalidSelector(bytes4 selector);
    error AssetMismatch(address expected, address actual);
    error AmountExceedsCap(uint256 amount, uint256 cap);
    error PayloadNotMulticall();
    error ForbiddenInnerTarget(address target);
    error CallNotAllowed(address target, bytes4 selector);
    error BeneficiaryMismatch(address expected, address actual);
    error InvalidRevertRecipient(address expected, address actual);
    error ValueOverspend(uint256 requested, uint256 available);
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

    /// @notice Authorise a single action the wallet is about to perform.
    /// @dev    Not `view` — the IActionPolicy interface declares this as
    ///         state-mutating so policies may update usage counters. This
    ///         implementation happens not to mutate, but MUST keep the
    ///         non-view mutability to match the interface (PRD §8.2). solc's
    ///         "can be restricted to view" advisory is therefore expected here
    ///         and is recorded in DEVIATIONS.md.
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
        if (req.amount > cfg.maxAmountPerCall) {
            revert AmountExceedsCap(req.amount, cfg.maxAmountPerCall); // R5
        }
        if (req.revertRecipient != account) {
            revert InvalidRevertRecipient(account, req.revertRecipient); // R10
        }

        _validateMulticallPayload(cfg, account, req.payload, value); // R6–R9, R11

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
            AllowedCall[] memory allowedCalls
        )
    {
        Config storage cfg = $configs[id][multiplexer][account];
        return (cfg.initialized, cfg.destChainHash, cfg.expectedCEA, cfg.asset, cfg.maxAmountPerCall, cfg.allowedCalls);
    }

    // ==============================
    //          INTERNALS
    // ==============================

    /// @dev Walks the nested multicall payload enforcing R6–R9 and R11.
    ///      ⚠ REVIEW REQUIRED — R7. `PushAgentWallet.execute` accepts
    ///      msg.sender == address(this) to permit batched self-configuration.
    ///      Without R7, a session key could route a call back into the wallet and
    ///      invoke installModule, taking full control.
    function _validateMulticallPayload(
        Config storage cfg,
        address account,
        bytes memory payload,
        uint256 valueAvailable
    ) internal view {
        if (payload.length < 4) revert PayloadNotMulticall();
        bytes4 sel;
        assembly {
            sel := mload(add(payload, 0x20))
        }
        if (sel != MULTICALL_SELECTOR) revert PayloadNotMulticall(); // R6

        bytes memory inner = _slice(payload, 4, payload.length - 4);
        Multicall[] memory calls = abi.decode(inner, (Multicall[]));

        uint256 valueSum;
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

            valueSum += calls[i].value;
            unchecked {
                ++i;
            }
        }

        if (valueSum > valueAvailable) revert ValueOverspend(valueSum, valueAvailable); // R11
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
                return AllowedCall(rule.target, rule.selector, rule.beneficiaryOffset, rule.hasBeneficiary);
            }
            unchecked {
                ++i;
            }
        }
        revert CallNotAllowed(to, selector);
    }

    /// @dev Copy a decoded config into storage, replacing any prior allowlist.
    function _store(Config storage cfg, Config memory incoming) internal {
        cfg.destChainHash = incoming.destChainHash;
        cfg.expectedCEA = incoming.expectedCEA;
        cfg.asset = incoming.asset;
        cfg.maxAmountPerCall = incoming.maxAmountPerCall;

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
        for (uint256 i; i < len;) {
            out[i] = data[start + i];
            unchecked {
                ++i;
            }
        }
    }
}
