// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { DemoLog } from "../lib/DemoLog.sol";
import { Keys } from "../lib/Keys.sol";
import { Ledger } from "../lib/Ledger.sol";
import { Amounts } from "../lib/Amounts.sol";
import { IUniversalCore } from "../lib/PushCore.sol";
import { IURP } from "../../src/interfaces/IURP.sol";
import { SEND_OUTBOUND_SELECTOR } from "../../src/libraries/PushWalletTypes.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";

/// @dev The engine view Preflight needs. Declared locally rather than importing SmartSession's
///      whole surface, which drags in the user-defined `PermissionId` type for one call.
interface ISessionEngineView {
    function isPermissionEnabled(bytes32 permissionId, address account) external view returns (bool);
}

/// @dev The wallet's nonce view.
interface IWalletView {
    function getNonce(uint192 nonceKey) external view returns (uint64);
    function owner() external view returns (address);
}

/**
 * @title  Preflight
 * @notice Read only, never broadcasts. Run at T-1 hour, and again five minutes before presenting.
 *
 * @dev    ONE GREEN/RED CHECKLIST, and every line names both the specific assertion and the
 *         specific act that fails without it. "Preflight failed" with no detail is not acceptable
 *         output — the point is to convert a mid-demo failure into a pre-demo one, and that only
 *         works if the remedy is on screen.
 *
 *         THREE PHASES, DETECTED FROM THE LEDGER, NOT PASSED IN:
 *
 *           A  always checkable  — keys, RPCs, address book, balances, token pair, reward pool
 *           B  after Act 1       — wallet exists, owned, funded, armed; mandate live; CEA matches
 *           C  after Act 2       — spend counter and nonce lane agree with the ledger
 *
 *         CHECKS OUT OF SCOPE PRINT GREY, NEVER RED. A preflight that goes red because Act 1 has
 *         not run yet is a preflight you learn to ignore, and an ignored preflight is worse than
 *         none. Phase is inferred from which ledger keys exist, so nobody has to remember a flag.
 *
 *         EXIT CODE IS THE CONTRACT. Any in-scope failure reverts, so `just preflight` fails loudly
 *         rather than printing red text into a scrollback nobody reads.
 */
contract Preflight is Script {
    error NotReady(string what, string breaks);

    /// @dev Bob needs enough for the bridge plus gas for one Sepolia transaction.
    uint256 internal constant BOB_MIN_ETH = 0.01 ether;

    /// @dev The relayer submits every Push-side transaction and funds the wallet's 20 PC.
    uint256 internal constant RELAYER_MIN_PC = 25 ether;

    /// @dev Enough for many outbounds at the current quote.
    uint256 internal constant AGW_MIN_PC = 5 ether;

    uint256 internal failures;
    uint256 internal phase;

    function run() external {
        phase = _detectPhase();

        DemoLog.header("PREFLIGHT", _phaseTitle());
        _phaseA();
        if (phase >= 2) _phaseB();
        else _skipped("Act 1 checks", "run act1 first");
        if (phase >= 3) _phaseC();
        else _skipped("Act 2 checks", "run act2 first");
        DemoLog.footer();

        if (failures > 0) revert NotReady("see the red lines above", "the acts they name");

        DemoLog.header("", "READY");
        DemoLog.line(DemoLog.green(DemoLog.bold("  Every check in scope passed.")));
        DemoLog.footer();
    }

    // ────────────────────────────── phase detection ──────────────────────────────

    /// @dev 1 = setup only · 2 = Act 1 done · 3 = Act 2 done. Inferred from the ledger, because a
    ///      flag someone has to set is a flag someone forgets.
    function _detectPhase() internal view returns (uint256) {
        if (!Ledger.has("agw")) return 1;
        if (!Ledger.has("permissionId")) return 2;
        return Ledger.has("nonceSeq") && Ledger.num("nonceSeq", "20_Stake") > 0 ? 3 : 2;
    }

    function _phaseTitle() internal view returns (string memory) {
        if (phase == 1) return "Phase A - setup";
        if (phase == 2) return "Phase B - mandate live";
        return "Phase C - agent has acted";
    }

    // ─────────────────────────────────── phase A ───────────────────────────────────

    function _phaseA() internal {
        DemoLog.line(DemoLog.bold("A  Always checkable"));

        _keys();
        _chains();
        _addressBook();
        _tokenPair();
        _balances();
        _rewardPool();
    }

    function _keys() internal {
        // `Keys.load` reverts naming the variable if one is missing, so reaching the end is the
        // assertion. Only addresses are ever printed.
        address bob = Keys.addressOf("BOB_KEY", "Bob signs the arrival and every owner action");
        address agent = Keys.addressOf("AGENT_KEY", "the agent signs its requests");
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer submits every Push-side tx");

        _check(bob != agent, "keys distinct", "Bob and the agent MUST be different keys - that separation is the demo");
        _check(relayer != bob && relayer != agent, "relayer distinct", "the relayer must hold no role");
    }

    function _chains() internal {
        _check(block.chainid == 42101, "donut rpc", "every Push-side act; run with --rpc-url $PUSH_DONUT_RPC_URL");

        // The Sepolia endpoint is checked by reading a contract that only exists there.
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        _check(block.chainid == 11155111, "sepolia rpc", "Act 1a and every far-chain assertion");
        vm.selectFork(donut);
    }

    /**
     * @dev Every key present AND has code, with two documented exemptions.
     *
     *      `universalExecutorModule` gates `creditRevert`, which Push core does not yet call, and
     *      has no code on Donut. `ed25519Precompile` is codeless BY DESIGN — it is a precompile,
     *      reached through a raw staticcall precisely because a typed call would insert an
     *      `extcodesize` check and revert. Neither is used by this demo, which is ECDSA throughout.
     */
    function _addressBook() internal {
        _hasCode(AddressBook.ours("factoryProxy"), "factory", "Act 1b cannot deploy the wallet");
        _hasCode(AddressBook.ours("urp"), "urp", "the mandate has no policy to name");
        _hasCode(AddressBook.ours("sessionValidator"), "validator", "no agent signature can be checked");
        _hasCode(AddressBook.ours("sessionEngine"), "engine", "the agent door has no validator");
        _hasCode(AddressBook.donut("UniversalGatewayPC"), "gatewayPC", "every outbound");
        _hasCode(AddressBook.donut("UniversalCore"), "core", "the quote, and every fee");
        _hasCode(AddressBook.donut("UEAFactory"), "ueaFactory", "Bob has no identity on Push Chain");
        _hasCode(AddressBook.donut("PRC20_USDC"), "pUSDC", "nothing to bridge or spend");

        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        _hasCode(AddressBook.sepolia("UniversalGateway"), "sepolia gateway", "Act 1a, the only Ethereum tx");
        _hasCode(AddressBook.sepolia("Vault"), "vault", "the far leg of every outbound");
        _hasCode(AddressBook.sepolia("CEAFactory"), "ceaFactory", "the CEA cannot be predicted or deployed");
        _hasCode(AddressBook.sepolia("USDC"), "sepolia USDC", "Bob has nothing to bridge");
        _hasCode(AddressBook.sepolia("StakeDummy"), "stakeDummy", "act1d and act1e both name it; run setup first");
        vm.selectFork(donut);
    }

    /// @dev The check that catches a wrong token before it wastes an act. A deprecated PRC20 still
    ///      quotes and still resolves to Sepolia, so the failure would otherwise be silent.
    function _tokenPair() internal {
        address prc20 = AddressBook.donut("PRC20_USDC");
        (address gasToken,,,, string memory namespace,) =
            IUniversalCore(AddressBook.donut("UniversalCore")).getOutboundTxGasAndFees(prc20, 0);

        _check(gasToken != address(0), "token registered", "every outbound; the PRC20 is unknown to core");
        _check(
            keccak256(bytes(namespace)) == keccak256("eip155:11155111"),
            "destination",
            "the outbound would land on the wrong chain"
        );
        _check(!_endsWithOld(IERC20Metadata(prc20).symbol()), "not deprecated", "a .old PRC20 fails SILENTLY");
    }

    function _balances() internal {
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer");
        _check(relayer.balance >= RELAYER_MIN_PC, "relayer PC", "every Push-side transaction, and the wallet's 20 PC");

        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        address bob = Keys.addressOf("BOB_KEY", "Bob");
        IERC20 usdc = IERC20(AddressBook.sepolia("USDC"));

        _check(bob.balance >= BOB_MIN_ETH, "bob ETH", "Act 1a, the bridge transaction");
        _check(usdc.balanceOf(bob) >= Amounts.bridge(), "bob USDC", "Act 1a has nothing to bridge");

        vm.selectFork(donut);
    }

    /// @dev A demo that dies at Act 4 because rehearsals drained the reward pool is the most
    ///      avoidable failure in this build, and it dies at the very last act.
    function _rewardPool() internal {
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        address stake = AddressBook.sepolia("StakeDummy");
        uint256 pool = IERC20(AddressBook.sepolia("USDC")).balanceOf(stake);

        _check(pool >= Amounts.REWARD, "reward pool", "Act 4a - unstake pays principal PLUS a flat 10 USDC");
        if (pool >= Amounts.REWARD && pool < 3 * Amounts.REWARD) {
            DemoLog.note(string.concat("      pool is low: ", DemoLog.formatAmount(pool, 6, "USDC"), " - top up soon"));
        }

        vm.selectFork(donut);
    }

    // ─────────────────────────────────── phase B ───────────────────────────────────

    function _phaseB() internal {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("B  After Act 1"));

        address agw = Ledger.addr("agw", "10_Arrive");
        address uea = Ledger.addr("uea", "10_Arrive");
        address prc20 = AddressBook.donut("PRC20_USDC");

        _hasCode(agw, "wallet exists", "every act from here");
        _check(IWalletView(agw).owner() == uea, "owner is the UEA", "Bob does not control the wallet");
        _check(IERC20(prc20).balanceOf(agw) > 0, "wallet funded", "the agent has nothing to spend");
        _check(
            IERC20(prc20).allowance(agw, AddressBook.donut("UniversalGatewayPC")) > 0,
            "gateway armed",
            "EVERY agent request reverts inside the gateway - the least obvious prerequisite"
        );
        _check(agw.balance >= AGW_MIN_PC, "wallet PC", "outbounds cannot pay the gas swap; run act1c");

        _mandate(agw);
        _ceaPrediction();
    }

    function _mandate(address agw) internal {
        if (!Ledger.has("permissionId")) {
            _skipped("mandate", "not granted yet; run act1e");
            return;
        }

        bytes32 pid = Ledger.word("permissionId", "14_GrantMandate");
        address engine = AddressBook.ours("sessionEngine");

        _check(
            ISessionEngineView(engine).isPermissionEnabled(pid, agw),
            "mandate live",
            "every agent request; the mandate was revoked or never landed"
        );

        // The PC cap is frozen at grant time. If fees have risen past it, gate 8 refuses every
        // request — and the only remedy is a regrant, which is not something to discover on stage.
        if (Ledger.has("mandate.maxPCPerCall")) {
            uint256 granted = Ledger.num("mandate.maxPCPerCall", "14_GrantMandate");
            uint256 needed = Ledger.has("quote.msgValue") ? Ledger.num("quote.msgValue", "01_Quote") : 0;
            _check(
                needed == 0 || needed <= granted,
                "PC cap covers fees",
                "URP gate 8 refuses every agent request; revoke and regrant"
            );
        }
    }

    /// @dev The CEA is predicted before the wallet exists and named in the mandate. If the deployed
    ///      address ever differed from the prediction, gates 14 and 15 would measure against the
    ///      wrong account and the agent could stake for a stranger.
    function _ceaPrediction() internal {
        if (!Ledger.has("predictedCEA")) return;

        address predicted = Ledger.addr("predictedCEA", "10_Arrive");
        uint256 donut = vm.activeFork();
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        if (predicted.code.length == 0) {
            _skipped("cea deployed", "not yet; act1d deploys it");
        } else {
            _ok("cea deployed", "at the predicted address");
        }

        vm.selectFork(donut);
    }

    // ─────────────────────────────────── phase C ───────────────────────────────────

    function _phaseC() internal {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("C  After Act 2"));

        address agw = Ledger.addr("agw", "10_Arrive");
        uint256 expectedSeq = Ledger.num("nonceSeq", "20_Stake");

        _check(
            IWalletView(agw).getNonce(0) == uint64(expectedSeq),
            "nonce lane agrees",
            "the next agent request reverts InvalidNonce; run `just state` and re-sync"
        );

        bytes32 pid = Ledger.word("permissionId", "14_GrantMandate");
        IURP.Config memory cfg = IURP(AddressBook.ours("urp")).getConfig(_configId(pid, agw), agw);

        DemoLog.kv(
            "spend",
            string.concat(
                DemoLog.formatAmount(cfg.spent, 6, ""),
                " / ",
                DemoLog.formatAmount(cfg.maxAmountTotal, 6, "USDC"),
                "   ",
                DemoLog.formatAmount(cfg.maxAmountTotal - cfg.spent, 6, "USDC"),
                " remaining"
            )
        );

        _check(cfg.spent <= cfg.maxAmountTotal, "budget intact", "the mandate is exhausted; G5 needs headroom");
    }

    /**
     * @dev The config id, derived exactly as the engine does — three nested hashes, and the ORDER
     *      of the operands matters at every level:
     *
     *        actionId = keccak(target ‖ selector)
     *        configId = keccak(account ‖ keccak(permissionId ‖ actionId))
     *
     *      Transcribed from `test/integration/E2E.t.sol`, which asserts it against the live engine.
     *      An earlier version of this function had the operands reversed and the account omitted;
     *      it produced a plausible-looking id that read an empty config, which would have reported
     *      `spent == 0` for a mandate that had been spent. Do not "simplify" it.
     */
    function _configId(bytes32 permissionId, address account) internal view returns (ConfigId) {
        bytes32 actionId = keccak256(abi.encodePacked(AddressBook.donut("UniversalGatewayPC"), SEND_OUTBOUND_SELECTOR));
        return ConfigId.wrap(keccak256(abi.encodePacked(account, keccak256(abi.encodePacked(permissionId, actionId)))));
    }

    // ───────────────────────────────── primitives ─────────────────────────────────

    function _check(bool passed, string memory what, string memory breaks) internal {
        if (passed) {
            DemoLog.ok(what, "");
        } else {
            DemoLog.fail(what, breaks);
            ++failures;
        }
    }

    function _hasCode(address a, string memory what, string memory breaks) internal {
        _check(a.code.length > 0, what, breaks);
    }

    function _ok(string memory what, string memory detail) internal view {
        DemoLog.ok(what, detail);
    }

    /// @dev Out of scope for the current phase. GREY, never red — see the contract docs.
    function _skipped(string memory what, string memory why) internal view {
        DemoLog.kv(string.concat("- ", what), DemoLog.dim(why));
    }

    function _endsWithOld(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length < 4) return false;
        uint256 n = b.length;
        return b[n - 4] == "." && b[n - 3] == "o" && b[n - 2] == "l" && b[n - 1] == "d";
    }
}

/// @dev Minimal metadata surface for the symbol check.
interface IERC20Metadata {
    function symbol() external view returns (string memory);
}
