// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PermissionId } from "smartsessions/DataTypes.sol";

/**
 * @title  ISmartSessionConfigReader
 * @notice The one SmartSession view the wallet needs that upstream `ISmartSession` does not declare.
 * @dev    Mirrors `SmartSessionBase.getSessionValidatorAndConfig` exactly. Declared locally rather than
 *         editing the vendored engine. A test (`test_mirror_getSessionValidatorAndConfigSelector`)
 *         pins this selector against the engine's own, so a fork bump that moves it fails the build.
 */
interface ISmartSessionConfigReader {
    /// @notice The session validator and its stored config for `permissionId` on `account`.
    /// @dev    Both are zero/empty for an unknown or removed permission: removal clears them.
    function getSessionValidatorAndConfig(address account, PermissionId permissionId)
        external
        view
        returns (address sessionValidator, bytes memory sessionValidatorData);
}
