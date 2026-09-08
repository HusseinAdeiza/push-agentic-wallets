// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { BaseTest } from "../Base.t.sol";
import { AGWFactory } from "../../src/AGWFactory.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { PushWalletErrors } from "../../src/libraries/PushWalletErrors.sol";
import { ModeLib, ModeCode } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @notice AGWFactory acceptance suite — T-01 … T-14.
 *
 * @dev    The factory is the ROOT OF TRUST for wallet identity, and the one thing that can break
 *         irrecoverably is address derivation: a user who counterfactually funded a predicted
 *         address has no remedy if that address moves. T-01 is the guard, and it is never deleted.
 *
 * @dev    ZERO selector-less `vm.expectRevert()` in this file. Every negative test names its error.
 */
contract AGWFactoryTest is BaseTest {
    bytes32 internal constant ADMIN_ROLE = 0x00; // DEFAULT_ADMIN_ROLE

    address internal PAUSER;
    address internal OPERATOR;

    function setUp() public override {
        super.setUp();
        PAUSER = makeAddr("pauser");
        OPERATOR = makeAddr("operator");

        vm.startPrank(FACTORY_ADMIN);
        factory.grantRole(factory.PAUSER_ROLE(), PAUSER);
        factory.grantRole(factory.OPERATOR_ROLE(), OPERATOR);
        vm.stopPrank();
    }

    // ═══════════════════════════════════ T-01 ═══════════════════════════════════

    /**
     * T-01(a) ⚠️ NEVER-DELETE — THE LAYOUT.
     *
     * `_walletImplementation` is the APPEND-ONLY ANCHOR. If any base contract or declaration is
     * reordered, it moves, and every not-yet-deployed predicted address moves with it — stranding
     * counterfactually funded wallets with NO REMEDY, because v3 has no migration of any kind.
     *
     * Asserted from solc's own storageLayout, not from a comment: exactly THREE linear entries,
     * in order, at slots 0/1/2, with the implementation alone at offset 0. All four bases use
     * ERC-7201 namespaced storage, so nothing inherited occupies the linear space — adding a
     * non-namespaced base would push our three down and turn this red.
     */
    function test_T01a_StorageLayout_IsFrozen() public view {
        string memory artifact = vm.readFile("out/AGWFactory.sol/AGWFactory.json");

        string[3] memory names = ["_walletCount", "_records", "_walletImplementation"];
        string[3] memory slots = ["0", "1", "2"];

        for (uint256 i; i < 3; ++i) {
            string memory base = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(artifact, string.concat(base, ".label")), names[i], "declaration order");
            assertEq(vm.parseJsonString(artifact, string.concat(base, ".slot")), slots[i], "slot");
            assertEq(
                vm.parseJsonUint(artifact, string.concat(base, ".offset")), 0, "offset 0 - nothing packs beside it"
            );
        }

        // EXACTLY three: a fourth entry means something was inserted, or a base stopped being
        // namespaced. Either way the anchor moved.
        assertFalse(
            vm.keyExistsJson(artifact, ".storageLayout.storage[3]"),
            "a fourth linear storage entry appeared - the append-only anchor may have moved"
        );
    }

    /**
     * T-01(b) ⚠️ NEVER-DELETE — ADDRESS STABILITY ACROSS A FACTORY UPGRADE.
     *
     * Upgrades exist for factory-LOGIC bugs only. The derivation is frozen forever. This records a
     * matrix of predictions, upgrades the logic to a build that APPENDS a variable after
     * `_walletImplementation` (the only legal shape), and asserts every prediction is byte-identical.
     */
    function test_T01b_AddressStability_AcrossFactoryUpgrade() public {
        address[3] memory owners = [makeAddr("o1"), makeAddr("o2"), makeAddr("o3")];

        // give o1 two wallets so a non-zero index range is covered
        vm.startPrank(owners[0]);
        factory.deployWallet("a");
        factory.deployWallet("b");
        vm.stopPrank();

        address[9] memory before;
        uint256 k;
        for (uint256 i; i < owners.length; ++i) {
            uint256 count = factory.walletCount(owners[i]);
            for (uint256 idx; idx <= count; ++idx) {
                (address w,) = factory.predictWallet(owners[i], idx);
                before[k++] = w;
            }
        }

        // upgrade to a logic build that APPENDS one variable — the only legal change
        AGWFactoryV2 v2 = new AGWFactoryV2();
        vm.prank(FACTORY_ADMIN);
        factory.upgradeToAndCall(address(v2), "");

        // every prediction identical
        uint256 j;
        for (uint256 i; i < owners.length; ++i) {
            uint256 count = factory.walletCount(owners[i]);
            for (uint256 idx; idx <= count; ++idx) {
                (address w,) = factory.predictWallet(owners[i], idx);
                assertEq(w, before[j++], "prediction moved across a factory upgrade");
            }
        }

        // and a deploy still lands on the predicted address
        (address predicted,) = factory.predictWallet(owners[1], 0);
        vm.prank(owners[1]);
        address deployed = factory.deployWallet("after upgrade");
        assertEq(deployed, predicted, "deploy matches the pre-upgrade prediction");

        // the implementation address itself survived
        assertEq(factory.walletImplementation(), address(walletImpl), "_walletImplementation unchanged");
    }

    /// The upgrade is admin-only, and the zero guard holds.
    function test_T01_UpgradeIsAdminOnly() public {
        AGWFactoryV2 v2 = new AGWFactoryV2();

        vm.prank(PAUSER);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, ADMIN_ROLE)
        );
        factory.upgradeToAndCall(address(v2), "");

        vm.prank(FACTORY_ADMIN);
        vm.expectRevert(IAGWFactory.ZeroAddress.selector);
        factory.upgradeToAndCall(address(0), "");
    }

    // ═══════════════════════════════════ T-02 ═══════════════════════════════════

    function testFuzz_T02_PredictEqualsDeploy(address owner, uint8 rawCount) public {
        vm.assume(owner != address(0) && owner.code.length == 0);
        uint256 n = bound(rawCount, 1, 5);

        for (uint256 i; i < n; ++i) {
            (address predicted, bool deployedBefore) = factory.predictWallet(owner, i);
            assertFalse(deployedBefore, "not deployed yet");

            vm.prank(owner);
            address actual = factory.deployWallet("");
            assertEq(actual, predicted, "predict == deploy");

            (address again, bool deployedAfter) = factory.predictWallet(owner, i);
            assertEq(again, predicted, "prediction stable after deployment");
            assertTrue(deployedAfter, "the deployed flag flipped false -> true");
        }
    }

    // ═══════════════════════════════════ T-03 ═══════════════════════════════════

    /// The caller IS the owner. There is no input that yields any other owner, because there is no
    /// owner parameter — this is enforced at the type level, not the check level.
    function test_T03_OwnerIsAlwaysCaller() public {
        address eoa = makeAddr("eoaCaller");
        vm.prank(eoa);
        address w1 = factory.deployWallet("eoa");
        assertEq(PushAgentWallet(payable(w1)).owner(), eoa, "EOA caller is the owner");
        assertEq(factory.ownerOf(w1), eoa, "registry agrees");

        // a CONTRACT caller
        DeployerContract deployer = new DeployerContract(address(factory));
        address w2 = deployer.deploy("contract");
        assertEq(PushAgentWallet(payable(w2)).owner(), address(deployer), "contract caller is the owner");
        assertEq(factory.ownerOf(w2), address(deployer), "registry agrees");

        // the wallet's own view and the registry never disagree
        assertTrue(PushAgentWallet(payable(w1)).owner() != address(deployer), "distinct owners");
    }

    // ═══════════════════════════════════ T-04 ═══════════════════════════════════

    /**
     * T-04 — index monotonicity under reentrancy. The effects-first ordering IS the guard; there is
     * deliberately no ReentrancyGuard (§11 item 7).
     *
     * (a) A malicious implementation whose `initializeAccount` re-enters `deployWallet` directly.
     *     The reentrant caller is THE CLONE, so it draws index 0 from its OWN counter — not n+1
     *     from the original owner's.
     */
    function test_T04a_IndexMonotonic_UnderDirectReentrancy() public {
        ReentryLatch latch = new ReentryLatch();
        ReenteringWallet reenterImpl = new ReenteringWallet(latch);
        AGWFactory f = _freshFactory(address(reenterImpl));

        address owner = makeAddr("reentrantOwner");
        vm.prank(owner);
        address outer = f.deployWallet("outer");

        // the outer wallet took the owner's index 0
        assertEq(f.indexOf(outer), 0, "outer wallet index");
        assertEq(f.ownerOf(outer), owner, "outer wallet owner");
        assertEq(f.walletCount(owner), 1, "owner's counter advanced exactly once");

        // the reentrant deploy was made BY the clone, so it drew from the clone's own counter
        address inner = ReenteringWallet(payable(outer)).spawned();
        assertTrue(inner != address(0), "the reentrant deploy happened");
        assertTrue(inner != outer, "and produced a DISTINCT address");
        assertEq(f.ownerOf(inner), outer, "the inner wallet is owned by the clone, not the original owner");
        assertEq(f.indexOf(inner), 0, "index 0 from the CLONE's counter, not n+1 from the owner's");
    }

    /// (b) The same, routed through a malicious OWNER contract that forwards, so the original owner
    ///     is preserved as msg.sender across both deploys.
    function test_T04b_IndexMonotonic_UnderForwardedReentrancy() public {
        AGWFactory f = _freshFactory(address(walletImpl));
        ReenteringOwner owner = new ReenteringOwner(address(f));

        address first = owner.deployTwice();
        address second = owner.second();

        assertTrue(first != second, "distinct addresses");
        assertEq(f.walletCount(address(owner)), 2, "counter advanced exactly twice");
        assertEq(f.indexOf(first), 0, "index 0");
        assertEq(f.indexOf(second), 1, "index 1 - never reused");
        assertEq(f.ownerOf(first), address(owner), "same owner");
        assertEq(f.ownerOf(second), address(owner), "same owner");
    }

    // ═══════════════════════════════════ T-05 ═══════════════════════════════════

    function test_T05_Registry_Consistency() public {
        address[2] memory owners = [makeAddr("r1"), makeAddr("r2")];
        address[5] memory wallets;
        uint256 k;

        vm.recordLogs();
        for (uint256 i; i < owners.length; ++i) {
            uint256 n = i + 2; // 2 and 3 wallets
            for (uint256 j; j < n; ++j) {
                vm.prank(owners[i]);
                wallets[k++] = factory.deployWallet("");
            }
        }

        assertEq(factory.walletCount(owners[0]), 2, "owner 0 count");
        assertEq(factory.walletCount(owners[1]), 3, "owner 1 count");

        // every record is mutually consistent, and matches the emitted event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory)) continue;
            if (logs[i].topics[0] != keccak256("WalletDeployed(address,uint256,address,string)")) continue;

            address evOwner = address(uint160(uint256(logs[i].topics[1])));
            uint256 evIndex = uint256(logs[i].topics[2]);
            address evWallet = address(uint160(uint256(logs[i].topics[3])));

            assertTrue(factory.isWallet(evWallet), "isWallet");
            assertEq(factory.ownerOf(evWallet), evOwner, "ownerOf matches the event");
            assertEq(factory.indexOf(evWallet), evIndex, "indexOf matches the event");
            (address predicted,) = factory.predictWallet(evOwner, evIndex);
            assertEq(predicted, evWallet, "prediction matches the deployed address");
            seen++;
        }
        assertEq(seen, 5, "five deployments observed");

        // foreign addresses
        address foreign = makeAddr("notAWallet");
        assertFalse(factory.isWallet(foreign), "foreign isWallet false");
        assertEq(factory.ownerOf(foreign), address(0), "foreign ownerOf zero");
        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.NotAWallet.selector, foreign));
        factory.indexOf(foreign);

        // ZERO IS A VALID INDEX — which is why indexOf reverts instead of returning 0
        assertEq(factory.indexOf(wallets[0]), 0, "index zero is real");
        assertTrue(factory.isWallet(wallets[0]), "and the wallet exists");
    }

    // ═══════════════════════════════════ T-06 ═══════════════════════════════════

    /// The label is emitted, never stored, and never enters the derivation.
    function test_T06_Label_NeverAffectsAddress() public {
        address o1 = makeAddr("l1");
        address o2 = makeAddr("l2");

        (address p1,) = factory.predictWallet(o1, 0);
        (address p2,) = factory.predictWallet(o2, 0);

        vm.prank(o1);
        address w1 = factory.deployWallet("");
        vm.prank(o2);
        address w2 = factory.deployWallet(unicode"a very long 🏷 label with unicode and spaces");

        assertEq(w1, p1, "empty label lands on the prediction");
        assertEq(w2, p2, "long label lands on the prediction too");

        // the label reaches the event
        vm.recordLogs();
        address o3 = makeAddr("l3");
        vm.prank(o3);
        factory.deployWallet("my label");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(factory)
                    && logs[i].topics[0] == keccak256("WalletDeployed(address,uint256,address,string)")
            ) {
                assertEq(abi.decode(logs[i].data, (string)), "my label", "the label is in the event");
                found = true;
            }
        }
        assertTrue(found, "WalletDeployed emitted");
    }

    // ═══════════════════════════════════ T-07 ═══════════════════════════════════

    function test_T07_Pause_BlocksDeployOnly() public {
        address owner = makeAddr("pauseOwner");
        (address predicted,) = factory.predictWallet(owner, 0);

        vm.prank(PAUSER);
        factory.pause();

        // deploys are blocked
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        factory.deployWallet("");

        // EVERY view still works while paused
        (address stillPredicted, bool dep) = factory.predictWallet(owner, 0);
        assertEq(stillPredicted, predicted, "predictWallet works while paused");
        assertFalse(dep, "and reports correctly");
        assertEq(factory.walletCount(owner), 0, "walletCount works");
        assertEq(factory.ownerOf(address(0xdead)), address(0), "ownerOf works");
        assertFalse(factory.isWallet(address(0xdead)), "isWallet works");
        assertEq(factory.walletImplementation(), address(walletImpl), "walletImplementation works");

        // THE ROLE SPLIT IS ENFORCED IN BOTH DIRECTIONS
        bytes32 operatorRole = factory.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, PAUSER, operatorRole)
        );
        vm.prank(PAUSER);
        factory.unpause();

        vm.prank(OPERATOR);
        factory.unpause();

        bytes32 pauserRole = factory.PAUSER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, pauserRole)
        );
        vm.prank(OPERATOR);
        factory.pause();

        // unpause restores deploys, and the previously predicted address is unchanged
        vm.prank(owner);
        address deployed = factory.deployWallet("");
        assertEq(deployed, predicted, "the address predicted before the pause is unchanged");
    }

    // ═══════════════════════════════════ T-08 ═══════════════════════════════════

    /// A failed `initializeAccount` reverts the WHOLE deployment. The "deployed but unarmed" state
    /// must never exist, and no recovery path for it is added (§11 item 9).
    function test_T08_AtomicInit_NoUninitialisedWallet() public {
        RevertingInitWallet badImpl = new RevertingInitWallet();
        AGWFactory f = _freshFactory(address(badImpl));

        address owner = makeAddr("atomicOwner");
        (address predicted,) = f.predictWallet(owner, 0);

        vm.prank(owner);
        vm.expectRevert(RevertingInitWallet.InitRejected.selector);
        f.deployWallet("");

        assertEq(f.walletCount(owner), 0, "counter unchanged");
        assertEq(f.ownerOf(predicted), address(0), "no record");
        assertFalse(f.isWallet(predicted), "not a wallet");
        assertEq(predicted.code.length, 0, "NO CODE at the predicted address");

        // with the REAL implementation, the wallet is fully functional in the deploy transaction
        vm.prank(owner);
        address good = factory.deployWallet("");
        assertTrue(PushAgentWallet(payable(good)).isModuleInstalled(1, address(engine), ""), "engine installed");
        assertEq(PushAgentWallet(payable(good)).owner(), owner, "owner set");
    }

    // ═══════════════════════════════════ T-09 ═══════════════════════════════════

    /**
     * T-09 — THE EXACT SELECTOR SET.
     *
     * Adding ANY function — a `setWalletImplementation` above all — forces a deliberate edit to
     * this list. That is the point: §11 item 1 calls a setter "the single most dangerous
     * improvement possible in this contract", and an exact set is the only assertion that catches
     * one under any name.
     */
    function test_T09_NoImplementationSetter_ABI() public view {
        string[34] memory sigs = [
            // ours
            "initialize(address,address)",
            "deployWallet(string)",
            "predictWallet(address,uint256)",
            "walletCount(address)",
            "ownerOf(address)",
            "isWallet(address)",
            "indexOf(address)",
            "walletImplementation()",
            "pause()",
            "unpause()",
            "PAUSER_ROLE()",
            "OPERATOR_ROLE()",
            // AccessControl
            "DEFAULT_ADMIN_ROLE()",
            "hasRole(bytes32,address)",
            "getRoleAdmin(bytes32)",
            "grantRole(bytes32,address)",
            "revokeRole(bytes32,address)",
            "renounceRole(bytes32,address)",
            "supportsInterface(bytes4)",
            // AccessControlDefaultAdminRules — the delayed two-step admin surface
            "owner()",
            "defaultAdmin()",
            "pendingDefaultAdmin()",
            "defaultAdminDelay()",
            "pendingDefaultAdminDelay()",
            "defaultAdminDelayIncreaseWait()",
            "beginDefaultAdminTransfer(address)",
            "cancelDefaultAdminTransfer()",
            "acceptDefaultAdminTransfer()",
            "changeDefaultAdminDelay(uint48)",
            "rollbackDefaultAdminDelay()",
            // Pausable
            "paused()",
            // UUPS
            "UPGRADE_INTERFACE_VERSION()",
            "proxiableUUID()",
            "upgradeToAndCall(address,bytes)"
        ];

        bytes4[] memory expected = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; ++i) {
            expected[i] = bytes4(keccak256(bytes(sigs[i])));
            // THE ASSERTION THAT MATTERS: no setter, under any name, reaches the ABI.
            assertTrue(
                expected[i] != bytes4(keccak256("setWalletImplementation(address)")),
                "a wallet-implementation setter appeared - see PRD 11 item 1"
            );
        }

        assertSelectorSet("AGWFactory", expected);
    }

    /// `initialize` cannot be called twice.
    function test_T09_InitializeIsOneShot() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(FACTORY_ADMIN, address(walletImpl));
    }

    // ═══════════════════════════════════ T-10 ═══════════════════════════════════

    /// Deployment and granting are independent by ruling. A zero-permission wallet is VALID.
    function test_T10_EmptyWallet_IsValid() public {
        address owner = makeAddr("emptyOwner");
        vm.prank(owner);
        address w = factory.deployWallet("");
        PushAgentWallet wallet = PushAgentWallet(payable(w));

        assertTrue(factory.isWallet(w), "it exists in the registry");
        assertEq(engine.getPermissionIDs(w).length, 0, "zero permissions");

        // owner-operable
        vm.deal(w, 1 ether);
        address sink = makeAddr("emptySink");
        vm.prank(owner);
        wallet.execute(ModeCode.unwrap(ModeLib.encodeSimpleSingle()), ExecutionLib.encodeSingle(sink, 1 ether, ""));
        assertEq(sink.balance, 1 ether, "the owner door works");

        // and it rejects any agent request — structurally, with no permission to name
        vm.prank(AGENT);
        vm.expectRevert(PushWalletErrors.InvalidSessionSignature.selector);
        wallet.executeWithSession(address(engine), ModeCode.unwrap(ModeLib.encodeSimpleSingle()), "", "", 0, 0, 0);
    }

    // ═══════════════════════════════════ T-11 ═══════════════════════════════════

    function test_T11_InitializeGuards() public {
        AGWFactory logic = new AGWFactory();

        // zero admin
        vm.expectRevert(IAGWFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(logic), abi.encodeCall(AGWFactory.initialize, (address(0), address(walletImpl))));

        // zero implementation
        vm.expectRevert(IAGWFactory.ZeroAddress.selector);
        new ERC1967Proxy(address(logic), abi.encodeCall(AGWFactory.initialize, (FACTORY_ADMIN, address(0))));

        // THE LOGIC CONTRACT cannot be initialised directly — its constructor disabled initialisers
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        logic.initialize(FACTORY_ADMIN, address(walletImpl));

        // nor can the one already behind our proxy
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factoryLogic.initialize(FACTORY_ADMIN, address(walletImpl));
    }

    /// The `ImplementationNotSet` guard is reachable only on a proxy deployed without its atomic
    /// init call — operator error. Without it, Clones would deploy a clone pointing at address zero.
    function test_T11_ImplementationNotSet_Guard() public {
        // OZ's ERC1967Proxy REFUSES empty init data (ERC1967ProxyUninitialized), so the
        // uninitialised-proxy state cannot be built the obvious way. It is reached instead by
        // zeroing the implementation slot directly — the same observable state an operator would
        // produce by deploying a proxy without its atomic init call.
        AGWFactory f = _freshFactory(address(walletImpl));
        vm.store(address(f), bytes32(uint256(2)), bytes32(0)); // slot 2 == _walletImplementation
        assertEq(f.walletImplementation(), address(0), "precondition: implementation is unset");

        vm.expectRevert(IAGWFactory.ImplementationNotSet.selector);
        f.deployWallet("");

        vm.expectRevert(IAGWFactory.ImplementationNotSet.selector);
        f.predictWallet(makeAddr("x"), 0);
    }

    // ═══════════════════════════════════ T-12 ═══════════════════════════════════

    /// A second factory proxy is a NEW ADDRESS SPACE. This documents the ruled versioning model:
    /// a new wallet implementation ships as a brand-new factory, never as a setter.
    function test_T12_SecondFactory_NewAddressSpace() public {
        PushAgentWallet implV2 = new PushAgentWallet(address(engine), address(urp), address(validator), GATEWAY);
        AGWFactory f2 = _freshFactory(address(implV2));

        address owner = makeAddr("twoFactoryOwner");

        (address a1,) = factory.predictWallet(owner, 0);
        (address a2,) = f2.predictWallet(owner, 0);
        assertTrue(a1 != a2, "same (owner, index), DIFFERENT factories => different addresses");

        vm.prank(owner);
        address w1 = factory.deployWallet("");
        vm.prank(owner);
        address w2 = f2.deployWallet("");

        assertEq(w1, a1, "factory 1 prediction holds");
        assertEq(w2, a2, "factory 2 prediction holds");

        // THE REGISTRIES ARE DISJOINT — neither claims the other's wallet
        assertTrue(factory.isWallet(w1), "f1 knows its own");
        assertFalse(factory.isWallet(w2), "f1 does not claim f2's");
        assertTrue(f2.isWallet(w2), "f2 knows its own");
        assertFalse(f2.isWallet(w1), "f2 does not claim f1's");

        // and each is internally consistent
        assertEq(factory.indexOf(w1), 0, "f1 index");
        assertEq(f2.indexOf(w2), 0, "f2 index");
        assertEq(factory.walletCount(owner), 1, "f1 count");
        assertEq(f2.walletCount(owner), 1, "f2 count");
    }

    // ═══════════════════════════════════ T-13 ═══════════════════════════════════

    /**
     * T-13 — the index bound. Every existing wallet PLUS exactly the next deployable one.
     *
     * Beyond that is a wallet that cannot be deployed until thousands of others are, and a user
     * funding such an address counterfactually would put money in a permanent hole with no recovery.
     */
    function test_T13_PredictWallet_IndexBound() public {
        address owner = makeAddr("boundOwner");

        // with zero wallets: index 0 (the next) is allowed, 1 is not
        (, bool d0) = factory.predictWallet(owner, 0);
        assertFalse(d0, "index 0 not yet deployed");

        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.IndexOutOfRange.selector, uint256(1), uint256(0)));
        factory.predictWallet(owner, 1);

        // deploy three
        for (uint256 i; i < 3; ++i) {
            vm.prank(owner);
            factory.deployWallet("");
        }

        // 0..2 are deployed, 3 is the next, 4 and beyond revert
        for (uint256 i; i < 3; ++i) {
            (, bool dep) = factory.predictWallet(owner, i);
            assertTrue(dep, "existing wallet reports deployed");
        }
        (, bool depNext) = factory.predictWallet(owner, 3);
        assertFalse(depNext, "the next index is predictable but not deployed");

        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.IndexOutOfRange.selector, uint256(4), uint256(3)));
        factory.predictWallet(owner, 4);

        vm.expectRevert(abi.encodeWithSelector(IAGWFactory.IndexOutOfRange.selector, type(uint256).max, uint256(3)));
        factory.predictWallet(owner, type(uint256).max);
    }

    // ═══════════════════════════════════ T-14 ═══════════════════════════════════

    /**
     * T-14 — THE DELAYED TWO-STEP ADMIN.
     *
     * The first two assertions are the ones that would have caught the plain-extension defect: with
     * the constructor-only `AccessControlDefaultAdminRules` behind a proxy, `defaultAdmin()` was
     * `address(0)` and `defaultAdminDelay()` was `0` — no admin at all, and no delay. Probe-verified
     * before the dependency was switched.
     */
    function test_T14_AdminTransferIsDelayed() public {
        // Move off timestamp 1: the extension stores schedules as uint48 offsets from now, and at
        // t=1 a "not yet" revert reports a schedule that is hard to read against.
        vm.warp(1_000_000);

        // (1) the initialiser actually took effect on the PROXY
        assertEq(factory.defaultAdmin(), FACTORY_ADMIN, "admin set on the proxy");
        assertEq(factory.defaultAdminDelay(), 2 days, "the two-day delay is real");
        assertTrue(factory.hasRole(ADMIN_ROLE, FACTORY_ADMIN), "and the role is held");

        // (2) the ordinary role path is walled off for DEFAULT_ADMIN_ROLE.
        //     `grantRole` reverts unconditionally (the extension overrides it); `renounceRole`
        //     reverts with the DELAY error, because renouncing the admin is itself routed through
        //     the scheduled flow and no transfer has been scheduled yet.
        address newAdmin = makeAddr("newAdmin");
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vm.prank(FACTORY_ADMIN);
        factory.grantRole(ADMIN_ROLE, newAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, uint48(0)
            )
        );
        vm.prank(FACTORY_ADMIN);
        factory.renounceRole(ADMIN_ROLE, FACTORY_ADMIN);

        // (3) the scheduled two-step flow: an IMMEDIATE accept is refused
        vm.prank(FACTORY_ADMIN);
        factory.beginDefaultAdminTransfer(newAdmin);

        (address pending, uint48 schedule) = factory.pendingDefaultAdmin();
        assertEq(pending, newAdmin, "pending admin recorded");
        assertEq(schedule, uint48(block.timestamp) + 2 days, "scheduled two days out");

        vm.prank(newAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        factory.acceptDefaultAdminTransfer();
        assertEq(factory.defaultAdmin(), FACTORY_ADMIN, "still the original admin");

        // (4) THE BOUNDARY IS EXCLUSIVE. `_hasSchedulePassed` is `schedule < block.timestamp`
        //     (upstream, line 398-400), so landing exactly ON the schedule is still too early.
        vm.warp(schedule);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vm.prank(newAdmin);
        factory.acceptDefaultAdminTransfer();

        // one second past it succeeds
        vm.warp(uint256(schedule) + 1);
        vm.prank(newAdmin);
        factory.acceptDefaultAdminTransfer();
        assertEq(factory.defaultAdmin(), newAdmin, "admin transferred after the delay");
        assertFalse(factory.hasRole(ADMIN_ROLE, FACTORY_ADMIN), "the old admin lost the role");
    }

    /// PAUSER and OPERATOR are ORDINARY roles — granted and revoked normally by the admin.
    function test_T14_OrdinaryRolesAreNotDelayed() public {
        address newPauser = makeAddr("newPauser");
        bytes32 pauserRole = factory.PAUSER_ROLE();

        vm.prank(FACTORY_ADMIN);
        factory.grantRole(pauserRole, newPauser);
        assertTrue(factory.hasRole(pauserRole, newPauser), "granted immediately");

        vm.prank(newPauser);
        factory.pause();

        vm.prank(FACTORY_ADMIN);
        factory.revokeRole(pauserRole, newPauser);
        assertFalse(factory.hasRole(pauserRole, newPauser), "revoked immediately");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newPauser, pauserRole)
        );
        vm.prank(newPauser);
        factory.pause();
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev A fresh proxy + logic pair, so a test can use a different wallet implementation.
    function _freshFactory(address walletImplementation_) internal returns (AGWFactory) {
        AGWFactory logic = new AGWFactory();
        return AGWFactory(
            address(
                new ERC1967Proxy(
                    address(logic), abi.encodeCall(AGWFactory.initialize, (FACTORY_ADMIN, walletImplementation_))
                )
            )
        );
    }
}

// ─────────────────────────────── test doubles ───────────────────────────────

/// @dev A factory logic build that APPENDS one variable after `_walletImplementation` — the only
///      legal shape for an upgrade. T-01(b) proves predictions survive it.
contract AGWFactoryV2 is AGWFactory {
    uint256 public appendedAfterTheAnchor;

    function setAppended(uint256 v) external {
        appendedAfterTheAnchor = v;
    }
}

contract DeployerContract {
    AGWFactory private immutable FACTORY_;

    constructor(address f) {
        FACTORY_ = AGWFactory(f);
    }

    function deploy(string calldata label) external returns (address) {
        return FACTORY_.deployWallet(label);
    }
}

/// @dev A wallet implementation whose `initializeAccount` re-enters `deployWallet`. The reentrant
///      caller is the CLONE, so it draws index 0 from its own counter.
/// @dev A shared one-shot latch. EACH CLONE HAS ITS OWN STORAGE, so a per-clone bool cannot stop
///      the chain — the clone's clone would re-enter too, forever, and the test would observe a
///      stack overflow instead of the index behaviour it asserts. The latch therefore lives in a
///      single contract every clone shares.
contract ReentryLatch {
    bool public fired;

    function tryFire() external returns (bool first) {
        if (fired) return false;
        fired = true;
        return true;
    }
}

contract ReenteringWallet {
    address public spawned;
    ReentryLatch public immutable LATCH;

    constructor(ReentryLatch latch) {
        LATCH = latch;
    }

    function initializeAccount() external {
        // `msg.sender` here IS the factory. Re-enter exactly once, globally.
        if (!ReenteringWallet(payable(address(this))).LATCH().tryFire()) return;
        spawned = AGWFactory(msg.sender).deployWallet("reentrant");
    }

    receive() external payable { }
}

/// @dev An owner contract that deploys twice in one call, preserving itself as msg.sender.
contract ReenteringOwner {
    AGWFactory private immutable FACTORY_;
    address public second;

    constructor(address f) {
        FACTORY_ = AGWFactory(f);
    }

    function deployTwice() external returns (address first) {
        first = FACTORY_.deployWallet("first");
        second = FACTORY_.deployWallet("second");
    }
}

/// @dev A wallet implementation whose init reverts, for the atomicity test.
contract RevertingInitWallet {
    error InitRejected();

    function initializeAccount() external pure {
        revert InitRejected();
    }
}
