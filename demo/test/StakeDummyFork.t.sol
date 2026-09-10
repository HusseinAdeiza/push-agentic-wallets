// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The deployed contract's surface, declared locally so this test binds to the ABI rather
///      than to our source — if the deployed bytecode were a different build, this would fail.
interface IStakeDummyLive {
    function stakeFor(address beneficiary, uint256 amount) external;
    function unstake() external;
    function totalBalance(address) external view returns (uint256);
    function REWARD() external view returns (uint256);
    function token() external view returns (address);
}

/**
 * @title  StakeDummyForkTest
 * @notice Exercises the DEPLOYED StakeDummy on a Sepolia fork.
 *
 * @dev    WHY THIS EXISTS ALONGSIDE THE UNIT TESTS. `StakeDummy.t.sol` deploys a fresh contract
 *         against a mock token and proves the source is correct. It says nothing about the
 *         contract the demo will actually call: whether the deployed bytecode is this source,
 *         whether it was wired to the right token, and whether its reward pool is funded.
 *
 *         Those three are exactly what makes Act 4 succeed or die, and the failure mode is late —
 *         `unstake` reverts on a dry pool at the very end of the demo, after the audience has
 *         watched the money go out. This test forks the live chain and runs the full cycle, so
 *         that failure surfaces now.
 *
 *         ENV-GATED, AND A SKIP IS NOT A PASS. Without `SEPOLIA_RPC_URL` there is nothing to fork,
 *         so the test no-ops. Run it against a real endpoint before trusting Act 4.
 */
contract StakeDummyForkTest is Test {
    /// @dev Read from the address book rather than hardcoded, so the test follows a redeploy.
    IStakeDummyLive internal stake;
    IERC20 internal usdc;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);

        string memory book = vm.readFile("deployments/address-book/sepolia.json");
        address sd = vm.parseJsonAddress(book, ".StakeDummy");
        if (sd == address(0)) return false;

        stake = IStakeDummyLive(sd);
        usdc = IERC20(vm.parseJsonAddress(book, ".USDC"));
        return true;
    }

    /**
     * @notice The full Act 2 -> Act 4a cycle against the live contract: stake 50, unstake, receive
     *         60. This is the demo's headline arithmetic, proven on the deployed bytecode.
     */
    function test_liveStakeUnstakeCycle() public {
        if (!_fork()) return;

        address staker = makeAddr("staker");
        deal(address(usdc), staker, 50e6);

        uint256 before = usdc.balanceOf(staker);

        vm.startPrank(staker);
        usdc.approve(address(stake), 50e6);
        stake.stakeFor(staker, 50e6);
        assertEq(stake.totalBalance(staker), 50e6, "principal credited");

        stake.unstake();
        vm.stopPrank();

        assertEq(usdc.balanceOf(staker), before + stake.REWARD(), "principal returned plus the flat reward");
        assertEq(stake.totalBalance(staker), 0, "balance cleared");
    }

    /// @dev The deployed contract must be wired to the same USDC the demo bridges, or the agent's
    ///      staked funds and the contract's token are two different assets.
    function test_liveTokenMatchesAddressBook() public {
        if (!_fork()) return;
        assertEq(stake.token(), address(usdc), "StakeDummy holds the USDC the demo uses");
    }

    /**
     * @dev The reward pool must cover at least one unstake, and preferably several.
     *      Preflight asserts the same thing; it is repeated here because a drained pool is the most
     *      avoidable way for this demo to die, and it dies at the very last act.
     */
    function test_liveRewardPoolIsFunded() public {
        if (!_fork()) return;

        uint256 pool = usdc.balanceOf(address(stake));
        assertGe(pool, stake.REWARD(), "pool covers at least one unstake");
        assertGe(pool, 10 * stake.REWARD(), "pool covers ten unstakes: rehearsals plus the live run");
    }
}
