// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { BobPayload, UniversalPayload } from "../../lib/BobPayload.sol";
import { UeaDigest } from "../../lib/UeaDigest.sol";
import { ISepoliaGateway } from "../../lib/PushCore.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";

/**
 * @title  SignedProbe
 * @notice Chain: Sepolia · broadcasts with a THROWAWAY key. The arrival path, fully signed.
 *
 * @dev    THE LAST UNTESTED VARIABLE. Three probes have now established what does NOT explain the
 *         inbound payload never executing:
 *
 *           · probe 1 — no native value        -> UEA deployed, minted, `nonce()` 0
 *           · probe 2 — 0.002 ETH native value -> gas leg delivered 4.996 PC, `nonce()` 0
 *           · probe 3 — `vType: 1`             -> gas leg delivered, `nonce()` 0
 *
 *         Missing gas is eliminated; the verification-type flag is eliminated. What remains is the
 *         empty `signatureData` that all three carried.
 *
 *         THIS IS ALSO A REHEARSAL OF THE REAL ARRIVAL, not just a probe. It computes the digest
 *         LOCALLY against the PREDICTED UEA — the only way to sign for an account that does not
 *         exist yet — using the recipe verified byte-for-byte against a deployed UEA in
 *         `UeaDigestFork.t.sol`. If this succeeds, the same code signs Bob's arrival.
 *
 *         `vType` is `signedVerification` (0) because the payload genuinely carries a signature,
 *         and because `vType` is inside the struct hash: the digest must be computed with the value
 *         actually sent.
 */
contract SignedProbe is Script {
    error InsufficientUSDC(uint256 have, uint256 need);

    uint256 internal constant PROBE_AMOUNT = 1e6;
    uint256 internal constant NATIVE_VALUE = 0.002 ether;

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant PUSH_CHAIN_ID = 42101;
    string internal constant SOURCE_CHAIN_ID = "11155111";

    /// @dev A fresh UEA's stored counter, which is what the digest must be computed against.
    uint256 internal constant FRESH_NONCE = 0;

    function run() external {
        uint256 pk = Keys.load("PROBE4_KEY", "the throwaway sender for the signed arrival probe");
        address probe = vm.addr(pk);

        address gateway = AddressBook.sepolia("UniversalGateway");
        address usdc = AddressBook.sepolia("USDC");
        address prc20 = AddressBook.donut("PRC20_USDC");
        address ueaFactory = AddressBook.donut("UEAFactory");

        DemoLog.header("PROBE", "Signed arrival payload");
        DemoLog.addr("Sender", probe, false);

        // UEAFactory lives on Donut; this script broadcasts on Sepolia. Predict across a fork.
        uint256 sepoliaFork = vm.activeFork();
        vm.createSelectFork(vm.envString("PUSH_DONUT_RPC_URL"));
        address uea = BobPayload.predictUEA(ueaFactory, SOURCE_CHAIN_ID, probe);
        vm.selectFork(sepoliaFork);

        DemoLog.addr("Predicted UEA", uea, true);
        DemoLog.note("Does not exist yet. The digest is computed against this address.");
        DemoLog.blank();

        uint256 balance = IERC20(usdc).balanceOf(probe);
        if (balance < PROBE_AMOUNT) revert InsufficientUSDC(balance, PROBE_AMOUNT);

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (uea, 0)) });

        UniversalPayload memory payload = BobPayload.multicallPayload(calls, FRESH_NONCE, 0);

        // The arrival's signature: computed locally, because there is no contract to ask.
        bytes32 digest = UeaDigest.hash(uea, SEPOLIA_CHAIN_ID, PUSH_CHAIN_ID, FRESH_NONCE, payload);
        bytes memory signature = BobPayload.signDigest(digest, pk);

        DemoLog.kv("Payload", "1 entry: pUSDC.transfer(uea, 0)");
        DemoLog.kv("vType", "0 (signedVerification)");
        DemoLog.kv("Digest", vm.toString(digest));
        DemoLog.kv("Signature", string.concat(vm.toString(signature.length), " bytes"));
        DemoLog.money("Bridging", PROBE_AMOUNT, 6, "USDC");
        DemoLog.money("Native", NATIVE_VALUE, 18, "ETH");

        vm.startBroadcast(pk);
        IERC20(usdc).approve(gateway, PROBE_AMOUNT);
        ISepoliaGateway(gateway).sendUniversalTx{ value: NATIVE_VALUE }(
            ISepoliaGateway.UniversalTxRequest({
                recipient: address(0),
                token: usdc,
                amount: PROBE_AMOUNT,
                payload: abi.encode(payload),
                revertRecipient: probe,
                signatureData: signature
            })
        );
        vm.stopBroadcast();

        DemoLog.blank();
        DemoLog.ok("sent", "poll the predicted UEA on Donut");
        DemoLog.note("nonce() > 0 -> the payload executed and the arrival can be one transaction.");
        DemoLog.note("nonce() == 0 -> payload execution is not wired on this build; ask Push core.");
        DemoLog.footer();
    }
}
