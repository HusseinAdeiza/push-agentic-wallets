// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { Identity } from "../../lib/Identity.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { Multicall } from "../../../src/libraries/PushWalletTypes.sol";
import { IAGWFactory } from "../../../src/interfaces/IAGWFactory.sol";

/**
 * @title  ArriveComplete
 * @notice ACT 1b · Chain: Donut · broadcasts with the RELAYER key, on a payload BOB signed.
 *
 * @dev    THE BEAT THIS SCRIPT EXISTS TO SHOW. Bob signs with his Ethereum key. An address with no
 *         role in the system submits it. Three things happen on a chain Bob has never touched: his
 *         agent wallet is deployed, funded with 100 pUSDC, and armed with a gateway allowance.
 *
 *         The signature is the authority — never the caller. `executeUniversalTx` is `external`
 *         with no access control, and the relayer holds nothing.
 *
 *         WHY THIS IS A SEPARATE SCRIPT FROM `10_Arrive`. Four probes established that the deployed
 *         build does not execute a payload attached to the inbound bridge (§3.4). The work moves
 *         here, onto the relayed path, which is proven on-chain: Donut tx `0x88b2ac09…` moved funds
 *         out of a UEA on a third party's submission and advanced the nonce.
 *
 *         IDEMPOTENT BY DETECTION, NOT BY FLAG. If the AGW already exists — because a rehearsal ran
 *         this, or because Push core enabled inbound execution and `10`'s attached payload did the
 *         work — this exits cleanly rather than deploying a second wallet at index 1. That matters:
 *         the mandate and every predicted address are derived from index 0.
 *
 *         THE NONCE IS READ HERE, NEVER CACHED. `BobPayload.signedMulticall` reads the UEA's stored
 *         counter immediately before signing, because the digest binds it and a stale value
 *         produces a signature that verifies against nothing.
 */
contract ArriveComplete is Script {
    error UEANotDeployed(address uea);
    error UEANotFunded(address uea, uint256 balance);
    error NoPCForGas(address uea);
    error SetupFailed(address agw);

    /// @dev How long Bob's signature stays valid. Long enough to relay by hand, short enough that a
    ///      signature left on a terminal is not indefinitely useful.
    uint256 internal constant VALID_FOR = 1 hours;

    /// @dev Must match `10_Arrive`, so both routes produce the same wallet record.
    string internal constant WALLET_LABEL = "demo-agw-1";

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits, and holds no authority");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address prc20 = AddressBook.donut("PRC20_USDC");
        address gatewayPC = AddressBook.donut("UniversalGatewayPC");
        address factory = AddressBook.ours("factoryProxy");

        DemoLog.header("ACT 1", "The wallet is built");
        DemoLog.addrPlain("Bob signs", vm.addr(bobPk));
        DemoLog.addrPlain("Relayer submits", vm.addr(relayerPk));
        DemoLog.note("    No authority. Anyone could do this.");
        DemoLog.blank();

        _requireArrived(uea, prc20);

        // Already built? Then the work is done and repeating it would deploy a SECOND wallet.
        (, bool deployed) = IAGWFactory(factory).predictWallet(uea, 0);
        if (deployed) {
            DemoLog.ok("already built", "the wallet exists; nothing to do");
            _report(agw, prc20, gatewayPC);
            DemoLog.footer();
            return;
        }

        Multicall[] memory calls = Identity.arrivalCalls(factory, prc20, agw, gatewayPC, Amounts.bridge(), WALLET_LABEL);
        (UniversalPayload memory payload, bytes memory signature) =
            BobPayload.signedMulticall(uea, calls, bobPk, VALID_FOR);

        DemoLog.kv("Payload", "3 entries, one signature");
        DemoLog.note("    1  deployWallet          -> the UEA becomes the owner");
        DemoLog.note(
            string.concat(
                "    2  transfer ",
                DemoLog.formatAmount(Amounts.bridge(), 6, "pUSDC"),
                "   -> into an address computed before it existed"
            )
        );
        DemoLog.note("    3  approve the gateway   -> through the owner door");
        DemoLog.kv("UEA nonce", vm.toString(payload.nonce));
        DemoLog.blank();

        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        _assertPostConditions(factory, uea, agw, prc20, gatewayPC);
        _report(agw, prc20, gatewayPC);

        DemoLog.blank();
        DemoLog.line(DemoLog.bold("One Ethereum transaction and one signature."));
        DemoLog.line(DemoLog.bold("Bob has a funded, armed agent wallet on a chain he has never touched."));
        DemoLog.footer();
    }

    /// @dev The relay has to have landed first. Each failure names what is missing and why.
    function _requireArrived(address uea, address prc20) internal view {
        if (uea.code.length == 0) revert UEANotDeployed(uea);

        uint256 balance = IERC20(prc20).balanceOf(uea);
        if (balance < Amounts.bridge()) revert UEANotFunded(uea, balance);

        // The UEA pays its own gas when it executes; the bridge's native leg supplies it.
        if (uea.balance == 0) revert NoPCForGas(uea);
    }

    /**
     * @dev Part 5.1's four post-conditions, asserted rather than eyeballed. An audience watching an
     *      assertion pass is worth more than a claim, and a silent partial success here would only
     *      surface two acts later.
     */
    function _assertPostConditions(address factory, address uea, address agw, address prc20, address gatewayPC)
        internal
        view
    {
        (address predicted, bool deployed) = IAGWFactory(factory).predictWallet(uea, 0);
        if (!deployed || predicted != agw || agw.code.length == 0) revert SetupFailed(agw);

        if (IERC20(prc20).balanceOf(agw) < Amounts.bridge()) revert SetupFailed(agw);
        if (IERC20(prc20).allowance(agw, gatewayPC) == 0) revert SetupFailed(agw);

        DemoLog.ok("deployed", "at exactly the predicted address");
        DemoLog.ok("funded", DemoLog.formatAmount(IERC20(prc20).balanceOf(agw), 6, "pUSDC"));
        DemoLog.ok("armed", "gateway allowance set");
    }

    function _report(address agw, address prc20, address gatewayPC) internal view {
        DemoLog.blank();
        DemoLog.addr("AGW", agw, true);
        DemoLog.money("Holds", IERC20(prc20).balanceOf(agw), 6, "pUSDC");
        DemoLog.money("PC", agw.balance, 18, "PC");
        DemoLog.kv("Allowance", IERC20(prc20).allowance(agw, gatewayPC) == type(uint256).max ? "unlimited" : "set");
    }
}
