// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { StakeDummy } from "../contracts/StakeDummy.sol";
import { Amounts } from "../lib/Amounts.sol";

/// @dev A 6-decimal ERC-20 standing in for dUSDC. Decimals matter: the demo's amounts and
///      the reward constant are all 6-decimal, and an 18-decimal stand-in would let a scaling bug
///      pass here and fail on-chain.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title  StakeDummyTest
 * @notice Unit tests for the demo's far-chain target.
 *
 * @dev    These cover the contract's own behaviour only. That the MANDATE constrains calls to it
 *         is URP's property and is proven by the gauntlet scripts against the live chain, not
 *         here — a unit test of StakeDummy cannot demonstrate anything about the policy.
 */
contract StakeDummyTest is Test {
    MockUSDC internal usdc;
    StakeDummy internal stake;

    address internal cea = makeAddr("cea");
    address internal funder = makeAddr("funder");

    uint256 internal constant STAKE_AMOUNT = 50e6;
    uint256 internal constant POOL = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        stake = new StakeDummy(IERC20(address(usdc)));

        usdc.mint(cea, 1000e6);
        usdc.mint(funder, POOL);

        vm.prank(funder);
        usdc.approve(address(stake), type(uint256).max);
        vm.prank(funder);
        stake.fundRewards(POOL);

        vm.prank(cea);
        usdc.approve(address(stake), type(uint256).max);
    }

    // ───────────────────────────────── stakeFor ─────────────────────────────────

    function test_stakeFor_creditsBeneficiaryAndPullsFromCaller() public {
        uint256 callerBefore = usdc.balanceOf(cea);

        vm.prank(cea);
        stake.stakeFor(cea, STAKE_AMOUNT);

        assertEq(stake.totalBalance(cea), STAKE_AMOUNT, "beneficiary credited");
        assertEq(usdc.balanceOf(cea), callerBefore - STAKE_AMOUNT, "caller debited");
    }

    /// @dev The payer and the beneficiary are genuinely separate. This is the property the mandate's
    ///      beneficiary pin depends on: if they were forced equal, pinning one would be vacuous.
    function test_stakeFor_payerAndBeneficiaryAreIndependent() public {
        vm.prank(cea);
        stake.stakeFor(funder, STAKE_AMOUNT);

        assertEq(stake.totalBalance(funder), STAKE_AMOUNT, "beneficiary credited");
        assertEq(stake.totalBalance(cea), 0, "payer not credited");
    }

    function test_stakeFor_accumulates() public {
        vm.startPrank(cea);
        stake.stakeFor(cea, STAKE_AMOUNT);
        stake.stakeFor(cea, STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(stake.totalBalance(cea), STAKE_AMOUNT * 2, "balances add");
    }

    /// @dev The beneficiary must sit at calldata offset 4 — the first argument word. The mandate
    ///      names that offset, and URP reads a 32-byte word there and compares it to the expected
    ///      CEA. If the signature ever gained a leading parameter this assertion fails, which is
    ///      the point: the offset is a contract between this file and the mandate.
    function test_stakeFor_beneficiaryIsAtCalldataOffset4() public pure {
        bytes memory data = abi.encodeCall(StakeDummy.stakeFor, (address(0xBEEF), STAKE_AMOUNT));

        bytes32 word;
        // Skip the 32-byte length prefix, then the 4-byte selector.
        assembly {
            word := mload(add(data, 36))
        }

        assertEq(address(uint160(uint256(word))), address(0xBEEF), "beneficiary is the first argument word");
    }

    function test_stakeFor_revertsOnZeroBeneficiary() public {
        vm.prank(cea);
        vm.expectRevert(StakeDummy.ZeroBeneficiary.selector);
        stake.stakeFor(address(0), STAKE_AMOUNT);
    }

    function test_stakeFor_revertsOnZeroAmount() public {
        vm.prank(cea);
        vm.expectRevert(StakeDummy.ZeroAmount.selector);
        stake.stakeFor(cea, 0);
    }

    // ───────────────────────────────── unstake ─────────────────────────────────

    function test_unstake_paysPrincipalPlusReward() public {
        vm.prank(cea);
        stake.stakeFor(cea, STAKE_AMOUNT);

        uint256 before = usdc.balanceOf(cea);

        vm.prank(cea);
        stake.unstake();

        assertEq(usdc.balanceOf(cea) - before, STAKE_AMOUNT + stake.REWARD(), "principal plus flat reward");
        assertEq(stake.totalBalance(cea), 0, "balance cleared");
    }

    /// @dev The demo's headline number: stake 50, unstake, hold 60.
    function test_unstake_demoArithmetic() public {
        vm.prank(cea);
        stake.stakeFor(cea, 50e6);
        vm.prank(cea);
        stake.unstake();

        assertEq(stake.REWARD(), 10e6, "flat 10 USDC reward");
    }

    function test_unstake_revertsForUnknownStaker() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StakeDummy.NothingStaked.selector);
        stake.unstake();
    }

    function test_unstake_revertsOnSecondCall() public {
        vm.startPrank(cea);
        stake.stakeFor(cea, STAKE_AMOUNT);
        stake.unstake();

        vm.expectRevert(StakeDummy.NothingStaked.selector);
        stake.unstake();
        vm.stopPrank();
    }

    /// @dev The balance is zeroed before the transfer. Asserted through observable state rather
    ///      than by reading the source: a reentrant token would find nothing left to withdraw.
    function test_unstake_zeroesBalanceBeforeTransfer() public {
        vm.prank(cea);
        stake.stakeFor(cea, STAKE_AMOUNT);
        vm.prank(cea);
        stake.unstake();

        assertEq(stake.totalBalance(cea), 0, "cleared");
    }

    // ─────────────────────────────── reward pool ───────────────────────────────

    function test_unstake_revertsWhenRewardPoolIsDry() public {
        // A fresh contract with no pool: the principal is present but the reward is not.
        StakeDummy dry = new StakeDummy(IERC20(address(usdc)));
        vm.startPrank(cea);
        usdc.approve(address(dry), type(uint256).max);
        dry.stakeFor(cea, STAKE_AMOUNT);

        vm.expectRevert();
        dry.unstake();
        vm.stopPrank();
    }

    function test_fundRewards_increasesPool() public {
        uint256 before = usdc.balanceOf(address(stake));

        usdc.mint(address(this), 25e6);
        usdc.approve(address(stake), 25e6);
        stake.fundRewards(25e6);

        assertEq(usdc.balanceOf(address(stake)) - before, 25e6, "pool grew");
    }

    function test_fundRewards_revertsOnZeroAmount() public {
        vm.expectRevert(StakeDummy.ZeroAmount.selector);
        stake.fundRewards(0);
    }

    /// @dev Setup funds 100 USDC — ten unstakes. Preflight asserts >= 10e6 remains, because a demo
    ///      that dies at Act 4 on a pool drained by rehearsals is the most avoidable failure there is.
    function test_pool_coversTenUnstakes() public view {
        assertGe(usdc.balanceOf(address(stake)), 10 * stake.REWARD(), "pool covers ten rewards");
    }

    // ──────────────────────────────── surface ────────────────────────────────

    /**
     * @dev The surface is frozen: three callable entry points plus three read-only getters, and
     *      nothing else. Any addition is surface the mandate does not name and invites a mid-demo
     *      question with no good answer.
     *
     *      SIX, NOT FOUR. Part 4 of the spec counts the four things a caller can *do*
     *      (`stakeFor`, `unstake`, `fundRewards`, and reading `totalBalance`). The ABI also carries
     *      getters solc generates for `public constant REWARD` and `public immutable token`, both
     *      of which the spec itself requires. They are reads of compile-time constants and add no
     *      behaviour — but they are real ABI entries, so the assertion counts them rather than
     *      pretending the number is four.
     *
     *      Asserted against solc's own ABI output rather than by counting `.selector` references,
     *      because a test that lists what it expects to find cannot notice a function that was
     *      ADDED. Reading the artifact is the only form of this assertion that can actually fail.
     *
     *      Walks indices rather than using a `[*]` wildcard: `vm.parseJson` rejects wildcards with
     *      "must return exactly one JSON value", the same limitation recorded at
     *      `test/Base.t.sol`'s storage-layout helper. Indexing until the key runs out is the form
     *      that works.
     */
    function test_surface_isExactlyFourFunctions() public view {
        string memory artifact = vm.readFile("out/StakeDummy.sol/StakeDummy.json");

        uint256 fns;
        for (uint256 i; i < 64; ++i) {
            string memory path = string.concat(".abi[", vm.toString(i), "].type");
            if (!vm.keyExistsJson(artifact, path)) break;
            if (keccak256(bytes(vm.parseJsonString(artifact, path))) == keccak256("function")) ++fns;
        }

        assertEq(fns, 6, "surface frozen: stakeFor, unstake, fundRewards, totalBalance, REWARD, token");
    }

    /// @dev The three the mandate names, plus the getter the inspect scripts read. Pinned so a
    ///      signature change breaks here rather than silently invalidating a granted allow-list.
    function test_surface_selectorsAreStable() public view {
        assertEq(StakeDummy.stakeFor.selector, bytes4(keccak256("stakeFor(address,uint256)")), "stakeFor");
        assertEq(StakeDummy.unstake.selector, bytes4(keccak256("unstake()")), "unstake");
        assertEq(StakeDummy.fundRewards.selector, bytes4(keccak256("fundRewards(uint256)")), "fundRewards");
        assertEq(stake.totalBalance.selector, bytes4(keccak256("totalBalance(address)")), "totalBalance getter");
    }

    /**
     * @notice `Amounts.REWARD` mirrors `StakeDummy.REWARD`, and the two must never drift.
     *
     * @dev    `Amounts.REWARD` exists only so scripts can ASSERT what a successful unstake should
     *         pay. If it and the contract's constant disagree, the assertion is wrong and the
     *         contract is right — and every act-4a balance check would fail for a reason that has
     *         nothing to do with the wallet. Pinning them together makes that a failing test here
     *         rather than a confusing number on screen.
     */
    function test_rewardMirrorMatchesTheContract() public view {
        assertEq(Amounts.REWARD, stake.REWARD(), "Amounts.REWARD drifted from StakeDummy.REWARD");
    }
}
