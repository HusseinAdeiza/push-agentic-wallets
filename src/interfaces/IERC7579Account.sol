// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ModeCode } from "../libraries/ModeLib.sol";

/// @notice The subset of the ERC-7579 account interface implemented by PushAgentWallet.
/// @dev MUST NOT be advertised via supportsInterface. ERC-7579 defines no single
///      account interfaceId; discovery is via `accountId()`. This is a deliberate
///      local subset and claiming conformance from it would be wrong.
/// @dev `executeFromExecutor` is deliberately absent — executor modules are
///      unsupported in v1 (D-04), and `supportsModule(2)` returns false.
interface IERC7579Account {
    event ModuleInstalled(uint256 moduleTypeId, address module);
    event ModuleUninstalled(uint256 moduleTypeId, address module);

    function execute(ModeCode mode, bytes calldata executionCalldata) external payable;

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external;

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external;

    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext)
        external
        view
        returns (bool);

    function accountId() external view returns (string memory);

    function supportsExecutionMode(ModeCode mode) external view returns (bool);

    function supportsModule(uint256 moduleTypeId) external view returns (bool);
}
