// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";

/**
 * @title  AddressBook
 * @notice Resolves every address the demo uses from `deployments/address-book/`, so that no script
 *         ever carries a hardcoded address.
 *
 * @dev    THE ONE RULE: this library never returns `address(0)`. A key that is absent, or present
 *         and zero, reverts `MissingAddress(chain, name)` naming what is missing. A demo that
 *         proceeds with a zero address fails minutes later on the far chain, in front of an
 *         audience, with nothing on screen explaining why — which is the failure mode the whole
 *         no-hardcoded-addresses rule exists to prevent.
 *
 *         TWO FILE SHAPES, TWO RESOLVERS. The files this reads were written for different purposes
 *         and are deliberately not unified:
 *
 *           · NESTED  — `push_agw_contracts.json` holds our own deployment under
 *                       `.contracts.<name>.address`, alongside sizes, tx hashes and notes. It is
 *                       the permanent record of what we shipped and is not reshaped to suit a
 *                       reader.
 *           · FLAT    — `sepolia.json` and `donut_push_core.json` are `<name>: <address>` maps of
 *                       infrastructure this repo does not deploy.
 *
 *         Both are read here rather than rewritten. If a key is in neither, that is a MissingAddress
 *         for a human to fill, not a file for a script to restructure.
 */
library AddressBook {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Push core and Sepolia infrastructure. NOT redeployed by the v2 cut — the gateway, the
    ///      UEA factory, the PRC20 registry and Sepolia's Vault/CEAFactory are all unchanged, and
    ///      `sepolia.json` additionally carries the corrected `CEAFactory` (the one the Vault
    ///      actually deploys through). Both files live only here.
    string internal constant DIR = "deployments/address-book/";

    /**
     * @dev OUR OWN five contracts, from the v2 deployment.
     *
     *      SPLIT DELIBERATELY, RATHER THAN COPYING FILES ACROSS. The v2 cut redeployed the wallet
     *      implementation, the factory and — this is the part that bites — the SESSION ENGINE and
     *      the VALIDATOR, while upgrading URP in place behind its proxy. Push core did not move at
     *      all. Pointing one directory at both would mean maintaining duplicate copies of files
     *      nobody redeployed, and a stale duplicate is exactly how the wrong-CEAFactory bug
     *      happened: an address that resolves, has code, and is simply not the one in use.
     *
     *      The validator's address is an input to every permission id, so mixing a v1 validator
     *      with a v2 engine would derive ids that address an empty config — failing at gate 1
     *      rather than anywhere informative.
     */
    string internal constant OURS_DIR = "deployments/address-book-v2/";

    /// @dev The named failure this library exists to produce. Names the file and the key.
    error MissingAddress(string chain, string name);

    // ─────────────────────────────── Push Chain Donut ───────────────────────────────

    /**
     * @notice Resolve one of the five contracts this repo deployed on Donut.
     * @param  name Key under `.contracts` — e.g. "factoryProxy", "urp", "sessionValidator".
     * @return The address. Never zero.
     */
    function ours(string memory name) internal view returns (address) {
        return _nested("push_agw_contracts.json", name);
    }

    /**
     * @notice Resolve Push core infrastructure or a PRC20 on Donut.
     * @param  name Key — e.g. "UniversalGatewayPC", "UniversalCore", "UEAFactory", "PRC20_USDC".
     * @return The address. Never zero.
     */
    function donut(string memory name) internal view returns (address) {
        return _flat("donut_push_core.json", name);
    }

    // ───────────────────────────────── Sepolia ─────────────────────────────────

    /**
     * @notice Resolve a contract on Ethereum Sepolia.
     * @param  name Key — e.g. "UniversalGateway", "Vault", "CEAFactory", "USDC", "StakeDummy".
     * @return The address. Never zero — an unwritten "StakeDummy" placeholder reverts.
     */
    function sepolia(string memory name) internal view returns (address) {
        return _flat("sepolia.json", name);
    }

    // ───────────────────────────────── resolvers ─────────────────────────────────

    /**
     * @dev Flat `<name>: <address>` map.
     * @param file Filename under the address-book directory.
     * @param name Top-level key.
     */
    function _flat(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(DIR, file));
        return _require(json, string.concat(".", name), file, name);
    }

    /**
     * @dev Nested record: the address sits at `.contracts.<name>.address`, beside metadata.
     *      Reads from `OURS_DIR` — our own deployment is the only thing the v2 cut moved.
     * @param file Filename under the v2 address-book directory.
     * @param name Key under `.contracts`.
     */
    function _nested(string memory file, string memory name) private view returns (address) {
        string memory json = vm.readFile(string.concat(OURS_DIR, file));
        return _require(json, string.concat(".contracts.", name, ".address"), file, name);
    }

    /**
     * @dev Read one JSON path and enforce the never-zero rule.
     *
     *      Absence and zero collapse to the same error on purpose. A caller can do nothing
     *      different about them — both mean "this address is not available" — and giving them
     *      separate errors would suggest a distinction that does not exist.
     *
     * @param json Parsed file contents.
     * @param path JSON path to read.
     * @param file Filename, for the error message.
     * @param name Key, for the error message.
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
