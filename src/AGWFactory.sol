// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlDefaultAdminRulesUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IAGWFactory } from "./interfaces/IAGWFactory.sol";
import { IPushAgentWalletInit } from "./interfaces/IPushAgentWalletInit.sol";

/**
 * @title  AGWFactory
 * @notice Deploys `PushAgentWallet` clones at addresses computable BEFORE deployment, and is the
 *         ROOT OF TRUST for wallet identity.
 *
 * @dev    Anyone can deploy a contract with a lying `owner()` view; only this registry proves
 *         provenance. The full audit chain is: destination account -> wallet -> FACTORY REGISTRY
 *         -> owner.
 *
 * @dev    THE CALLER IS ALWAYS THE OWNER. There is no owner parameter, which makes deploying a
 *         wallet owned by someone else impossible at the TYPE level, not the check level.
 *
 * @dev    WHAT THIS CONTRACT NEVER DOES: hold funds (no receive, no fallback, no token logic);
 *         touch a wallet after deployment (no upgrade, no migration, no admin reach — ever);
 *         accept an implementation parameter at deploy time or any policy/agent/mandate data;
 *         change the wallet implementation after initialisation (NO SETTER EXISTS).
 *
 * @dev    DEPLOYMENT SHAPE: ERC-1967 proxy -> this implementation (UUPS). The PROXY address is the
 *         permanent, user-facing factory address; it never changes across logic upgrades.
 */
contract AGWFactory is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IAGWFactory
{
    // ──────────────────────────── roles & constants ────────────────────────────

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /**
     * @dev THE DELAY MATTERS MORE HERE THAN ANYWHERE ELSE IN THE SYSTEM. This admin's one real
     *      power is authorising a UUPS upgrade of the factory logic, and a careless upgrade is the
     *      single action that can permanently strand counterfactually funded addresses. Admin
     *      transfer is therefore two-step and time-delayed, never instant — and `grantRole` /
     *      `renounceRole` on DEFAULT_ADMIN_ROLE revert by design, the extension forcing the
     *      scheduled flow.
     */
    uint48 internal constant DEFAULT_ADMIN_DELAY = 2 days;

    // ─────────────────────── storage — exact, ordered, frozen ───────────────────────

    // DECLARATION ORDER IS NORMATIVE. All four bases use ERC-7201 namespaced storage, so NO
    // inherited variable occupies the linear slot space and these three sit at slots 0, 1, 2.
    // The storage-layout test asserts exactly that, reading `forge inspect` output rather than
    // trusting this comment.

    /// @dev owner => number of wallets deployed for them. DOUBLES AS THE NEXT INDEX — one value,
    ///      one slot, no way for a count and a "next index" to drift apart. `uint96` so it matches
    ///      `WalletRecord.index` exactly: no narrowing cast anywhere in this contract.
    mapping(address => uint96) internal _walletCount;

    /// @dev wallet => its record. `record.owner == address(0)` <=> not deployed by this factory.
    ///      This is the ENTIRE registry: existence, owner and index from one packed slot per wallet.
    mapping(address => IAGWFactory.WalletRecord) internal _records;

    /// @notice The canonical PushAgentWallet logic contract all clones delegate to.
    /// @dev    Written exactly once, in `initialize`. NO SETTER EXISTS, deliberately. Any
    ///         function able to rewrite this address could silently move every not-yet-deployed
    ///         predicted address, stranding counterfactually funded wallets with NO REMEDY (v3 has
    ///         no migration of any kind). The absence of the function IS the security mechanism.
    ///
    /// @dev    DECLARED LAST, AND DELIBERATELY: it is the APPEND-ONLY ANCHOR. Every future variable
    ///         goes after it; nothing is ever inserted or reordered before it. If that rule is
    ///         violated this address moves and address derivation breaks with no remedy — which is
    ///         why the storage-layout and address-stability tests assert this and are never
    ///         deleted or weakened.
    ///
    /// @dev    `internal`, exposed only through `walletImplementation()`. A `public` variable would
    ///         auto-generate a second getter with a different selector.
    address internal _walletImplementation;

    // THERE IS NO `__gap`, DELIBERATELY. This is a leaf UUPS implementation that nothing inherits
    // from, so a trailing gap protects against nothing: a future logic version appends after
    // `_walletImplementation`, which is always safe. The real protection is the append-only rule
    // plus the storage-layout test.

    // ────────────────────────────── constructor ──────────────────────────────

    /// @dev Standard UUPS hygiene: the logic contract can never be initialised directly.
    ///      `UUPSUpgradeable.__self` already rejects `upgradeToAndCall` invoked on the logic
    ///      contract, so no further guard is added.
    constructor() {
        _disableInitializers();
    }

    // ────────────────────────────── initialisation ──────────────────────────────

    /**
     * @notice Callable once, on the proxy, at deployment time.
     * @dev    Makes no external calls and deploys nothing. PAUSER/OPERATOR membership is granted
     *         afterwards by the admin through standard `grantRole`.
     */
    function initialize(address admin, address walletImplementation_) external initializer {
        if (admin == address(0) || walletImplementation_ == address(0)) revert ZeroAddress();

        __AccessControlDefaultAdminRules_init(DEFAULT_ADMIN_DELAY, admin);
        __Pausable_init();
        // NO `__UUPSUpgradeable_init()`: OZ 5.7.0's UUPSUpgradeable declares no initializer,
        // because it holds only an immutable (`__self`) and has no state to initialise. Calling one
        // does not compile — verified, not assumed.

        _walletImplementation = walletImplementation_;
    }

    // ──────────────────────────────── deployment ────────────────────────────────

    /**
     * @notice Deploys the caller's next agent wallet.
     *
     * @dev    THE ORDER OF EFFECTS IS NORMATIVE, and it is also the reentrancy protection — there
     *         is deliberately NO ReentrancyGuard. The counter is advanced and
     *         the registry written BEFORE the one external call, so a reentrant `deployWallet` can
     *         never be handed the same index twice. Adding a guard would be harmless-looking noise
     *         that hides the actual invariant.
     *
     * @dev    NOTHING MANDATE-RELATED ENTERS THE DERIVATION. The salt is the owner and a
     *         factory-assigned sequential index, nothing else. The owner appears TWICE — in the
     *         salt and in the immutable args — redundantly and on purpose: optimising it out of
     *         either changes every future address.
     */
    function deployWallet(string calldata label) external whenNotPaused returns (address wallet) {
        address implementation = _walletImplementation;
        // Reachable only on a proxy deployed without its atomic init call — operator error, not a
        // code path. Without it, `Clones` would happily deploy a clone pointing at address zero,
        // which OZ's own warning at `Clones.sol:192` calls out as permanently uninitialisable.
        if (implementation == address(0)) revert ImplementationNotSet();

        address owner = msg.sender;
        uint96 index = _walletCount[owner];

        // EFFECTS FIRST.
        _walletCount[owner] = index + 1;

        bytes32 salt = keccak256(abi.encode(owner, index));
        // 40 bytes: owner at offset 0-19, factory (this proxy) at offset 20-39. The wallet reads
        // both back via `Clones.fetchCloneArgs`; this encoding is frozen forever.
        bytes memory args = abi.encodePacked(owner, address(this));

        wallet = Clones.cloneDeterministicWithImmutableArgs(implementation, args, salt);

        // Registry written BEFORE the external call. No cast: `index` is already `uint96`.
        _records[wallet] = WalletRecord({ owner: owner, index: index });

        // THE ONLY EXTERNAL CALL THIS CONTRACT EVER MAKES. Any revert bubbles, and the entire
        // deployment reverts atomically: no wallet, no record, no counter change survives. There is
        // no code path on which an un-initialised wallet exists on-chain, and no recovery path for
        // a "deployed but unarmed" state is added, because no such state can occur.
        IPushAgentWalletInit(wallet).initializeAccount();

        emit WalletDeployed(owner, index, wallet, label);
    }

    // ─────────────────────── prediction & enumeration ───────────────────────

    /**
     * @notice The address wallet `index` of `owner` has, or will have.
     * @dev    THE WHOLE PRODUCT LEANS ON THIS. Counterfactual funding — a user sending assets to
     *         wallet #3 before deploying it — is a supported, first-class flow, which is why the
     *         derivation is frozen forever and why steps below must mirror `deployWallet` exactly.
     *         Any divergence between the two is a critical bug.
     */
    function predictWallet(address owner, uint256 index) external view returns (address wallet, bool deployed) {
        address implementation = _walletImplementation;
        // A prediction against an unconfigured factory would be garbage an SDK might trust.
        if (implementation == address(0)) revert ImplementationNotSet();

        uint256 next = _walletCount[owner];
        // Every existing wallet (0 … count-1) PLUS exactly the next deployable one (count).
        // Anything beyond is a wallet that cannot be deployed until thousands of others are, and a
        // user funding it counterfactually would put money in a permanent hole with no recovery.
        if (index > next) revert IndexOutOfRange(index, next);

        bytes32 salt = keccak256(abi.encode(owner, uint96(index)));
        bytes memory args = abi.encodePacked(owner, address(this));

        wallet = Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt, address(this));
        // Valid because indices are strictly sequential. NOT `extcodesize`, which would misreport
        // during construction and costs more.
        deployed = index < next;
    }

    /// @notice How many wallets `owner` has; also the index the next deploy will use.
    /// @dev    Full enumeration = this call + `predictWallet(owner, 0..count-1)`. Enumeration is
    ///         reconstructible from two on-chain reads forever; it cannot be lost or desynced,
    ///         which is why no per-owner array of wallet addresses is stored.
    function walletCount(address owner) external view returns (uint256) {
        return _walletCount[owner];
    }

    // ───────────────────────────── registry views ─────────────────────────────

    /// @notice The owner of `wallet`, or address(0) if this factory did not deploy it.
    function ownerOf(address wallet) external view returns (address) {
        return _records[wallet].owner;
    }

    /// @notice True only for wallets this factory deployed.
    function isWallet(address account) external view returns (bool) {
        return _records[account].owner != address(0);
    }

    /// @notice The wallet's index under its owner.
    /// @dev    Reverts rather than returning 0 because ZERO IS A VALID INDEX.
    function indexOf(address wallet) external view returns (uint256) {
        WalletRecord memory record = _records[wallet];
        if (record.owner == address(0)) revert NotAWallet(wallet);
        return record.index;
    }

    // ────────────────────────────── configuration ──────────────────────────────

    /// @notice The canonical wallet logic contract.
    /// @dev    The ONLY getter for it — the variable is `internal` precisely so no second,
    ///         auto-generated getter exists. Exposed so the SDK can verify its local derivation
    ///         mirror before showing a user an address to fund.
    function walletImplementation() external view returns (address) {
        return _walletImplementation;
    }

    // ──────────────────────────────── admin ────────────────────────────────

    /// @dev Pause gates `deployWallet` ONLY. Views are never gated, and nothing about a deployed
    ///      wallet is affected — the factory has no reach into wallets, paused or not.
    ///
    ///      DOCUMENTED RESIDUAL (accepted by ruling): while paused, a user who counterfactually
    ///      funded a predicted address cannot deploy it; the funds are unreachable until unpause.
    ///      Availability-only — funds are never lost.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @dev The role split is deliberate: pause is a cheap panic button, unpause a considered
    ///      operational act. PAUSER cannot unpause; OPERATOR cannot pause.
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /**
     * @dev NORMATIVE CONSTRAINT ON EVERY FUTURE FACTORY-LOGIC UPGRADE: it must not change (a) the
     *      salt formula, (b) the immutable-args encoding, (c) `_walletImplementation`'s value, or
     *      (d) the storage layout — new variables are APPENDED after `_walletImplementation`, base
     *      contracts are never added, removed or reordered, and nothing may come to share that
     *      slot. The address-stability test is the permanent guard; it runs across an upgrade in
     *      CI and is never deleted or weakened.
     *
     *      Upgrades exist for factory-LOGIC bugs only. The derivation is frozen forever.
     *
     *      NOT `view`, though solc notes it could be: the base declares
     *      `function _authorizeUpgrade(address) internal virtual` (UUPSUpgradeable.sol:127), and an
     *      override cannot add mutability restrictions the base does not have.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
    }
}
