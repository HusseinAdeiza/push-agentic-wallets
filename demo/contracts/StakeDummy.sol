// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  StakeDummy
 * @notice DEMO CONTRACT. NEVER DEPLOY THIS TO MAINNET. It pays a reward out of a pool anyone may
 *         fund, has no owner, no pause and no supply accounting, and would be drained within a
 *         block on a live network. It exists to be the far-chain target of a demo mandate.
 *
 * @dev    ITS SHAPE IS CHOSEN, NOT INCIDENTAL. `stakeFor(address,uint256)` takes a beneficiary as
 *         its FIRST argument specifically so that UCEP's `AllowedCall` can pin that argument and
 *         assert it equals the wallet's own destination account. With a plain `stake(uint256)` the
 *         beneficiary gate never fires and the demo skips the most product-defining check in the
 *         system. The beneficiary therefore sits at calldata offset 4 — the first argument word,
 *         immediately after the selector — which is the `beneficiaryOffset` the mandate names.
 *
 *         FOUR FUNCTIONS, AND IT STAYS AT FOUR. Every function not in the agent's allow-list
 *         invites "why can't the agent call that?" mid-demo. There is nothing here to explain
 *         away.
 */
contract StakeDummy {
    using SafeERC20 for IERC20;

    /// @notice The staked asset. Sepolia USDC in the demo.
    IERC20 public immutable token;

    /// @notice Staked principal per beneficiary. The auto-generated getter is the only accessor.
    mapping(address => uint256) public totalBalance;

    /// @notice The flat reward `unstake` pays on top of principal. Named, never inlined.
    uint256 public constant REWARD = 10e6;

    event Staked(address indexed payer, address indexed beneficiary, uint256 amount);
    event Unstaked(address indexed staker, uint256 principal, uint256 reward);
    event RewardsFunded(address indexed funder, uint256 amount);

    error ZeroBeneficiary();
    error ZeroAmount();
    error NothingStaked();

    /// @param _token The ERC-20 staked and rewarded. Not validated: a demo contract with a bad
    ///               token is inert, and a zero-address check here would be the only guard in a
    ///               contract that deliberately has none.
    constructor(IERC20 _token) {
        token = _token;
    }

    /**
     * @notice Stake `amount` on behalf of `beneficiary`.
     *
     * @dev    The caller pays; the beneficiary is credited. In the demo the CEA is both, but they
     *         are separate parameters precisely so the mandate can pin one of them.
     *
     * @param beneficiary Credited with the principal. Must be non-zero.
     * @param amount      Amount to pull from the caller. Must be non-zero.
     */
    function stakeFor(address beneficiary, uint256 amount) external {
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);
        totalBalance[beneficiary] += amount;

        emit Staked(msg.sender, beneficiary, amount);
    }

    /**
     * @notice Withdraw the caller's entire principal plus a flat reward.
     *
     * @dev    NO ARGUMENTS BY DESIGN. The caller is the staker, which keeps the allow-list entry
     *         trivial — no beneficiary to pin — and makes the agent's second request a bare
     *         four-byte calldata. Balance is zeroed before the transfer.
     *
     *         The reward must already be in the contract; `fundRewards` puts it there.
     */
    function unstake() external {
        uint256 principal = totalBalance[msg.sender];
        if (principal == 0) revert NothingStaked();

        totalBalance[msg.sender] = 0;
        token.safeTransfer(msg.sender, principal + REWARD);

        emit Unstaked(msg.sender, principal, REWARD);
    }

    /**
     * @notice Add to the reward pool.
     * @dev    Permissionless so the setup script can pre-fund without a privileged role — one less
     *         piece of state, and nothing an audience needs explained.
     * @param amount Amount to pull from the caller.
     */
    function fundRewards(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);

        emit RewardsFunded(msg.sender, amount);
    }
}
