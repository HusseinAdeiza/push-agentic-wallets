// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  AddressBook
 * @notice Resolves every address the native demo uses, so that no script carries a hardcoded one.
 *
 * @dev    THE ONE RULE: this library never returns `address(0)`. A key that is absent, or present
 *         and zero, reverts `MissingAddress(file, name)` naming what is missing. A demo that
 *         proceeds with a zero address fails later, in front of an audience, with nothing on screen
 *         explaining why.
 *
 *         ADAPTED FROM `demo/lib/AddressBook.sol`, WITH ONE RESOLVER REMOVED AND ONE ADDED:
 *
 *           · `sepolia()` is GONE. There is no second chain in this demo. If a script in
 *             `demo-native/` needs a Sepolia address, that is a bug in the script, and the absence
 *             of the resolver is what makes it a compile error rather than a runtime surprise.
 *           · `native()` is NEW — the two demo-only contracts this demo deploys on Push.
 *
 *         THREE FILES, THREE SHAPES, read rather than rewritten:
 *
 *           · NESTED — `push_agw_contracts.json` holds our own deployment under
 *                      `.contracts.<name>.address`, beside sizes, tx hashes and notes. It is the
 *                      permanent record of what we shipped and is not reshaped to suit a reader.
 *           · FLAT   — `donut_push_core.json` is a `<name>: <address>` map of Push infrastructure
 *                      this repo does not deploy.
 *           · FLAT   — `native_demo.json` is this demo's own two contracts, in the same shape.
 */
library AddressBook {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Push core infrastructure and the PRC20 registry. NOT deployed by this repo.
    string internal constant DIR = "deployments/address-book/";

    /**
     * @dev OUR OWN contracts, and this demo's, from the v2 (v3.1) cut.
     *
     *      THE SAME SPLIT THE CROSS-CHAIN DEMO USES, FOR THE SAME REASON. The v2 cut redeployed the
     *      wallet implementation, the factory, the SESSION ENGINE and the VALIDATOR, while upgrading
     *      URP in place behind its proxy. Push core did not move. The validator's address is an
     *      input to every permission id, so mixing a v1 validator with a v2 engine derives ids that
     *      address an empty config — failing at gate N1 rather than anywhere informative.
     */
    string internal constant OURS_DIR = "deployments/address-book-v2/";

    /// @dev The named failure this library exists to produce. Names the file and the key.
    error MissingAddress(string file, string name);

    // ─────────────────────────────── Push Chain Donut ───────────────────────────────

    /**
     * @notice Resolve one of the five contracts this repo deployed on Donut.
     * @param  name Key under `.contracts` — e.g. "factoryProxy", "urp", "sessionValidator",
     *              "sessionEngine".
     * @return The address. Never zero.
     */
    function ours(string memory name) internal view returns (address) {
        return _nested("push_agw_contracts.json", name);
    }

    /**
     * @notice Resolve Push core infrastructure on Donut.
     *
     * @dev    This demo uses it for ONE key only — nothing here calls the gateway. It is read so
     *         that scripts and tests can assert the wallet's `UNIVERSAL_GATEWAY_PC` immutable, and
     *         so the native mandate can prove it does not name it (gate N3, and the wallet's
     *         grant-time `MandateTypeMismatch`).
     *
     * @param  name Key — e.g. "UniversalGatewayPC".
     * @return The address. Never zero.
     */
    function donut(string memory name) internal view returns (address) {
        return _flat(DIR, "donut_push_core.json", name);
    }

    /**
     * @notice Resolve a contract this demo itself deployed — `DemoUSDC` or `StakeDummy`.
     *
     * @dev    Ships with both keys zeroed, so a script run before setup fails with a named
     *         `MissingAddress` rather than proceeding against `address(0)`.
     *
     * @param  name "DemoUSDC" or "StakeDummy".
     * @return The address. Never zero.
     */
    function native(string memory name) internal view returns (address) {
        return _flat(OURS_DIR, "native_demo.json", name);
    }

    // ───────────────────────────────── resolvers ─────────────────────────────────

    /// @dev Flat `<name>: <address>` map.
    function _flat(string memory dir, string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(dir, file));
        return _require(json, string.concat(".", name), file, name);
    }

    /// @dev Nested record: the address sits at `.contracts.<name>.address`, beside metadata.
    function _nested(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(OURS_DIR, file));
        return _require(json, string.concat(".contracts.", name, ".address"), file, name);
    }

    /**
     * @dev Read one JSON path and enforce the never-zero rule.
     *
     *      Absence and zero collapse to the same error on purpose. A caller can do nothing
     *      different about them — both mean "this address is not available" — and separate errors
     *      would suggest a distinction that does not exist.
     */
    function _require(string memory json, string memory path, string memory file, string memory name)
        private
        view
        returns (address)
    {
        if (!vm.keyExistsJson(json, path)) revert MissingAddress(file, name);
        address a = vm.parseJsonAddress(json, path);
        if (a == address(0)) revert MissingAddress(file, name);
        return a;
    }
}
