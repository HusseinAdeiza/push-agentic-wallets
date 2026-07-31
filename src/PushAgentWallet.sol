// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { IERC7579Module, IERC7579Validator, IERC7579Hook } from "./interfaces/IERC7579Module.sol";
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
 * @notice Per-user, per-mandate ERC-7579 modular smart account on Push Chain.
 *         Holds funds and is the `msg.sender` seen by `UniversalGatewayPC`,
 *         which therefore determines which CEA executes on the destination chain.
 *
 * @dev    Deployed as an EIP-1167 minimal clone by `AgentWalletFactory` (D-01).
 *         The owner is set once at `initialize` and never changes (D-02).
 *
 *         There is no ERC-4337 EntryPoint on Push Chain (C2), so the account is
 *         driven by `executeWithSession`, a native-AA entry point that unpacks
 *         ERC-4337 ValidationData itself.
 */
contract PushAgentWallet is ReentrancyGuardTransient, IERC165, IERC721Receiver, IERC1155Receiver {
    // ==============================
    //          CONSTANTS
    // ==============================

    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2; // declared, never installable in v1 (D-04)
    uint256 internal constant MODULE_TYPE_FALLBACK = 3; // declared, never installable in v1 (D-07)
    uint256 internal constant MODULE_TYPE_HOOK = 4;

    string internal constant ACCOUNT_ID = "push.agentwallet.1.0.0";

    bytes4 internal constant ERC1271_FAILED = 0xFFFFFFFF;

    /// @dev Domain tag mixed into opHash. Prevents collision with any other digest scheme.
    bytes32 internal constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v1");

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

    // ==============================
    //            EVENTS
    // ==============================

    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);
    event WalletInitialized(address indexed owner);
    event SessionExecuted(address indexed validator, uint192 indexed nonceKey, uint64 nonceSeq, bytes32 opHash);
    event EmergencyRevokeAll(address indexed caller);
    event PCSwept(address indexed to, uint256 amount);

    // ==============================
    //          MODIFIERS
    // ==============================

    /// @dev The UEA owner, or the wallet calling itself (enables batched self-config).
    ///      SECURITY: because address(this) is permitted here, ACPActionPolicy MUST
    ///      reject address(this) as a call target. See §8.5 rule R7 / attack test A-04.
    modifier onlyOwnerOrSelf() {
        if (msg.sender != owner && msg.sender != address(this)) revert PushWalletErrors.Unauthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert PushWalletErrors.Unauthorized();
        _;
    }

    // ==============================
    //        INITIALIZATION
    // ==============================

    /// @notice Called exactly once by AgentWalletFactory immediately after cloning.
    /// @param  owner_ The UEA that owns this wallet. MUST be non-zero.
    /// @dev    Unguarded by caller because the clone is deployed and initialized
    ///         atomically by the factory in the same transaction; the counterfactual
    ///         address does not exist until `cloneDeterministic` returns. The
    ///         `_initialized` flag is the sole protection.
    function initialize(address owner_) external {
        if (_initialized) revert PushWalletErrors.AlreadyInitialized();
        if (owner_ == address(0)) revert PushWalletErrors.ZeroAddress();
        _initialized = true;
        owner = owner_;
        emit WalletInitialized(owner_);
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
        onlyOwnerOrSelf
        nonReentrant
    {
        if (!supportsModule(moduleTypeId)) revert PushWalletErrors.UnsupportedModuleType(moduleTypeId);
        if (module == address(0)) revert PushWalletErrors.ZeroAddress();
        if (_modules[moduleTypeId][module]) {
            revert PushWalletErrors.ModuleAlreadyInstalled(moduleTypeId, module);
        }

        // SECURITY: set state BEFORE the external call — onInstall may reenter.
        _modules[moduleTypeId][module] = true;
        if (moduleTypeId == MODULE_TYPE_HOOK) _hook = module;

        IERC7579Module(module).onInstall(initData);

        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @dev ⚠ REVIEW REQUIRED: `onUninstall` is called AFTER clearing state, so a
    ///      module that reverts in `onUninstall` still blocks removal. This is why
    ///      `emergencyRevokeAll` exists as the escape hatch.
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        onlyOwnerOrSelf
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

    function execute(ModeCode mode, bytes calldata executionCalldata) external payable onlyOwnerOrSelf nonReentrant {
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
        _hook = address(0);
        emit EmergencyRevokeAll(msg.sender);
    }

    /// @notice Return unspent native PC to a destination. Owner only.
    function sweepPC(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert PushWalletErrors.ZeroAddress();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert PushWalletErrors.NativeTransferFailed();
        emit PCSwept(to, amount);
    }

    /// @notice Owner-gated passthrough so SmartSession sees msg.sender == address(this).
    /// @dev    `data` MUST be an ABI-encoded call to SmartSession (e.g. enableSessions).
    ///         ⚠ REVIEW REQUIRED: the installed-validator check is what stops this
    ///         being an arbitrary-call escape hatch. It MUST NOT be relaxed.
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
