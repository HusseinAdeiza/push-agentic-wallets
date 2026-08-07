// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC7579Module, IERC7579Validator, IERC7579Hook } from "../../src/interfaces/IERC7579Module.sol";
import { UniversalOutboundTxRequest, Multicall, MULTICALL_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";

/// @notice Validator that returns a caller-controlled ValidationData word.
contract MockValidator is IERC7579Validator {
    uint256 public validationData;
    bool public installed;
    bytes public lastInitData;
    uint256 public installCount;
    uint256 public uninstallCount;

    bytes32 public lastOpHash;
    address public lastSender;
    uint256 public lastNonce;
    bytes public lastSignature;
    bytes public lastCallData;

    function setValidationData(uint256 v) external {
        validationData = v;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external returns (uint256) {
        lastOpHash = userOpHash;
        lastSender = userOp.sender;
        lastNonce = userOp.nonce;
        lastSignature = userOp.signature;
        lastCallData = userOp.callData;
        return validationData;
    }

    function isValidSignatureWithSender(address, bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }

    function onInstall(bytes calldata data) external virtual {
        installed = true;
        lastInitData = data;
        ++installCount;
    }

    function onUninstall(bytes calldata) external virtual {
        installed = false;
        ++uninstallCount;
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 1;
    }

    function isInitialized(address) external view returns (bool) {
        return installed;
    }
}

/// @notice Validator whose onUninstall always reverts — proves emergencyRevokeAll works (A-10).
contract StubbornValidator is MockValidator {
    function onUninstall(bytes calldata) external pure override {
        revert("cannot uninstall");
    }
}

/// @notice Validator that reenters the wallet during onInstall (A-11).
contract ReenteringValidator is MockValidator {
    address public wallet;
    bool public attempted;
    bool public reentrySucceeded;

    function setWallet(address w) external {
        wallet = w;
    }

    function onInstall(bytes calldata) external override {
        attempted = true;
        (bool ok,) = wallet.call(abi.encodeWithSignature("installModule(uint256,address,bytes)", 1, address(this), ""));
        reentrySucceeded = ok;
    }
}

/// @notice Simple call target that records invocations.
contract MockTarget {
    uint256 public value;
    uint256 public receivedValue;
    uint256 public callCount;
    uint256[] public order;

    error TargetReverted(string reason);

    function setValue(uint256 v) external payable {
        value = v;
        receivedValue += msg.value;
        ++callCount;
        order.push(v);
    }

    function boom() external pure {
        revert TargetReverted("boom");
    }

    function orderLength() external view returns (uint256) {
        return order.length;
    }
}

/// @notice Hook that records pre/post invocations.
contract MockHook is IERC7579Hook {
    uint256 public preCount;
    uint256 public postCount;
    bytes public lastHookData;
    address public lastMsgSender;
    uint256 public lastMsgValue;
    bool public installed;

    function preCheck(address msgSender, uint256 msgValue, bytes calldata) external returns (bytes memory hookData) {
        ++preCount;
        lastMsgSender = msgSender;
        lastMsgValue = msgValue;
        return abi.encode(preCount);
    }

    function postCheck(bytes calldata hookData) external {
        ++postCount;
        lastHookData = hookData;
    }

    function onInstall(bytes calldata) external {
        installed = true;
    }

    function onUninstall(bytes calldata) external {
        installed = false;
    }

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 4;
    }

    function isInitialized(address) external view returns (bool) {
        return installed;
    }
}

/// @notice Records the outbound request the wallet sends, standing in for UniversalGatewayPC.
contract MockUniversalGatewayPC {
    uint256 public callCount;
    uint256 public lastValue;
    address public lastSender;

    bytes public lastRecipient;
    address public lastToken;
    uint256 public lastAmount;
    bytes public lastPayload;
    address public lastRevertRecipient;

    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external payable {
        ++callCount;
        lastValue = msg.value;
        lastSender = msg.sender;
        lastRecipient = req.recipient;
        lastToken = req.token;
        lastAmount = req.amount;
        lastPayload = req.payload;
        lastRevertRecipient = req.revertRecipient;
    }
}

/// @notice Stand-in for the USV precompile, etched at its fixed address.
contract MockUSV {
    bool public result;
    bytes public lastPubKey;
    bytes public lastMessage;
    bytes public lastSignature;

    function setResult(bool r) external {
        result = r;
    }

    function verifyEd25519(bytes calldata, bytes32, bytes calldata) external view returns (bool) {
        return result;
    }

    function verifyEd25519RawMessage(bytes calldata pubKey, bytes calldata message, bytes calldata signature)
        external
        view
        returns (bool)
    {
        // `view` for interface compatibility; recording is done via a separate helper
        // in tests that need it.
        pubKey;
        message;
        signature;
        return result;
    }
}

/// @notice Rejects native transfers, to exercise sweepPC failure.
contract RejectsPC {
    receive() external payable {
        revert("no pc");
    }
}

/**
 * @notice Faithful mirror of the FROZEN `CEA` execution paths, for T-54.
 *
 * @dev MIRRORS: push-chain-core-contracts/src/cea/CEA.sol
 *        - `_handleExecution`   lines 164-179  (three-way branch)
 *        - `_handleMulticall`   lines 188-215  (incl. the value-0 self-call rule, :196)
 *        - `_handleSingleCall`  lines 225-256  (incl. the park case and InvalidRecipient)
 *        - `_isMulticall`       lines 281-284
 *        - `_isMigration`       lines 298-301
 *
 *      Rule 1 forbids modifying `CEA.sol`, so its semantics are load-bearing AS-IS: the
 *      `InvalidRecipient()` revert is what makes ACP's R14 a fail-closed backstop. This
 *      mock exists to prove that backstop against the real branch structure rather than
 *      against an assumption about it. If the frozen source ever changes, update the line
 *      references above in lockstep.
 */
contract MockCEA {
    bytes4 internal constant MIGRATION_SELECTOR = bytes4(keccak256("UEA_MIGRATION"));

    error InvalidTarget();
    error InvalidInput();
    error InvalidRecipient();
    error ExecutionFailed();

    event UniversalTxExecuted(address recipient, bytes payload);

    bool public parked;

    function handleExecution(address recipient, bytes calldata payload) external payable {
        if (_isMulticall(payload)) {
            _handleMulticall(abi.decode(payload[4:], (Multicall[])));
        } else if (_isMigration(payload)) {
            if (recipient != address(this)) revert InvalidRecipient();
            emit UniversalTxExecuted(address(this), payload);
        } else {
            _handleSingleCall(recipient, payload);
        }
    }

    function _handleMulticall(Multicall[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].to == address(0)) revert InvalidTarget();
            // CEA.sol:196 — self-calls are permitted, but must carry zero value. This is
            // what makes the inner CEA self-call a viable exit path, and therefore why
            // ACP R7 must reject `to == expectedCEA` (A-03).
            if (calls[i].to == address(this) && calls[i].value != 0) revert InvalidInput();
            (bool ok, bytes memory ret) = calls[i].to.call{ value: calls[i].value }(calls[i].data);
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(32, ret), mload(ret))
                    }
                }
                revert ExecutionFailed();
            }
        }
    }

    function _handleSingleCall(address recipient, bytes calldata payload) internal {
        // The documented "park funds in the caller's CEA" case.
        if (payload.length == 0 && recipient == address(0)) {
            parked = true;
            emit UniversalTxExecuted(address(this), payload);
            return;
        }
        // R14's BACKSTOP: a non-empty payload with a zero recipient reverts here instead
        // of executing `recipient.call{value: msg.value}(payload)` — which would be direct
        // theft (A-02).
        if (recipient == address(0)) revert InvalidRecipient();
        if (recipient == address(this)) revert InvalidRecipient();

        (bool ok, bytes memory ret) = recipient.call{ value: msg.value }(payload);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            }
            revert ExecutionFailed();
        }
        emit UniversalTxExecuted(recipient, payload);
    }

    function _isMulticall(bytes calldata data) internal pure returns (bool) {
        if (data.length < 4) return false;
        return bytes4(data[0:4]) == MULTICALL_SELECTOR;
    }

    function _isMigration(bytes calldata data) internal pure returns (bool) {
        if (data.length < 4) return false;
        return bytes4(data[0:4]) == MIGRATION_SELECTOR;
    }

    receive() external payable { }
}
