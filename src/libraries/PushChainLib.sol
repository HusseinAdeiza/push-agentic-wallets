// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { MandateType, VmFamily } from "./PushWalletTypes.sol";

/**
 * @title  PushChainLib — Push's own CAIP-2 identity, computed, never configured.
 *
 * @notice `selfChainHash()` is `keccak256("eip155:" ‖ decimal(block.chainid))` — the identity
 *         `UEAFactory.getOriginForUEA` reports for native accounts. The wallet calls it at grant and
 *         URP calls it at config init, so two contracts derive one mode from one envelope with
 *         nothing between them that can drift.
 *
 * @dev    WHY THIS IS A FUNCTION AND NOT AN IMMUTABLE, A CONSTANT, OR A STORAGE ANCHOR.
 *         - An immutable in URP is forbidden by URP's own design (`URP.sol:36-42`), which moved the
 *           trust anchors to storage when the contract went behind a transparent proxy, and which
 *           OpenZeppelin's upgrade tooling enforces. NOT "impossible": immutables are set at
 *           implementation-deploy time and inlined into the runtime bytecode the proxy
 *           `delegatecall`s into, so they do function. The objection is design consistency and
 *           tooling, not mechanics — stated precisely so nobody "corrects" it back.
 *         - A storage anchor in URP would need a `reinitializer` and an `upgradeAndCall` with data,
 *           and would become a deploy-time input that can be set wrong.
 *         - An immutable in the wallet PLUS a storage anchor in URP is TWO AUTHORS OF ONE FACT,
 *           separately upgradeable, asserted equal only at deploy. That is precisely the drift this
 *           library exists to make impossible.
 *         - `block.chainid` is the one value that cannot be misconfigured, is identical in both
 *           contracts within one transaction, and moves both together across a fork.
 *
 *         COST: ~1.2k gas on chain 42101, ~0.9k on chain 1. Called once per grant in the wallet and
 *         once per config init in URP. NEVER ON A RUNTIME PATH — `checkAction` does not call this.
 *
 *         NOT THE UEAFACTORY FORMULA. `keccak256(abi.encode("eip155", "42101"))` — two separately
 *         encoded strings — is a DIFFERENT value for the same chain, and it belongs to UEA address
 *         prediction. Conflating the two is how `Config.destChainHash` came to carry four different
 *         conventions in one repository. `test_ChainLib_notTheTwoStringFormula` pins the difference.
 *
 *         TESTS MUST PIN `block.chainid`. Foundry's default is 31337, where this derives
 *         `eip155:31337`. Native test helpers build the string from `block.chainid`, never a
 *         literal; tests that want the Donut value use `vm.chainId(42101)`.
 */
library PushChainLib {
    /// @notice keccak256 of this chain's CAIP-2 identifier.
    function selfChainHash() internal view returns (bytes32) {
        return keccak256(bytes(string.concat("eip155:", Strings.toString(block.chainid))));
    }

    /**
     * @notice The rulebook a mandate on `chainHash` belongs to.
     * @dev    This chain ⇒ NATIVE (a Push-side call). Any other ⇒ UNIVERSAL (through the gateway).
     *         An unrecognised or malformed string derives UNIVERSAL and is then refused against the
     *         action targets, or against the asset by URP — never silently accepted.
     */
    function deriveMode(bytes32 chainHash) internal view returns (MandateType) {
        return chainHash == selfChainHash() ? MandateType.NATIVE : MandateType.UNIVERSAL;
    }

    /// @dev The two CAIP-2 namespaces URP has a universal rulebook for. Seven bytes each, colon
    ///      included, so `"eip155:1"` and `"solana:…"` both classify on their first seven bytes.
    bytes7 internal constant NS_EIP155 = "eip155:";
    bytes7 internal constant NS_SOLANA = "solana:";

    /// @notice The declared chain string names a namespace URP has no rulebook for.
    /// @dev    Raised at config init only, so a grant fails closed instead of producing a mandate
    ///         that can never be used.
    error UnsupportedNamespace(bytes32 chainHash);

    /**
     * @notice The destination VM of a UNIVERSAL mandate, from its CAIP-2 string.
     * @dev    - Reads only the 7-byte prefix; the MODE is still derived from the full hash by
     *           `deriveMode`, and the wallet keeps doing exactly that. This is a second, narrower
     *           classification for URP's own routing, never a replacement.
     *         - Only meaningful for a string `deriveMode` already classified as UNIVERSAL. A native
     *           string also begins with `eip155:` and would classify EVM; callers must not ask.
     *         - Any other prefix reverts: an unknown namespace could pass init today (the asset check
     *           would accept a matching token) and then fail every request. Refusing at grant is the
     *           fail-closed reading.
     * @param  chain  The CAIP-2 string exactly as the envelope carries it.
     * @return The family, `EVM` or `SVM`.
     */
    function deriveVm(string memory chain) internal pure returns (VmFamily) {
        bytes memory b = bytes(chain);
        if (b.length > 7) {
            bytes32 word;
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                word := mload(add(b, 0x20))
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes7 prefix = bytes7(word); // the truncation IS the classification: only the prefix is read
            if (prefix == NS_EIP155) return VmFamily.EVM;
            if (prefix == NS_SOLANA) return VmFamily.SVM;
        }
        revert UnsupportedNamespace(keccak256(b));
    }
}
