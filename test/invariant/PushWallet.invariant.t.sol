// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../../src/AgentWalletFactory.sol";
import { ModeLib } from "../../src/libraries/ModeLib.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";
import { MockValidator, MockTarget, MockHook } from "../mocks/Mocks.sol";

/**
 * @notice Drives the wallet through arbitrary sequences of every state-changing
 *         entry point, so the invariants are checked against real usage.
 */
contract WalletHandler is Test {
    PushAgentWallet public wallet;
    MockValidator public validator;
    MockTarget public target;
    address public owner;

    uint192[] public keysUsed;
    mapping(uint192 => bool) internal _seen;

    // Ghost variables.
    uint256 public ghost_valueOut;
    uint256 public ghost_valueIn;
    mapping(uint192 => uint64) public ghost_maxNonceSeen;

    address public hookA;
    address public hookB;

    constructor(PushAgentWallet w, MockValidator v, MockTarget t, address o, address a, address b) {
        wallet = w;
        validator = v;
        target = t;
        owner = o;
        hookA = a;
        hookB = b;
    }

    /// Candidate modules, including two hooks so the single-active-hook invariant
    /// (N-02b) is genuinely exercised rather than vacuously true.
    function _moduleFor(uint256 seed) internal view returns (address) {
        uint256 k = seed % 4;
        if (k == 0) return address(validator);
        if (k == 1) return address(target);
        if (k == 2) return hookA;
        return hookB;
    }

    function _track(uint192 key) internal {
        if (!_seen[key]) {
            _seen[key] = true;
            keysUsed.push(key);
        }
        uint64 n = wallet.nonce(key);
        if (n > ghost_maxNonceSeen[key]) ghost_maxNonceSeen[key] = n;
    }

    function keysUsedLength() external view returns (uint256) {
        return keysUsed.length;
    }

    function executeSingle(uint256 v, uint96 value) external {
        value = uint96(bound(value, 0, address(wallet).balance));
        bytes memory cd = ExecutionLib.encodeSingle(address(target), value, abi.encodeCall(MockTarget.setValue, (v)));
        vm.prank(owner);
        try wallet.execute(ModeLib.encodeSimpleSingle(), cd) {
            ghost_valueOut += value;
        } catch { }
    }

    function executeWithSession(uint192 key, uint256 v, uint96 value) external {
        value = uint96(bound(value, 0, address(wallet).balance));
        uint64 seq = wallet.nonce(key);
        bytes memory cd = ExecutionLib.encodeSingle(address(target), value, abi.encodeCall(MockTarget.setValue, (v)));
        try wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, "", key, seq) {
            ghost_valueOut += value;
        } catch { }
        _track(key);
    }

    function executeWithBadNonce(uint192 key, uint64 seq) external {
        bytes memory cd = ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (1)));
        try wallet.executeWithSession(address(validator), ModeLib.encodeSimpleSingle(), cd, "", key, seq) { } catch { }
        _track(key);
    }

    function installModule(uint256 typeId, uint256 moduleSeed) external {
        typeId = bound(typeId, 0, 8);
        address module = _moduleFor(moduleSeed);
        vm.prank(owner);
        try wallet.installModule(typeId, module, "") { } catch { }
    }

    function uninstallModule(uint256 typeId, uint256 moduleSeed) external {
        typeId = bound(typeId, 0, 8);
        address module = _moduleFor(moduleSeed);
        vm.prank(owner);
        try wallet.uninstallModule(typeId, module, "") { } catch { }
    }

    function sweepPC(uint96 amount) external {
        amount = uint96(bound(amount, 0, address(wallet).balance));
        vm.prank(owner);
        try wallet.sweepPC(payable(address(0xD35)), amount) {
            ghost_valueOut += amount;
        } catch { }
    }

    function tryUnauthorizedExecute(address caller, uint256 v) external {
        if (caller == owner || caller == address(wallet)) return;
        bytes memory cd = ExecutionLib.encodeSingle(address(target), 0, abi.encodeCall(MockTarget.setValue, (v)));
        vm.prank(caller);
        try wallet.execute(ModeLib.encodeSimpleSingle(), cd) { } catch { }
    }

    function tryReinitialize(address newOwner) external {
        try wallet.initialize(newOwner) { } catch { }
    }

    function fund(uint96 amount) external {
        amount = uint96(bound(amount, 0, 10 ether));
        vm.deal(address(this), amount);
        (bool ok,) = address(wallet).call{ value: amount }("");
        if (ok) ghost_valueIn += amount;
    }

    receive() external payable { }
}

/// @notice PRD §11.7 — invariants N-01 … N-05.
contract PushWalletInvariantTest is Test {
    PushAgentWallet internal wallet;
    AgentWalletFactory internal factory;
    MockValidator internal validator;
    MockTarget internal target;
    WalletHandler internal handler;

    address internal ownerUEA = address(0xB0B);

    function setUp() public {
        PushAgentWallet impl = new PushAgentWallet();
        factory = new AgentWalletFactory(address(impl));
        vm.prank(ownerUEA);
        wallet = PushAgentWallet(payable(factory.deployAgentWallet(keccak256("inv"))));

        validator = new MockValidator();
        target = new MockTarget();

        vm.prank(ownerUEA);
        wallet.installModule(1, address(validator), "");

        vm.deal(address(wallet), 100 ether);

        handler =
            new WalletHandler(wallet, validator, target, ownerUEA, address(new MockHook()), address(new MockHook()));
        targetContract(address(handler));
    }

    /// N-01 — owner never changes after initialize.
    function invariant_N01_ownerNeverChanges() public view {
        assertEq(wallet.owner(), ownerUEA, "owner is immutable in behaviour");
    }

    /// N-02 — a module never appears installed under a type it was not installed for.
    function invariant_N02_noModuleTypeConfusion() public view {
        // Executors and fallbacks can never be installed at all (D-04, D-07).
        assertFalse(wallet.isModuleInstalled(2, address(validator), ""), "executor slot must stay empty");
        assertFalse(wallet.isModuleInstalled(3, address(validator), ""), "fallback slot must stay empty");
        assertFalse(wallet.isModuleInstalled(2, address(target), ""));
        assertFalse(wallet.isModuleInstalled(3, address(target), ""));

        // Unsupported type ids are never installable.
        for (uint256 t = 5; t <= 8; ++t) {
            assertFalse(wallet.isModuleInstalled(t, address(validator), ""));
            assertFalse(wallet.isModuleInstalled(t, address(target), ""));
        }
        assertFalse(wallet.isModuleInstalled(0, address(validator), ""));
    }

    /**
     * N-02b — AT MOST ONE address may be installed as a hook at any time (Q8).
     *
     * This is the property that makes the emergencyRevokeAll fix correct: because
     * installModule rejects a second hook, `_hook` is provably the only address with
     * _modules[4][.] == true, so clearing it is complete. Machine-checked rather
     * than argued.
     */
    function invariant_N02b_atMostOneActiveHook() public view {
        uint256 count;
        if (wallet.isModuleInstalled(4, handler.hookA(), "")) ++count;
        if (wallet.isModuleInstalled(4, handler.hookB(), "")) ++count;
        if (wallet.isModuleInstalled(4, address(handler.validator()), "")) ++count;
        if (wallet.isModuleInstalled(4, address(handler.target()), "")) ++count;
        assertLe(count, 1, "at most one hook may ever be installed");
    }

    /**
     * N-03 / N-04 — native PC leaves the wallet only via execute, executeWithSession,
     * or sweepPC. Every one of those paths credits `ghost_valueOut`, so the balance is
     * fully explained by: seed + everything funded in − everything sanctioned out.
     * Any unattributed outflow (a path we did not sanction) breaks this equality.
     */
    function invariant_N03_N04_balanceOnlyDecreasesThroughSanctionedPaths() public view {
        assertEq(
            address(wallet).balance,
            100 ether + handler.ghost_valueIn() - handler.ghost_valueOut(),
            "all outflow must be attributable to a sanctioned path"
        );
    }

    /// N-05 — _nonces[key] is non-decreasing.
    function invariant_N05_nonceNonDecreasing() public view {
        uint256 len = handler.keysUsedLength();
        for (uint256 i; i < len; ++i) {
            uint192 key = handler.keysUsed(i);
            assertGe(wallet.nonce(key), handler.ghost_maxNonceSeen(key), "nonce must never decrease");
        }
    }

    /// The wallet can never be re-initialized to a different owner.
    function invariant_walletStaysInitialized() public view {
        assertTrue(wallet.owner() != address(0), "must remain initialized");
    }
}
