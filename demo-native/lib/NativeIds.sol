// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ConfigId } from "smartsessions/DataTypes.sol";

/**
 * @title  NativeIds
 * @notice The engine's config-id derivation, written ONCE and derived nowhere else.
 *
 * @dev    WHY THIS FILE EXISTS. A universal mandate has exactly one action, so there is one config
 *         id per mandate and most scripts never have to derive it. A NATIVE mandate has ONE CONFIG
 *         PER ACTION — a two-action mandate holds two independent rulebooks with independent
 *         counters under two distinct ids — so every script that reads or asserts URP state must
 *         derive the id for the specific action it cares about.
 *
 *         `abi.encodePacked` AT EVERY LEVEL, THREE DEEP. Nothing in this derivation uses
 *         `abi.encode`. Transcribed from `lib/smartsessions/contracts/lib/IdLib.sol`:
 *
 *           actionId = keccak256(abi.encodePacked(target, selector))
 *           policyId = keccak256(abi.encodePacked(permissionId, actionId))
 *           configId = keccak256(abi.encodePacked(account, policyId))
 *
 *         REACHING FOR `abi.encode` ON ANY ONE LEVEL derives an id that addresses an EMPTY config.
 *         Every read then fails at gate N1 with `NotInitialized`, which looks like a mandate
 *         problem and is not. That failure mode is the reason this derivation is in one file with
 *         a test that asserts it against a LIVE GRANT rather than against a second copy of the
 *         formula — a test that compares two transcriptions of the same arithmetic passes even
 *         when both are wrong.
 */
library NativeIds {
    /**
     * @notice The engine's action id for one `(target, selector)` pair.
     *
     * @dev    `IdLib.toActionId`. Note that the engine assigns `VALUE_SELECTOR` (`0xFFFFFFFF`)
     *         when calldata is under four bytes — so a value-only action's id is derived from that
     *         sentinel, not from an empty selector. This demo has no value-only actions; the note
     *         is here so nobody derives one wrongly later.
     *
     * @param  target   Action target.
     * @param  selector Action selector.
     * @return The action id.
     */
    function actionId(address target, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }

    /**
     * @notice The config id URP stores a rulebook under.
     *
     * @param  permissionId The mandate.
     * @param  account      The wallet the mandate belongs to.
     * @param  target       Action target.
     * @param  selector     Action selector.
     * @return The config id, ready to pass to `getNativeConfig` / `getMode` / `assertSpent`.
     */
    function configId(bytes32 permissionId, address account, address target, bytes4 selector)
        internal
        pure
        returns (ConfigId)
    {
        bytes32 policyId = keccak256(abi.encodePacked(permissionId, actionId(target, selector)));
        return ConfigId.wrap(keccak256(abi.encodePacked(account, policyId)));
    }

    /// @notice The same id as a raw `bytes32`, for writing to the ledger.
    function configWord(bytes32 permissionId, address account, address target, bytes4 selector)
        internal
        pure
        returns (bytes32)
    {
        return ConfigId.unwrap(configId(permissionId, account, target, selector));
    }
}
