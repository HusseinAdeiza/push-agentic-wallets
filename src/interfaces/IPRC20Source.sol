// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  IPRC20Source — the ONE view URP reads from a PRC20, at grant only.
 *
 * @notice Mirror of push-chain-core `src/PRC20.sol` — `string public SOURCE_CHAIN_NAMESPACE`, set
 *         once in `initialize` with no setter. Returns the CAIP-2 identifier of the chain the token
 *         came from, e.g. `"eip155:11155111"` for `USDC.eth` on Donut (read live, 2026-09-17).
 *
 * @dev    WHY A MIRROR AND NOT AN IMPORT: push-chain-core is not a submodule of this repository, so
 *         there is nothing to import. The mirror is therefore pinned by a FORK TEST against a
 *         deployed PRC20 rather than by the compiler.
 *
 *         WHY THE COUPLING IS SAFE: the gateway reads this exact view on every outbound, through
 *         `UniversalCore.getOutboundTxGasAndFees` — it is how the gateway decides which chain to
 *         route to. If this signature ever changes, the gateway breaks before URP does.
 *
 *         THE FIELD WAS RENAMED ONCE ALREADY (`SOURCE_CHAIN_ID`, now deprecated), which is the
 *         argument for pinning the current name here and in a test, not an argument against reading
 *         it.
 */
interface IPRC20Source {
    function SOURCE_CHAIN_NAMESPACE() external view returns (string memory);
}
