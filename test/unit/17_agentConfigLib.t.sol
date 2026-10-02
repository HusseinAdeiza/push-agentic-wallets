// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { AgentConfigLib } from "../../src/libraries/AgentConfigLib.sol";

/// @dev Exposes the internal library through an external call, so tests pass it calldata-born
///      memory exactly as the validator and the wallet do.
contract AgentConfigLibHarness {
    function decode(bytes memory c) external pure returns (address) {
        return AgentConfigLib.decode(c);
    }
}

/**
 * @notice AgentConfigLib — the one decoder of a rules set's agent config, shared by the validator
 *         (which enforces it) and the wallet (which reads it for `agentOf` and the agent door).
 * @dev    The format is frozen: `abi.encode(address agent)`, exactly 32 bytes, clean upper bytes,
 *         non-zero. Anything else decodes to `address(0)` and never reverts.
 */
contract AgentConfigLibTest is BaseTest {
    AgentConfigLibHarness internal lib;

    function setUp() public override {
        super.setUp();
        lib = new AgentConfigLibHarness();
    }

    function test_decode_wellFormedConfigReturnsAgent() public view {
        assertEq(lib.decode(abi.encode(AGENT)), AGENT, "abi.encode(agent) decodes to the agent");
    }

    function testFuzz_decode_roundTripsEveryNonZeroAddress(address a) public view {
        vm.assume(a != address(0));
        assertEq(lib.decode(abi.encode(a)), a, "round trip");
    }

    function test_decode_zeroAddressIsZero() public view {
        assertEq(lib.decode(abi.encode(address(0))), address(0), "a zero agent is no agent");
    }

    function test_decode_wrongLengthIsZero() public view {
        assertEq(lib.decode(""), address(0), "0 bytes");
        assertEq(lib.decode(hex"01"), address(0), "1 byte");
        assertEq(lib.decode(abi.encodePacked(AGENT)), address(0), "20 bytes - the old raw-key shape");
        assertEq(lib.decode(new bytes(31)), address(0), "31 bytes");
        assertEq(lib.decode(abi.encodePacked(abi.encode(AGENT), hex"00")), address(0), "33 bytes");
        assertEq(lib.decode(abi.encode(AGENT, AGENT)), address(0), "64 bytes");
    }

    function testFuzz_decode_anyLengthOtherThan32IsZero(bytes memory c) public view {
        vm.assume(c.length != 32);
        assertEq(lib.decode(c), address(0), "only one ABI word can name an agent");
    }

    function testFuzz_decode_dirtyUpperBytesAreZero(uint96 high, address a) public view {
        vm.assume(high != 0);
        uint256 word = uint256(high) << 160 | uint256(uint160(a));
        assertEq(lib.decode(abi.encodePacked(word)), address(0), "dirty upper bytes are refused, never truncated");
    }

    /// A pre-D3 config — `abi.encode(uint8 scheme, bytes key)` — can never pass as a D3 config.
    function test_decode_oldEcdsaConfigIsRejected() public view {
        assertEq(lib.decode(abi.encode(uint8(0), abi.encodePacked(AGENT))), address(0), "old ECDSA config");
    }
}
