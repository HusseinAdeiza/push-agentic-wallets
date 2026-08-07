// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Session, PermissionId } from "smartsessions/DataTypes.sol";

/**
 * @title  ISmartSessionMandate
 * @notice The minimal slice of SmartSession the wallet's mandate lifecycle calls.
 *
 * @dev    Declared locally rather than importing `ISmartSession` wholesale: the wallet
 *         only ever needs these four functions, and a narrow interface makes the
 *         wallet's authority over the session engine auditable at a glance.
 *
 * @dev    All four are `msg.sender`-scoped upstream — SmartSession keys every mapping
 *         by the calling smart account. The wallet therefore cannot touch another
 *         account's sessions through this interface.
 *
 * @dev    `removeSession` deliberately has NO installed-module check upstream
 *         (`SmartSessionBase.sol:329`), which is what makes `purgeDanglingSessions`
 *         able to run after `emergencyRevokeAll` has flipped the module off. Do not
 *         route removals through `callValidator` — see PushAgentWallet.revokeMandate.
 */
interface ISmartSessionMandate {
    function enableSessions(Session[] calldata sessions) external returns (PermissionId[] memory);

    function removeSession(PermissionId permissionId) external;

    function isPermissionEnabled(PermissionId permissionId, address account) external view returns (bool);

    function getPermissionIDs(address account) external view returns (PermissionId[] memory);
}
