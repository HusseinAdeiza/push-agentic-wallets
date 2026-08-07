// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, Vm } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";

/**
 * @notice v2 Step 2 — the Rule 2 factory rewrite (T-01 … T-05).
 *
 * @dev The property under test changed species. v1 keyed wallets by
 *      (owner, mandateId) and REVERTED on a duplicate. v2 keys by owner alone and is
 *      IDEMPOTENT, because one wallet per user for life is what fixes one CEA per user
 *      per external chain (Rule 2, D-03v2).
 */
contract AgentWalletFactoryV2Test is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;

    address internal ownerUEA = address(0xB0B);
    address internal alice = address(0xA11CE0);
    address internal guardian = address(0x6DA);

    event AgentWalletDeployed(address indexed wallet, address indexed owner);

    function setUp() public {
        impl = new PushAgentWallet(address(0x5511), address(0x6A7E), address(0xAC90), address(0x71FE), address(0x0A11));
        factory = new AgentWalletFactory(address(impl));
    }

    // ── T-01 ──────────────────────────────────────────────────────────

    function test_T01_deploysAtPredictedAddress() public {
        address predicted = factory.computeAgentWallet(ownerUEA);
        assertEq(predicted.code.length, 0, "must not exist before deployment");

        vm.prank(ownerUEA);
        address actual = factory.deployAgentWallet(guardian);

        assertEq(actual, predicted, "counterfactual address must be exact");
        assertTrue(factory.isDeployed(ownerUEA));
        assertEq(factory.walletOf(ownerUEA), actual);
    }

    /// @dev The salt must be keccak256(abi.encode(owner)) and nothing else — the SDK
    ///      computes `expectedCEA` from this address before the wallet exists (S-8).
    function test_T01b_saltIsOwnerOnly() public view {
        address predicted = factory.computeAgentWallet(ownerUEA);
        bytes32 salt = keccak256(abi.encode(ownerUEA));
        address expected = vm.computeCreate2Address(salt, keccak256(_cloneInitCode(address(impl))), address(factory));
        assertEq(predicted, expected, "salt must derive from the owner alone");
    }

    // ── T-02 — idempotence (F-13) ─────────────────────────────────────

    /**
     * A second call returns the same address, does NOT revert, and emits
     * `AgentWalletDeployed` EXACTLY ONCE.
     *
     * Why idempotence rather than a revert: Stage B is one atomic UEA multicall
     * (deploy → install → approve → grant → fund). A revert on a benign duplicate deploy
     * would fail the whole multicall and take an otherwise-valid grant down with it.
     * Under Rule 2 a duplicate deploy can damage nothing, so returning is strictly better.
     */
    function test_T02_secondCallIsIdempotentAndEmitsOnce() public {
        vm.recordLogs();

        vm.prank(ownerUEA);
        address first = factory.deployAgentWallet(guardian);

        vm.prank(ownerUEA);
        address second = factory.deployAgentWallet(guardian);

        assertEq(second, first, "must return the existing wallet");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deployEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == AgentWalletDeployed.selector) deployEvents++;
        }
        assertEq(deployEvents, 1, "no event on a re-call: the wallet was already announced");
    }

    /// @dev A re-call with a DIFFERENT guardian must not re-point an existing wallet.
    ///      `deployAgentWallet` returns early, so `initialize` is never reached.
    function test_T02b_reCallCannotOverwriteGuardian() public {
        vm.prank(ownerUEA);
        address w = factory.deployAgentWallet(guardian);

        vm.prank(ownerUEA);
        factory.deployAgentWallet(address(0xDEAD));

        assertEq(PushAgentWallet(payable(w)).guardian(), guardian, "guardian must be unchanged");
    }

    // ── T-03 ──────────────────────────────────────────────────────────

    function test_T03_twoOwnersTwoWallets() public {
        vm.prank(ownerUEA);
        address bobWallet = factory.deployAgentWallet(guardian);

        vm.prank(alice);
        address aliceWallet = factory.deployAgentWallet(guardian);

        assertTrue(bobWallet != aliceWallet, "distinct owners must not collide");
        assertEq(PushAgentWallet(payable(bobWallet)).owner(), ownerUEA);
        assertEq(PushAgentWallet(payable(aliceWallet)).owner(), alice);
    }

    // ── T-04 ──────────────────────────────────────────────────────────

    function test_T04_ownerIsCallerAndGuardianIsArgument() public {
        vm.prank(ownerUEA);
        PushAgentWallet w = PushAgentWallet(payable(factory.deployAgentWallet(guardian)));

        assertEq(w.owner(), ownerUEA, "the caller IS the owner");
        assertEq(w.guardian(), guardian);
        assertFalse(w.sessionsPaused(), "sessions start unpaused");
    }

    function test_T04b_guardianMayBeZero() public {
        vm.prank(ownerUEA);
        PushAgentWallet w = PushAgentWallet(payable(factory.deployAgentWallet(address(0))));

        assertEq(w.guardian(), address(0), "no guardian is a valid configuration");
    }

    // ── T-05 — ABI assertion ──────────────────────────────────────────

    /**
     * The only deploy entrypoint takes exactly ONE argument (the guardian), never an owner.
     *
     * There must be no `deployFor(owner, ...)` variant: a third-party deployment path
     * would let an attacker deploy a victim's wallet against an implementation the victim
     * did not choose. The caller is always the owner, structurally.
     */
    function test_T05_noThirdPartyDeploymentPath() public {
        // The one-arg form is the canonical entrypoint.
        assertEq(
            AgentWalletFactory.deployAgentWallet.selector,
            bytes4(keccak256("deployAgentWallet(address)")),
            "the sole deploy entrypoint takes one argument: the guardian"
        );

        // No two-arg variant under any plausible name.
        string[4] memory forbidden = [
            "deployAgentWallet(address,address)",
            "deployFor(address,address)",
            "deployAgentWalletFor(address,address)",
            "deployAgentWallet(bytes32)"
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            (bool ok,) =
                address(factory).call(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i]))), alice, alice));
            assertFalse(ok, forbidden[i]);
        }

        // An attacker deploying only ever creates a wallet owned by the attacker.
        address attacker = address(0xBAD);
        vm.prank(attacker);
        address attackerWallet = factory.deployAgentWallet(guardian);
        assertEq(PushAgentWallet(payable(attackerWallet)).owner(), attacker);
        assertFalse(factory.isDeployed(ownerUEA), "the victim's slot is untouched");
    }

    function test_T05b_zeroImplementationReverts() public {
        vm.expectRevert(PushWalletErrors.ZeroAddress.selector);
        new AgentWalletFactory(address(0));
    }

    // ── helpers ───────────────────────────────────────────────────────

    /// @dev EIP-1167 minimal-proxy init code, as OpenZeppelin's Clones emits it.
    function _cloneInitCode(address implementation) internal pure returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
