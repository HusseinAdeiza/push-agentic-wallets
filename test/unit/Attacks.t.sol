// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { MockValidator, MockTarget } from "../mocks/Mocks.sol";

/**
 * @notice PRD §12 — attacks whose demonstrating test is not already named inline in
 *         another suite. The remaining attacks (A-02 … A-12, A-14 … A-16) are covered
 *         by tests carrying their id in the test name.
 */
contract AttacksTest is Test {
    PushAgentWallet internal impl;
    AgentWalletFactory internal factory;
    PushAgentWallet internal wallet;
    MockValidator internal validator;
    MockTarget internal target;

    address internal ownerUEA = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() public {
        impl = _newImpl();
        factory = new AgentWalletFactory(address(impl));
        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(address(0))));

        validator = new MockValidator();
        target = new MockTarget();
    }

    /**
     * A-01 — module type confusion: a validator must never be usable as an executor.
     *
     * `_modules` is keyed type-first (`type => address => bool`), so installing a
     * module as type 1 grants it nothing under any other type id. Executors (2) and
     * fallbacks (3) are additionally not installable at all (D-04, D-07).
     */
    function test_A01_moduleTypeConfusionPrevented() public {
        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");

        // Installed as a validator...
        assertTrue(wallet.isModuleInstalled(1, address(validator), ""), "type 1 granted");

        // ...and as nothing else.
        assertFalse(wallet.isModuleInstalled(2, address(validator), ""), "must not be an executor");
        assertFalse(wallet.isModuleInstalled(3, address(validator), ""), "must not be a fallback");
        assertFalse(wallet.isModuleInstalled(4, address(validator), ""), "must not be a hook");
        for (uint256 t = 5; t <= 8; ++t) {
            assertFalse(wallet.isModuleInstalled(t, address(validator), ""));
        }

        // The executor type can never be granted in the first place.
        vm.expectRevert(abi.encodeWithSelector(PushWalletErrors.UnsupportedModuleType.selector, uint256(2)));
        vm.prank(ownerUEA);
        wallet.installModule(2, address(validator), "");

        // There is no executor entry point at all.
        (bool ok,) =
            address(wallet).call(abi.encodeWithSignature("executeFromExecutor(bytes32,bytes)", bytes32(0), bytes("")));
        assertFalse(ok, "executeFromExecutor must not exist");
    }

    /**
     * A-13 — the implementation contract must not be initializable by an attacker.
     *
     * The deploy script seals it by initializing to 0xdead (§10.2). This test
     * demonstrates both halves: an unsealed implementation is claimable, and once
     * sealed it is permanently inert.
     */
    function test_A13_implementationSealedAgainstDirectInitialization() public {
        PushAgentWallet fresh = _newImpl();

        // Seal it exactly as Deploy.s.sol does. The burn now takes two arguments; the
        // guardian is address(0) because the implementation is never used as a wallet.
        fresh.initialize(address(0xdead), address(0));
        assertEq(fresh.owner(), address(0xdead));

        // An attacker can no longer claim it.
        vm.expectRevert(PushWalletErrors.AlreadyInitialized.selector);
        vm.prank(attacker);
        fresh.initialize(attacker, attacker);

        assertEq(fresh.owner(), address(0xdead), "owner must be unchanged");
    }

    /**
     * A-13b — clones are unaffected by the implementation's own state. Sealing the
     * logic contract must not stop the factory minting usable wallets.
     */
    function test_A13b_clonesUnaffectedBySealedImplementation() public {
        // The production implementation is sealed...
        PushAgentWallet sealedImpl = _newImpl();
        sealedImpl.initialize(address(0xdead), address(0));

        AgentWalletFactory f = new AgentWalletFactory(address(sealedImpl));

        // ...yet clones initialize normally to their real owner.
        vm.prank(ownerUEA);
        PushAgentWallet clone = PushAgentWallet(payable(f.deployAgentWallet(address(0))));
        assertEq(clone.owner(), ownerUEA);

        // And the clone itself cannot be re-initialized.
        vm.expectRevert(PushWalletErrors.AlreadyInitialized.selector);
        vm.prank(attacker);
        clone.initialize(attacker, attacker);
    }

    /**
     * A-13c — a counterfactual address cannot be front-run, because the clone does
     * not exist until `cloneDeterministic` returns, and the factory initializes it
     * atomically in the same transaction (§5.8).
     */
    function test_A13c_counterfactualAddressCannotBeFrontRunInitialized() public {
        // Rule 2: the counterfactual address derives from the owner alone. Use a fresh
        // owner, since ownerUEA's wallet is already deployed in setUp.
        address victim = address(0x7135);
        address predicted = factory.computeAgentWallet(victim);

        // Nothing is deployed there yet.
        assertEq(predicted.code.length, 0, "must not exist yet");

        // An attacker cannot initialize a non-existent contract.
        vm.prank(attacker);
        (bool ok,) = predicted.call(abi.encodeCall(PushAgentWallet.initialize, (attacker, attacker)));
        assertTrue(ok, "call to an empty address is a no-op success");
        assertEq(predicted.code.length, 0, "still nothing there");

        // The rightful owner deploys and is initialized atomically.
        vm.prank(victim);
        address actual = factory.deployAgentWallet(address(0));
        assertEq(actual, predicted);
        assertEq(PushAgentWallet(payable(actual)).owner(), victim, "owner must be the deployer");
    }

    /// Only the true owner may deploy under their own identity — there is no deployFor.
    function test_A13d_noThirdPartyDeploymentPath() public {
        address victim = address(0x7135);

        // The attacker deploying only ever creates a wallet owned by the attacker.
        vm.prank(attacker);
        address attackerWallet = factory.deployAgentWallet(address(0));
        assertEq(PushAgentWallet(payable(attackerWallet)).owner(), attacker);

        // The victim's own slot is untouched and still available to them.
        assertFalse(factory.isDeployed(victim));
        vm.prank(victim);
        address victimWallet = factory.deployAgentWallet(address(0));
        assertEq(PushAgentWallet(payable(victimWallet)).owner(), victim);
        assertTrue(victimWallet != attackerWallet);
    }

    /// @dev v2 constructor takes five module addresses. This suite tests the wallet's own
    ///      guards, not the session path, so placeholders suffice.
    function _newImpl() internal returns (PushAgentWallet) {
        return new PushAgentWallet(address(0x5511), address(0x6A7E), address(0xAC90), address(0x71FE), address(0x0A11));
    }
}
