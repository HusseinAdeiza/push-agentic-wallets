// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  Keys
 * @notice Reads the demo's private keys from the environment.
 *
 * @dev    WHY THIS EXISTS RATHER THAN `vm.envUint` AT EACH SITE. `vm.envUint` requires a `0x`
 *         prefix and fails with a parse error otherwise. Keys are commonly stored bare, and this
 *         repo's `.env` stores them that way. Rather than require every operator to reformat a
 *         working `.env` — and risk a mangled key, which is the one editing mistake with no
 *         recoverable failure mode — both forms are accepted here.
 *
 *         NEVER PRINT A KEY. These functions return the private key itself; callers derive an
 *         address with `vm.addr` and print only that. Nothing in the demo may log a key, and the
 *         address is the only thing an audience needs.
 */
library Keys {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Names the variable and what it is for, so a missing key is a one-line fix.
    error MissingKey(string name, string usedFor);

    /**
     * @notice Read a private key, tolerating a missing `0x` prefix.
     * @param  name    Environment variable name, e.g. "BOB_KEY".
     * @param  usedFor What breaks without it, named in the error.
     * @return The private key.
     */
    function load(string memory name, string memory usedFor) internal view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        if (bytes(raw).length == 0) revert MissingKey(name, usedFor);

        return vm.parseUint(_hexPrefixed(raw));
    }

    /// @notice The address a key controls. The only key-derived value anything may print.
    function addressOf(string memory name, string memory usedFor) internal view returns (address) {
        return vm.addr(load(name, usedFor));
    }

    /// @dev Prepend `0x` when absent. A 64-char bare hex string and a 66-char prefixed one are both
    ///      valid ways to write the same key.
    function _hexPrefixed(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) return s;
        return string.concat("0x", s);
    }
}
