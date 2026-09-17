// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  MockPRC20Source — TEST ONLY. The asset URP interrogates at universal init.
 *
 * @notice Answers `SOURCE_CHAIN_NAMESPACE()` with a configurable CAIP-2 string, mirroring
 *         push-chain-core's `PRC20`. The real thing sets the value once in `initialize` and has no
 *         setter; this one is settable so a single test can point the same address at a different
 *         chain without deploying a second token.
 *
 * @dev    ⚠️ OBSERVER, NEVER ORACLE. This mock supplies the STRING; it never decides the outcome.
 *         URP does the hashing and the comparison, so a wrong answer here makes the test fail rather
 *         than making a dead branch look alive. That distinction is what the repo's one shipped
 *         critical bug turned on: the Ed25519 branch passed every test because the tests etched
 *         bytecode at a precompile address that has none on the real chain.
 *
 *         WHAT THE REAL THING DOES, AND WHY THE COUPLING IS SAFE: the gateway reads this exact view
 *         on every outbound, through `UniversalCore.getOutboundTxGasAndFees`, to decide which chain
 *         to route to. The fork test pins the mirror against a deployed PRC20; this mock covers the
 *         cases a live token cannot be made to exhibit.
 *
 *         THE FAILURE MODES ARE SEPARATE CONTRACTS, at the bottom of this file, because they are the
 *         point of the `code.length` guard and each must be reachable independently.
 */
contract MockPRC20Source {
    string public SOURCE_CHAIN_NAMESPACE;

    constructor(string memory chainNamespace) {
        SOURCE_CHAIN_NAMESPACE = chainNamespace;
    }

    /// @dev Test-only. The real PRC20 has no setter — this exists so one test can retarget one
    ///      address, not because the production field is mutable.
    function setSourceChainNamespace(string calldata chainNamespace) external {
        SOURCE_CHAIN_NAMESPACE = chainNamespace;
    }
}

/// @dev Answers the view by REVERTING. The only failure mode `try/catch` actually catches — which is
///      why the no-code and non-string cases below need the explicit `code.length` guard instead.
contract RevertingPRC20Source {
    error Nope();

    function SOURCE_CHAIN_NAMESPACE() external pure returns (string memory) {
        revert Nope();
    }
}

/// @dev Returns one 32-byte word where a `string` was expected. The call SUCCEEDS; the ABI decode
///      fails in URP's own frame, outside the `try/catch`, so this reverts UNNAMED. A contract that
///      is simply not a PRC20.
contract NonStringPRC20Source {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @dev Returns nothing at all. Same outcome as `NonStringPRC20Source`, different shape: the decode
///      has zero bytes to work with rather than the wrong bytes.
contract EmptyReturnPRC20Source {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}
