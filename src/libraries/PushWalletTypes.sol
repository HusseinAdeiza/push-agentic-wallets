// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @notice Mirror of push-chain-gateway .../libraries/TypesUGPC.sol
 * @dev MUST match field-for-field and in order. Verified against
 *      contracts/evm-gateway/src/libraries/TypesUGPC.sol.
 */
struct UniversalOutboundTxRequest {
    bytes recipient; // raw destination address on source chain (bytes for SVM compat)
    address token; // PRC20 token address on Push Chain
    uint256 amount; // amount to withdraw (burn on Push, unlock at origin)
    uint256 gasLimit; // gas limit for fee quote; 0 = per-chain default
    uint256 gasPrice; // gas price override; 0 = per-chain default
    uint256 maxPCForGas; // max native PC for gas swap; 0 = no cap
    bytes payload; // ABI-encoded calldata to execute on origin chain
    address revertRecipient; // address to receive funds in case of revert
}

/**
 * @notice Mirror of push-chain-core .../libraries/Types.sol
 * @dev Batch call entry for multicall execution.
 */
struct Multicall {
    address to;
    uint256 value;
    bytes data;
}

/// @dev bytes4(keccak256("UEA_MULTICALL")) — magic prefix for multicall payloads.
bytes4 constant MULTICALL_SELECTOR = bytes4(keccak256("UEA_MULTICALL"));

/**
 * @dev The two kinds of mandate. Declared by the owner at grant, asserted by the wallet, stored by
 *      URP as the config's mode.
 *
 *      DECLARED ONCE, HERE, AND IMPORTED BY BOTH THE WALLET AND `IURP`. Two enums with identical
 *      values that must always agree is the duplication this file exists to prevent — see the note
 *      on `SEND_OUTBOUND_SELECTOR` below. The wallet asserts the declared type against the action
 *      set at grant; URP stores it and branches on it at validation. They must be the same type.
 *
 *      `UNIVERSAL` is the zero value, so an uninitialised slot reads as `UNIVERSAL`. That is why
 *      URP's `ModeSlot` carries an explicit `initialized` flag and never infers emptiness from the
 *      mode alone.
 */
enum MandateType {
    UNIVERSAL,
    NATIVE
}

/**
 * @dev Which destination VM a UNIVERSAL mandate targets. Derived by URP from the envelope's chain
 *      namespace prefix (`eip155:` / `solana:`) at config init; the wallet never reads it, because
 *      its grant rules are identical for every non-Push chain.
 *
 *      `EVM` MUST STAY THE ZERO VALUE. URP's `ModeSlot` entries written before this enum existed
 *      read 0 in the byte that now holds it, and every one of them is an EVM mandate.
 */
enum VmFamily {
    EVM,
    SVM
}

/**
 * @dev Mirrors of engine constants that are not importable — `IdLib.VALUE_SELECTOR` is `internal`
 *      to a library, and the fallback flags are file-level constants in the vendored fork.
 *
 *      MIRRORED, NOT GUESSED: each is pinned by a constant-mirror test against the upstream value,
 *      exactly as `MULTICALL_SELECTOR` is. If the fork moves, the test fails rather than the wallet
 *      silently permitting an action it means to forbid.
 */

/// @dev `IdLib.VALUE_SELECTOR` — the action selector the engine assigns when calldata is under four
///      bytes. A native action carrying this selector is a value-only transfer with EMPTY calldata;
///      a no-argument function like `unstake()` still carries its own four bytes and is a normal
///      selector action.
bytes4 constant VALUE_SELECTOR = 0xFFFFFFFF;

/// @dev `DataTypes.FALLBACK_TARGET_FLAG`. Refused by name at grant time: the engine does NOT reject
///      it at enable time (only at check time, `PolicyLib.sol:200`), so the wallet is the only
///      grant-time layer for this value.
address constant ENGINE_FALLBACK_TARGET = address(1);

/// @dev `DataTypes.FALLBACK_TARGET_SELECTOR_FLAG` — the wildcard action's selector.
bytes4 constant ENGINE_FALLBACK_SELECTOR = 0x00000001;

/// @dev `DataTypes.FALLBACK_TARGET_SELECTOR_FLAG_PERMITTED_TO_CALL_SMARTSESSION` — the sentinel that
///      routes a request to the engine itself. An agent reaching this could configure sessions.
bytes4 constant ENGINE_FALLBACK_SELECTOR_SMARTSESSION = 0x00000002;

/**
 * @dev The gateway's outbound entry point — the ONE selector an agent mandate may ever name.
 *
 *      DECLARED HERE, BESIDE THE STRUCT IT TAKES, AND NOWHERE ELSE. The wallet's grant-shape check
 *      and the policy's request-decode gate must agree on this value exactly: the wallet refuses to
 *      grant a mandate naming any other selector, and the policy refuses to validate a request
 *      carrying any other selector. Two independently hand-typed copies of the same signature
 *      string is the kind of duplication that stays correct only until one of them is edited, and
 *      the failure would be silent in the safe direction for one contract and open in the other.
 *
 *      The signature string spells out `UniversalOutboundTxRequest` field-for-field because that is
 *      how Solidity encodes a struct parameter into a selector. It is therefore load-bearing on the
 *      mirror above: reorder or retype a field there without editing this string and the selector
 *      silently stops matching the deployed gateway.
 */
bytes4 constant SEND_OUTBOUND_SELECTOR =
    bytes4(keccak256("sendUniversalTxOutbound((bytes,address,uint256,uint256,uint256,uint256,bytes,address))"));

/**
 * @dev Domain separator for the wallet's operation hash — distinct from every other protocol's, so
 *      a signature produced for this system can never be replayed as one for another.
 *
 *      The `v3` is the ARCHITECTURE GENERATION and is frozen: it is mixed into every agent
 *      signature, so changing the string invalidates every outstanding signed request. It is
 *      deliberately not tied to the wallet contract's own semver, which advances with releases.
 */
bytes32 constant OP_HASH_DOMAIN = keccak256("PushAgentWallet.Op.v3");

/**
 * @dev The owner's signed authorisation for up to three actions: deploy, grant, execute.
 *
 *      SIGNED ONCE under the FACTORY's EIP-712 domain and verified by the factory and by every wallet
 *      it deploys. Each door checks only its own fields and advances its own nonce, so one signature
 *      serves each door exactly once.
 *
 *      - Presentable ONLY by `executor`: every door, on its signature path, requires
 *        `intent.executor != address(0) && msg.sender == intent.executor`. Without that, anyone who saw
 *        the intent in calldata could drive the doors out of order and burn the owner's signature.
 *      - A zero `sessionHash` / `execCalldataHash` means "not authorised for that action".
 *      - EVERY FIELD IS IN THE TYPEHASH, IN DECLARATION ORDER. A field outside the typed data would
 *        guarantee the SDK and the contract disagree about what was signed.
 *
 *      DECLARED HERE, beside the other values the factory and the wallet must agree on exactly.
 */
struct OwnerIntent {
    address owner; // the wallet owner (UEA or EOA)
    address wallet; // the wallet this intent is for — the predicted address if not yet deployed
    address executor; // the ONLY msg.sender allowed to present this intent to a door
    uint96 index; // wallet index under owner; deployWallet requires index == walletCount(owner)
    bytes32 sessionHash; // keccak256(abi.encode(Session)) for grantMandateWithSig; 0 = no grant
    bytes32 mode; // ERC-7579 mode word for executeWithSig
    bytes32 execCalldataHash; // keccak256(executionCalldata) for executeWithSig; 0 = no exec
    uint192 nonceKey; // owner lane for executeWithSig; must have OWNER_LANE_FLAG set
    uint64 nonceSeq; // expected _nonces[nonceKey] at execution
    uint64 grantNonce; // expected _grantNonce at grant
    uint48 deadline; // unix seconds; all three doors reject after this
    uint256 signerChainId; // EIP-712 domain.chainId the signer's wallet accepts — the owner's HOME chain
}

/// @dev The struct string must list every OwnerIntent field, in declaration order, with its exact type.
bytes32 constant OWNER_INTENT_TYPEHASH = keccak256(
    "OwnerIntent(address owner,address wallet,address executor,uint96 index,bytes32 sessionHash,"
    "bytes32 mode,bytes32 execCalldataHash,uint192 nonceKey,uint64 nonceSeq,uint64 grantNonce,"
    "uint48 deadline,uint256 signerChainId)"
);

/**
 * @dev The intent's EIP-712 domain. Five fields:
 *      - `chainId` is the SIGNER's home chain (`intent.signerChainId`), not Push: MetaMask refuses to
 *        sign typed data whose `domain.chainId` differs from the active chain.
 *      - `salt` is `bytes32(block.chainid)` — the Push chain id — which is what isolates one Push chain
 *        from another.
 *      - `verifyingContract` is the FACTORY PROXY for both the factory and every wallet; the wallet
 *        reads it from its immutable args. The `wallet` field stops cross-wallet replay.
 */
bytes32 constant OWNER_INTENT_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");
bytes32 constant OWNER_INTENT_DOMAIN_NAME_HASH = keccak256("AGWFactory");
bytes32 constant OWNER_INTENT_DOMAIN_VERSION_HASH = keccak256("1");

/**
 * @dev Top bit of a uint192 nonce key. SET = an owner lane, consumable only by `executeWithSig`; CLEAR =
 *      an agent lane, consumable only by `executeWithSession`. A pure calldata partition of `_nonces`:
 *      no new storage, and neither door can ever consume the other's replay position.
 */
uint192 constant OWNER_LANE_FLAG = uint192(1) << 191;
