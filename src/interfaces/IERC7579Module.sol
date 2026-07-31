// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @notice Base ERC-7579 module interface.
interface IERC7579Module {
    /// @notice Called by the account when the module is installed.
    function onInstall(bytes calldata data) external;

    /// @notice Called by the account when the module is uninstalled.
    function onUninstall(bytes calldata data) external;

    /// @notice Returns true if the module is of the given type.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);

    /// @notice Returns true if the module has been initialized for `smartAccount`.
    function isInitialized(address smartAccount) external view returns (bool);
}

/// @notice ERC-7579 validator module (type 1).
interface IERC7579Validator is IERC7579Module {
    /// @notice Validates a user operation. Returns packed ERC-4337 ValidationData.
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external returns (uint256);

    /// @notice ERC-1271 style signature validation on behalf of the account.
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4);
}

/// @notice ERC-7579 hook module (type 4). Declared per D-08; none installed in v1.
interface IERC7579Hook is IERC7579Module {
    /// @notice Called before execution. Return value is passed to postCheck.
    function preCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory hookData);

    /// @notice Called after execution with the data returned by preCheck.
    function postCheck(bytes calldata hookData) external;
}
