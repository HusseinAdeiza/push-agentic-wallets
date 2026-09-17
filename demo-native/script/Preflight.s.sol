// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";

import { DemoUSDC } from "../contracts/DemoUSDC.sol";
import { StakeDummy } from "../contracts/StakeDummy.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { Amounts } from "../lib/Amounts.sol";
import { DemoLog } from "../lib/DemoLog.sol";
import { Keys } from "../lib/Keys.sol";
import { Ledger } from "../lib/Ledger.sol";

interface IURPVersion {
    function version() external view returns (string memory);
}

/**
 * @title  Preflight
 * @notice The green/red checklist. Run at T-1 hour AND five minutes before presenting.
 *
 * @dev    EVERY CHECK IS READ LIVE. Nothing here trusts a config file, a previous run, or this
 *         document. The single most expensive failure mode in a live demo is a script that proceeds
 *         against a wrong address and fails three acts later with an opaque error, and this is the
 *         instrument that prevents it.
 *
 *         IT COUNTS FAILURES RATHER THAN REVERTING ON THE FIRST. An operator needs the WHOLE list,
 *         not the first problem — fixing them one run at a time is how a T-5-minutes check becomes
 *         a T-plus-20 scramble.
 */
contract Preflight is Script {
    uint256 internal _failures;

    function run() external {
        DemoLog.header("PREFLIGHT", "Is this demo ready?");

        _chain();
        _contracts();
        _people();
        _pool();
        _ledger();

        DemoLog.blank();
        if (_failures == 0) {
            DemoLog.ok("READY", "every check passed");
        } else {
            DemoLog.fail("NOT READY", string.concat(vm.toString(_failures), " check(s) failed - see above"));
        }
        DemoLog.footer();

        require(_failures == 0, "preflight failed");
    }

    // ─────────────────────────────── checks ───────────────────────────────

    function _chain() private {
        _check("chain is Donut (42101)", block.chainid == 42101, vm.toString(block.chainid));
    }

    function _contracts() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Contracts"));

        address urp = AddressBook.ours("urp");
        string memory v = IURPVersion(urp).version();
        _check("URP answers version() through the proxy", keccak256(bytes(v)) == keccak256(bytes("1.0.0")), v);

        address factory = AddressBook.ours("factoryProxy");
        address impl = IAGWFactory(factory).walletImplementation();
        _check("factory has a wallet implementation", impl != address(0), vm.toString(impl));

        DemoUSDC token = DemoUSDC(AddressBook.native("DemoUSDC"));
        _check("dUSDC has 6 decimals", token.decimals() == Amounts.DECIMALS, vm.toString(token.decimals()));
        _check(
            "dUSDC symbol is dUSDC (NOT 'USDC')",
            keccak256(bytes(token.symbol())) == keccak256(bytes(Amounts.SYMBOL)),
            token.symbol()
        );

        StakeDummy stake = StakeDummy(AddressBook.native("StakeDummy"));
        _check("StakeDummy stakes dUSDC", address(stake.token()) == address(token), vm.toString(address(stake.token())));
    }

    function _people() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("People"));

        address bob = Keys.addressOf("BOB_KEY", "the user");
        address agent = Keys.addressOf("AGENT_KEY", "the agent");
        address relayer = Keys.addressOf("PC_RELAYER_KEY", "the relayer");
        address deployer = Keys.addressOf("PRIVATE_KEY", "the deployer");

        // FOUR DISTINCT ADDRESSES. Reusing one key for two roles makes the demo's central claim —
        // that the agent is separate from the owner and from the relayer — literally untrue.
        bool distinct = bob != agent && bob != relayer && bob != deployer && agent != relayer && agent != deployer
            && relayer != deployer;
        _check("bob / agent / relayer / deployer are four distinct addresses", distinct, "");

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));

        _check("Bob has PC for ~7 transactions", bob.balance >= 1 ether, _pc(bob.balance));
        _check(
            "Bob has enough dUSDC for act 1",
            token.balanceOf(bob) >= Amounts.WALLET_FUND + Amounts.THROWAWAY_FUND,
            DemoLog.formatAmount(token.balanceOf(bob), Amounts.DECIMALS, Amounts.SYMBOL)
        );
        _check("Relayer has PC to submit", relayer.balance >= 5 ether, _pc(relayer.balance));

        // THE THESIS, AS AN ASSERTION. If the agent ever holds funds, the demo's central claim is
        // no longer true on stage, and it belongs here rather than in a rule nobody checks.
        _check("Agent holds NO PC", agent.balance == 0, _pc(agent.balance));
        _check("Agent holds NO dUSDC", token.balanceOf(agent) == 0, vm.toString(token.balanceOf(agent)));
    }

    function _pool() private {
        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Reward pool"));

        IERC20 token = IERC20(AddressBook.native("DemoUSDC"));
        uint256 pool = token.balanceOf(AddressBook.native("StakeDummy"));

        // One successful unstake per run, at `REWARD` each.
        _check(
            "pool funds at least one more unstake",
            pool >= Amounts.REWARD,
            DemoLog.formatAmount(pool, Amounts.DECIMALS, Amounts.SYMBOL)
        );
    }

    function _ledger() private {
        if (!Ledger.has("agw")) {
            DemoLog.blank();
            DemoLog.note("No wallet in the ledger - this is a FRESH run. Start at act1a.");
            return;
        }

        DemoLog.blank();
        DemoLog.line(DemoLog.bold("Ledger"));

        address agw = Ledger.addr("agw", "10_DeployWallet");
        address bob = Keys.addressOf("BOB_KEY", "the user");
        IAGWFactory factory = IAGWFactory(AddressBook.ours("factoryProxy"));

        _check("the recorded wallet is a real wallet", factory.isWallet(agw), vm.toString(agw));
        _check("and Bob owns it", factory.ownerOf(agw) == bob, vm.toString(factory.ownerOf(agw)));

        // A throwaway wallet left holding funds is money stranded by a half-finished 4f.
        if (Ledger.has("throwawayAgw")) {
            address t = Ledger.addr("throwawayAgw", "47_Throwaway_DeployAndFund");
            uint256 held = IERC20(AddressBook.native("DemoUSDC")).balanceOf(t);
            _check(
                "the throwaway wallet holds nothing (sweep it if not)",
                held == 0,
                DemoLog.formatAmount(held, Amounts.DECIMALS, Amounts.SYMBOL)
            );
        }
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _check(string memory what, bool pass, string memory detail) private {
        if (pass) {
            DemoLog.ok(what, detail);
        } else {
            DemoLog.fail(what, detail);
            ++_failures;
        }
    }

    function _pc(uint256 wei_) private pure returns (string memory) {
        return string.concat(vm.toString(wei_ / 1e18), ".", vm.toString((wei_ % 1e18) / 1e16), " PC");
    }
}
