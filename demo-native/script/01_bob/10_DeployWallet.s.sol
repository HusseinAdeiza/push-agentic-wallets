// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";

import { IAGWFactory } from "../../../src/interfaces/IAGWFactory.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";

/**
 * @title  DeployWallet
 * @notice ACT 1a · Chain: Donut · broadcasts with BOB's key.
 *
 * @dev    THE HEADLINE OF THE WHOLE NATIVE DEMO IS IN THIS SCRIPT'S SIMPLICITY.
 *
 *         In the cross-chain demo, getting Bob a wallet took a four-step identity chain — his
 *         Ethereum EOA, a `UniversalAccountId`, a UEA deployed on Push, and an AGW owned by that
 *         UEA — plus a signed `UniversalPayload` relayed through `executeUniversalTx`, because Bob
 *         had no Push Chain account at all.
 *
 *         Here Bob IS a Push Chain account. He calls the factory himself. `AGWFactory.deployWallet`
 *         takes its owner from `msg.sender` and has no owner parameter and no UEA dependency of any
 *         kind, so the identity chain is one step long:
 *
 *             Bob's Push EOA  ->  AGW, owned directly by it
 *
 *         PREDICTION FIRST, THEN DEPLOY. `predictWallet` is asserted against the deployed address
 *         so the counterfactual-funding property is demonstrated rather than merely claimed — a
 *         user can fund an address before it exists.
 */
contract DeployWallet is Script {
    error PredictionMismatch(address predicted, address deployed);
    error NotRegistered(address wallet);
    error WrongOwner(address expected, address actual);

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob owns and deploys his wallet");
        address bob = vm.addr(bobPk);
        IAGWFactory factory = IAGWFactory(AddressBook.ours("factoryProxy"));

        // Index 0 is Bob's first wallet. Act 4f uses index 1 for the throwaway.
        (address predicted, bool already) = factory.predictWallet(bob, 0);

        DemoLog.header("ACT 1a", "Bob arrives");
        DemoLog.addrPlain("Bob (Push EOA)", bob);
        DemoLog.note("    An ordinary Push Chain account. No UEA. No second chain.");
        DemoLog.blank();
        DemoLog.addrPlain("His wallet will be", predicted);
        DemoLog.note("    Known BEFORE it exists - it can be funded counterfactually.");

        address wallet = predicted;
        if (already) {
            DemoLog.blank();
            DemoLog.note("Already deployed; reusing it. Nothing was broadcast.");
        } else {
            vm.startBroadcast(bobPk);
            wallet = factory.deployWallet("native-staking");
            vm.stopBroadcast();
        }

        // ASSERT AGAINST THE CHAIN, not against the call having succeeded.
        if (wallet != predicted) revert PredictionMismatch(predicted, wallet);
        if (!factory.isWallet(wallet)) revert NotRegistered(wallet);
        address owner = factory.ownerOf(wallet);
        if (owner != bob) revert WrongOwner(bob, owner);

        Ledger.setAddr("bob", bob);
        Ledger.setAddr("agw", wallet);

        DemoLog.blank();
        DemoLog.ok("deployed", "prediction matched the deployed address exactly");
        DemoLog.addrPlain("Owner", owner);
        DemoLog.note("    Bob's EOA itself - read from the factory's registry, not assumed.");
        DemoLog.footer();
    }
}
