// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IPushAgentWalletInit — the ONE function the factory compiles against.
 * @notice The factory deliberately does NOT import `PushAgentWallet`. Its obligation ends at
 *         "call this once, bubble its revert"; everything inside is the wallet's own concern.
 *         Importing the wallet would couple the factory's build to the wallet's whole dependency
 *         graph for a single zero-argument call.
 */
interface IPushAgentWalletInit {
    /// @notice One-shot. Callable only by the factory recorded in the clone's immutable args.
    /// @dev    Installs the default permission engine with empty install data. If it reverts, the
    ///         factory's whole deployment reverts with it — a wallet can never exist un-initialised.
    function initializeAccount() external;
}
