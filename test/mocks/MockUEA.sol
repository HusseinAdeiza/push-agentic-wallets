// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  MockUEA — TEST ONLY. A stand-in for push-chain-core's `UEA_EVM` as an AGW owner.
 *
 * @notice Implements the one verification method the owner-intent doors call, with the SAME logic the
 *         real contract uses (`UEA_EVM.sol:105-108`): a raw ECDSA recover of the digest compared to the
 *         origin key. No domain, no prefix — the real verifier does not care which domain produced the
 *         digest, and neither does this one.
 *
 * @dev    ⚠️ NOT AN ORACLE. It never decides an outcome on its own: it answers `true` only when the
 *         signature really recovers to the origin key, so a wrong digest fails the test. Like the real
 *         UEA it implements no ERC-1271.
 *
 *         `exec` stands in for `executeUniversalTx` so integration tests can drive the UEA as the
 *         owner of an AGW (msg.sender == this) — the Phase 1 payload in the PRD.
 */
contract MockUEA {
    address public immutable ORIGIN_KEY;

    constructor(address originKey) {
        ORIGIN_KEY = originKey;
    }

    function verifyUniversalPayloadSignature(bytes32 payloadHash, bytes memory signature) external view returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(payloadHash, signature);
        return err == ECDSA.RecoverError.NoError && recovered == ORIGIN_KEY;
    }

    /// @dev Stands in for executeUniversalTx: only the origin key may drive the UEA.
    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        require(msg.sender == ORIGIN_KEY, "MockUEA: not origin");
        bool ok;
        (ok, ret) = to.call{ value: value }(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable { }
}

/// @dev A contract owner that implements only ERC-1271 (a Safe-like owner), recovering to one key.
contract Mock1271Owner {
    address public immutable KEY;

    constructor(address key) {
        KEY = key;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig);
        return err == ECDSA.RecoverError.NoError && recovered == KEY ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev A contract owner that implements nothing and reverts on every call.
contract MockRevertingOwner {
    fallback() external {
        revert("no");
    }
}

/// @dev A contract owner whose fallback SUCCEEDS with empty return data (Safe fallback-handler shape).
///      The case a high-level `try` cannot survive: the decode failure is raised in the caller.
contract MockEmptyReturnOwner {
    fallback() external { }
}

/// @dev A contract owner whose fallback succeeds with 64 bytes — the right value, the wrong length.
contract MockWrongLengthOwner {
    fallback() external {
        assembly {
            mstore(0, 1)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

/// @dev A contract owner whose fallback returns the first 32 bytes of its calldata. For an ERC-1271
///      call that word is `0x1626ba7e ‖ digest[0:28]` — right first four bytes, wrong word.
contract MockEchoOwner {
    fallback() external {
        assembly {
            calldatacopy(0, 0, 32)
            return(0, 32)
        }
    }
}
