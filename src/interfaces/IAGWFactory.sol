// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { OwnerIntent } from "../libraries/Types.sol";

/**
 * @title  IAGWFactory — the factory's complete external surface.
 * @notice Functions not declared here must not exist on `AGWFactory` (the inherited
 *         AccessControl / Pausable / UUPS surface excepted). The factory's test suite asserts the
 *         exact selector set, so an accidental addition fails the build rather than shipping.
 *
 * @dev    Errors live in `AGWFactoryErrors` (`libraries/Errors.sol`).
 *
 * @dev    ROLES. `pause` is `PAUSER_ROLE`, `unpause` is `OPERATOR_ROLE` — a deliberate deviation from
 *         the gateway, so the account that can stop signups is not the account that can resume them.
 */
interface IAGWFactory {
    // ─────────────────────────────── types ───────────────────────────────

    /// @param owner the deploying caller; `address(0)` means "not deployed by this factory"
    /// @param index the wallet's position under its owner. `uint96` so it matches the counter
    ///        exactly — there is no narrowing cast anywhere in this contract.
    struct WalletRecord {
        address owner;
        uint96 index;
    }

    // ═══════════════════════════════ AGWF_1: EVENTS ═══════════════════════════════

    /// @dev The complete deployment history. With the registry, this is the indexer's whole input.
    ///      `label` is the only unindexed field — it is emitted, never stored.
    event WalletDeployed(address indexed owner, uint256 indexed index, address indexed wallet, string label);

    // ═══════════════════════════════ AGWF_2: DEPLOY ═══════════════════════════════

    /// @notice Deploys the caller's next agent wallet. THE CALLER IS THE OWNER — no parameter.
    function deployWallet(string calldata label) external returns (address wallet);

    /// @notice Deploys wallet `intent.index` for `intent.owner`, authorised by the owner's signature.
    /// @dev    The owner is the signer of an OwnerIntent naming this owner, index and wallet, presented
    ///         by `intent.executor`. Salt and immutable args are identical to `deployWallet(string)`,
    ///         so every predicted address is unchanged.
    function deployWalletWithSig(OwnerIntent calldata intent, bytes calldata sig, string calldata label)
        external
        returns (address wallet);

    /// @notice PAUSER_ROLE only. Gates `deployWallet` and `deployWalletWithSig` and nothing else.
    function pause() external;

    /// @notice OPERATOR_ROLE only. The split from `pause` is deliberate (see the header).
    function unpause() external;

    // ═══════════════════════════════ AGWF_3: VIEWS ═══════════════════════════════

    /// @notice The OwnerIntent EIP-712 domain separator for a signer on `signerChainId`.
    /// @dev    Exposed so the SDK can verify its local derivation before prompting the owner.
    function domainSeparator(uint256 signerChainId) external view returns (bytes32);

    /// @notice The address wallet `index` of `owner` has, or will have. Pure derivation.
    /// @dev    Counterfactual funding is a first-class flow, which is why the derivation is frozen.
    function predictWallet(address owner, uint256 index) external view returns (address wallet, bool deployed);

    /// @notice How many wallets `owner` has. Also the index the next deploy will take.
    function walletCount(address owner) external view returns (uint256);

    /// @notice The owner of `wallet`, or address(0) if this factory did not deploy it.
    function ownerOf(address wallet) external view returns (address);

    /// @notice True only for wallets this factory deployed.
    function isWallet(address account) external view returns (bool);

    /// @notice The wallet's index under its owner.
    /// @dev    REVERTS for a non-wallet rather than returning 0, because 0 is a VALID index.
    function indexOf(address wallet) external view returns (uint256);

    /// @notice The canonical wallet logic contract. Set once at initialize. NO SETTER EXISTS.
    function walletImplementation() external view returns (address);
}
