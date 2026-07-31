// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { IERC7579Module, IERC7579Validator, IERC7579Hook } from "../../src/interfaces/IERC7579Module.sol";
import { UniversalOutboundTxRequest } from "../../src/libraries/PushWalletTypes.sol";

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
