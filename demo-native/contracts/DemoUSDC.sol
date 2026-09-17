// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title  DemoUSDC
 * @notice DEMO TOKEN. NEVER DEPLOY THIS TO MAINNET. Anyone may mint any amount to any address.
 *
 * @dev    WHY THIS EXISTS RATHER THAN USING THE BRIDGED PRC20. The native demo has no bridge, and
 *         measured on Donut the deployer holds ZERO PRC20 USDC while the relayer holds 0.50 —
 *         acquiring a usable balance would mean bridging from Sepolia, reintroducing the exact
 *         cross-chain dependency this demo exists to remove. A purpose-deployed token also makes a
 *         fresh run self-contained: no faucet, no pool that a previous rehearsal drained.
 *
 * @dev    IT IS NAMED `dUSDC`, NOT `USDC`, AND THAT IS NOT A STYLE CHOICE. The audience reads the
 *         block explorer during the demo. A token called "USDC" on screen invites the conclusion
 *         that real USDC is in play, which would make the whole demonstration dishonest.
 *
 * @dev    SIX DECIMALS, matching real USDC, so every on-screen figure reads identically to the
 *         cross-chain demo's. The two demos must look the same to an audience.
 *
 * @dev    NO OWNER, NO PAUSE, NO BLOCKLIST, NO UPGRADE PATH. Each of those invites a mid-demo
 *         question that is not about agentic wallets. `mint` is permissionless for the same reason
 *         `StakeDummy.fundRewards` is: one less privileged role is one less thing to explain, and
 *         an owner-gated mint on a testnet demo token is ceremony with no security value.
 */
contract DemoUSDC is ERC20 {
    constructor() ERC20("Demo USDC", "dUSDC") { }

    /// @notice Six decimals, matching real USDC. `ERC20` defaults to 18, so this override is
    ///         load-bearing: without it every amount in the demo is off by twelve orders of
    ///         magnitude and the mandate's caps stop meaning what they say.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Mint to any address. Permissionless by design; see the contract notes.
     * @param to     Recipient.
     * @param amount Amount, in 6-decimal units.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
