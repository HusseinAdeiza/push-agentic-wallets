// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { PushAgentWallet } from "../../src/PushAgentWallet.sol";
import { AGWFactory } from "../../src/AGWFactory.sol";

/**
 * @notice S-05 — the deployment record matches the deployed wallet implementation's immutables.
 *
 * @dev    WHAT THIS CATCHES: a record written from intent rather than from what was actually
 *         deployed. The four wiring keys are named after the wallet's view functions precisely so
 *         the comparison is mechanical — the record cannot drift from the bytecode without this
 *         going red.
 *
 * @dev    "PLACEHOLDER" IS DEFINED, not vibes: `address(0)`, or any address with `extcodesize == 0`
 *         on the target network. The record must point at DEPLOYED CODE, not at an intended
 *         address. The gateway and executor module are the exception — they are Push-core
 *         contracts this repo does not deploy, so on a local fork they are configured constants
 *         with no code, and the test says so rather than pretending otherwise.
 *
 * @dev    ENV-GATED, and it names the RPC it needs. A record test that silently passes when no
 *         deployment exists would be worse than no test — the same rot class that put two defects
 *         into P-03 before it was ever run.
 */
contract DeploymentRecordTest is Test {
    function test_S05_DeploymentRecord() public {
        string memory rpc = vm.envOr("DEPLOYMENT_RPC", string(""));
        uint256 chainId = vm.envOr("CHAIN_ID", uint256(0));

        if (bytes(rpc).length == 0 || chainId == 0) {
            vm.skip(true, "S-05 requires DEPLOYMENT_RPC and CHAIN_ID pointing at a live deployment");
        }

        vm.createSelectFork(rpc);

        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        string memory record = vm.readFile(path);

        // ── the record's own identity ──
        //
        // COMPARED AGAINST THE CHAIN, NOT AGAINST THE ENVIRONMENT. `CHAIN_ID` already chose the
        // filename; asserting the file's own field against that same variable would close a loop
        // in which nothing ever contradicts the env. `block.chainid` is the only independent
        // witness, and it is what makes a mainnet deployment recorded as 31337 fail here.
        assertEq(
            vm.parseJsonUint(record, ".chainId"),
            block.chainid,
            "the record's chainId must match THE FORKED CHAIN, not the environment"
        );

        // Both commit keys must be present AND DISTINCT in meaning. They share a value only until
        // this repo's first commit; a test comparing the wrong one would pass silently forever.
        assertGt(bytes(vm.parseJsonString(record, ".commit")).length, 0, "repo commit recorded");
        assertEq(vm.parseJsonString(record, ".engineForkCommit"), "7dc20e4", "the vendored engine pin");

        // ── the addresses ──
        address sessionEngine = vm.parseJsonAddress(record, ".sessionEngine");
        address sessionValidator = vm.parseJsonAddress(record, ".sessionValidator");
        address ucep = vm.parseJsonAddress(record, ".ucep");
        address universalGateway = vm.parseJsonAddress(record, ".universalGateway");
        address universalExecutorModule = vm.parseJsonAddress(record, ".universalExecutorModule");
        address walletImplementation = vm.parseJsonAddress(record, ".walletImplementation");
        address factoryProxy = vm.parseJsonAddress(record, ".factoryProxy");
        address factoryLogic = vm.parseJsonAddress(record, ".factoryLogic");

        address[8] memory all = [
            sessionEngine,
            sessionValidator,
            ucep,
            universalGateway,
            universalExecutorModule,
            walletImplementation,
            factoryProxy,
            factoryLogic
        ];
        for (uint256 i; i < all.length; ++i) {
            assertTrue(all[i] != address(0), "no address in the record may be zero");
        }

        // ── THE CORE ASSERTION: the record equals what the BYTECODE says ──
        PushAgentWallet impl = PushAgentWallet(payable(walletImplementation));
        assertEq(impl.sessionEngine(), sessionEngine, "sessionEngine matches the deployed immutable");
        assertEq(impl.sessionValidator(), sessionValidator, "sessionValidator matches the deployed immutable");
        assertEq(impl.ucep(), ucep, "ucep matches the deployed immutable");
        assertEq(impl.universalGateway(), universalGateway, "universalGateway matches the deployed immutable");

        // the factory points at the same wallet implementation
        assertEq(
            AGWFactory(factoryProxy).walletImplementation(),
            walletImplementation,
            "the factory proxy points at the recorded implementation"
        );

        // ── every address WE deploy must have code on the target network ──
        address[6] memory ours =
            [sessionEngine, sessionValidator, ucep, walletImplementation, factoryProxy, factoryLogic];
        for (uint256 i; i < ours.length; ++i) {
            assertGt(ours[i].code.length, 0, "a recorded address has no code - it is a placeholder");
        }

        // The gateway and executor module are Push-core contracts this repo does not deploy. On a
        // local fork they are configured constants with no code; on a real network they must have
        // code. Asserted conditionally rather than skipped, so the real-network case is covered.
        if (block.chainid != 31_337) {
            assertGt(universalGateway.code.length, 0, "the gateway must be deployed on a real network");
            assertGt(universalExecutorModule.code.length, 0, "the executor module must be deployed");
        }
    }

    /**
     * THE NEGATIVE HALF: a record whose `chainId` disagrees with the chain it is read against must
     * FAIL. Without this, the assertion above could be satisfied by any record on any chain and
     * nobody would notice — which is precisely the defect this pair was added to close.
     *
     * Built as a temporary record so no real one is touched, and removed afterwards.
     */
    function test_S05_MismatchedChainIdIsRejected() public {
        string memory rpc = vm.envOr("DEPLOYMENT_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "S-05 requires DEPLOYMENT_RPC pointing at a live deployment");
        }
        vm.createSelectFork(rpc);

        // A record claiming a DIFFERENT chain than the one we are on.
        string memory obj = "wrong";
        vm.serializeUint(obj, "chainId", block.chainid + 1);
        string memory bad = vm.serializeAddress(obj, "sessionEngine", address(0xBEEF));

        string memory path = "deployments/_mismatch_probe.json";
        vm.writeJson(bad, path);

        // Run the SAME check S-05 runs, through an external call so its failure is catchable.
        // Asserting a boolean I computed myself would prove nothing about the real assertion.
        try this.assertRecordChainId(path) {
            vm.removeFile(path);
            fail(); // it accepted a record for the wrong chain
        } catch {
            // refused, as it must be
        }
        vm.removeFile(path);
    }

    /// @dev The chain-id half of S-05, callable externally so the negative test can catch it.
    function assertRecordChainId(string calldata path) external view {
        assertEq(
            vm.parseJsonUint(vm.readFile(path), ".chainId"),
            block.chainid,
            "the record's chainId must match THE FORKED CHAIN, not the environment"
        );
    }
}
