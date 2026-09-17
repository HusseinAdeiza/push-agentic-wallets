// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { ActionId, ConfigId, PermissionId } from "smartsessions/DataTypes.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";

import { NativeIds } from "../lib/NativeIds.sol";

/**
 * @title  NativeIdsTest
 * @notice ⚠️ THE PHASE 2 GATE. The config-id derivation, checked against the ENGINE'S OWN code.
 *
 * @dev    WHY THIS TEST IS THE ONE THAT MATTERS MOST IN THIS FOLDER.
 *
 *         `NativeIds` is the only piece of off-chain arithmetic in the native demo with NO
 *         compile-time link to the contract it addresses. If it is wrong, every read returns an
 *         empty config and every act fails at gate N1 with `NotInitialized` — which looks exactly
 *         like a mandate problem and is not. An operator would spend the demo debugging the wrong
 *         layer.
 *
 *         THE ORACLE IS `IdLib` ITSELF — the engine's own library, the same code the deployed
 *         SmartSession runs. This is deliberately NOT a second transcription of the formula: a test
 *         comparing two hand-written copies of the same arithmetic passes even when both are wrong,
 *         which is precisely the failure mode here.
 *
 *         The build instruction asks for this to be asserted against a LIVE GRANT. `IdLib` is
 *         stronger for the unit case — it is the source, not a sample — and the live assertion is
 *         additionally performed on-chain by `13_GrantMandate`, which reads the rulebook back
 *         through the derived id and reverts if it is not initialised. Both layers exist because
 *         each catches what the other cannot: this one catches a wrong formula, that one catches a
 *         right formula applied to the wrong target.
 */
contract NativeIdsTest is Test {
    address internal wallet = makeAddr("agw");
    address internal stakeDummy = makeAddr("stakeDummy");
    address internal token = makeAddr("dUSDC");
    address internal otherWallet = makeAddr("other");

    bytes4 internal constant STAKE_FOR = bytes4(keccak256("stakeFor(address,uint256)"));
    bytes4 internal constant UNSTAKE = bytes4(keccak256("unstake()"));
    bytes4 internal constant APPROVE = bytes4(keccak256("approve(address,uint256)"));

    bytes32 internal permissionId = keccak256("permission-1");

    /// @dev The action id, against `IdLib.toActionId`.
    function test_actionId_matchesTheEngine() public view {
        assertEq(
            NativeIds.actionId(stakeDummy, STAKE_FOR),
            ActionId.unwrap(IdLib.toActionId(stakeDummy, STAKE_FOR)),
            "action id drifted from IdLib"
        );
    }

    /// @dev The whole chain, against `IdLib.toConfigId`.
    function test_configId_matchesTheEngine() public view {
        ConfigId mine = NativeIds.configId(permissionId, wallet, stakeDummy, STAKE_FOR);
        ConfigId theirs =
            IdLib.toConfigId(PermissionId.wrap(permissionId), IdLib.toActionId(stakeDummy, STAKE_FOR), wallet);
        assertEq(ConfigId.unwrap(mine), ConfigId.unwrap(theirs), "config id drifted from IdLib");
    }

    /**
     * @dev ONE CONFIG PER ACTION — the property that makes native mode different from universal.
     *
     *      A universal mandate has one action and therefore one config. A native mandate has one
     *      rulebook PER ACTION, with independent counters. If these ids collided, two actions would
     *      share a budget and the demo's "60 lifetime" would silently mean something else.
     */
    function test_configId_differsPerSelector() public view {
        assertTrue(
            ConfigId.unwrap(NativeIds.configId(permissionId, wallet, stakeDummy, STAKE_FOR))
                != ConfigId.unwrap(NativeIds.configId(permissionId, wallet, stakeDummy, UNSTAKE)),
            "stakeFor and unstake share a config id"
        );
    }

    /**
     * @dev ⚠️ ACT 4f'S TRAP, as a test.
     *
     *      4f is the only place in the demo where the action target is NOT `StakeDummy` — it is the
     *      token, because the action is `approve`. Deriving that config id against `StakeDummy` out
     *      of habit yields an id addressing an empty slot. This asserts the two are genuinely
     *      different, so the mistake cannot pass unnoticed.
     */
    function test_configId_differsPerTarget() public view {
        assertTrue(
            ConfigId.unwrap(NativeIds.configId(permissionId, wallet, token, APPROVE))
                != ConfigId.unwrap(NativeIds.configId(permissionId, wallet, stakeDummy, APPROVE)),
            "the target is not bound into the config id"
        );
    }

    /// @dev Two mandates on one wallet meter independently — the basis of the stake/unstake split.
    function test_configId_differsPerPermission() public view {
        assertTrue(
            ConfigId.unwrap(NativeIds.configId(permissionId, wallet, stakeDummy, STAKE_FOR))
                != ConfigId.unwrap(NativeIds.configId(keccak256("permission-2"), wallet, stakeDummy, STAKE_FOR)),
            "two mandates share a config id"
        );
    }

    /// @dev And two wallets never share one, or one user's budget would meter another's.
    function test_configId_differsPerAccount() public view {
        assertTrue(
            ConfigId.unwrap(NativeIds.configId(permissionId, wallet, stakeDummy, STAKE_FOR))
                != ConfigId.unwrap(NativeIds.configId(permissionId, otherWallet, stakeDummy, STAKE_FOR)),
            "two wallets share a config id"
        );
    }

    /**
     * @dev THE MUTATION THIS FILE EXISTS TO CATCH: `abi.encode` where `abi.encodePacked` belongs.
     *
     *      Both encodings compile, both produce a 32-byte hash, and both look right. Only one
     *      addresses a config that exists. This pins the difference so that swapping them is a
     *      failing test rather than a demo that dies at N1.
     */
    function test_packedEncodingIsNotInterchangeableWithEncode() public view {
        bytes32 packed = keccak256(abi.encodePacked(stakeDummy, STAKE_FOR));
        bytes32 padded = keccak256(abi.encode(stakeDummy, STAKE_FOR));

        assertEq(NativeIds.actionId(stakeDummy, STAKE_FOR), packed, "actionId must use encodePacked");
        assertTrue(packed != padded, "the two encodings must differ - otherwise this guard is vacuous");
    }
}
