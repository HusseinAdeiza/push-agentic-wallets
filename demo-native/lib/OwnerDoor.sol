// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { NativeRequest } from "./NativeRequest.sol";

/// @dev The owner door and the lifecycle functions. `execute(bytes32,bytes)` is a FROZEN signature
///      — the engine branches on this selector, and any other shape routes validation to a path
///      where URP's value gate sees a hardcoded zero instead of the real value.
interface IOwnerDoor {
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;
    function owner() external view returns (address);
    function stopAll() external;
    function stopMandate(bytes32 permissionId) external;
}

/**
 * @title  OwnerDoor
 * @notice Bob's half: one call through `execute`, encoded the one way the wallet accepts.
 *
 * @dev    DECLARED ONCE BECAUSE FOUR SCRIPTS USE IT — the approval (1c), the withdrawal (4c), and
 *         Act 4f's throwaway funding. Each would otherwise re-encode the same three layers, and an
 *         encoding mistake in one of them would look like a permission failure.
 *
 *         THE OWNER DOOR CONSULTS EXACTLY TWO THINGS: the immutable-args owner and the calldata.
 *         No module, policy, engine state or flag is read there — it must succeed with the engine
 *         uninstalled and a hostile validator installed. That is why Bob can always act, instantly,
 *         no matter what any mandate says, and it is the property Act 4c demonstrates.
 */
library OwnerDoor {
    /**
     * @notice Have the wallet call `target` with `data`, carrying no value.
     * @dev    Broadcast this from the OWNER's key; `execute` is `onlyOwner`.
     */
    function call(address wallet, address target, bytes memory data) internal {
        IOwnerDoor(wallet).execute(NativeRequest.singleMode(), ExecutionLib.encodeSingle(target, 0, data));
    }
}
