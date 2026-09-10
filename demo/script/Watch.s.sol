// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "../lib/AddressBook.sol";
import { DemoLog } from "../lib/DemoLog.sol";
import { Ledger } from "../lib/Ledger.sol";

/// @dev `StakeDummy`'s ledger, read across the boundary.
interface IStakeView {
    function totalBalance(address) external view returns (uint256);
}

/**
 * @title  Watch
 * @notice Read only, never broadcasts. Run after every cross-chain hop.
 *
 * @dev    THIS IS WHAT MAKES THE CROSS-CHAIN WAIT WATCHABLE INSTEAD OF AWKWARD. A relay takes tens
 *         of seconds; measured at ~30–45s Sepolia→Donut. Standing in silence for that long reads as
 *         something having gone wrong, so this prints an elapsed counter and then the result.
 *
 *         POLLS STATE, NOT LOGS, AND THAT IS DELIBERATE. `cast logs` over a wide block range on
 *         Donut returns EMPTY rather than erroring — a silent false negative that once made a
 *         successful relay look like a failure. Balances and mappings cannot lie in that way, so
 *         every condition here is a state read.
 *
 *         WHAT TO WATCH IS CHOSEN BY NAME, so the justfile can expose one recipe per hop:
 *
 *           cea      — the CEA has code on Sepolia            (after act1d)
 *           staked   — StakeDummy credits the CEA             (after act2)
 *           unstaked — the CEA holds principal + reward       (after act4a)
 *           returned — the wallet's pUSDC rises               (after act4c)
 *
 *         ON TIMEOUT IT PRINTS WHERE TO LOOK, NOT JUST THAT IT GAVE UP. A timeout is not proof of
 *         failure — the Push-side decision is already complete and final, and only the far leg is
 *         outstanding. The explorer links let the presenter narrate while investigating rather than
 *         standing in silence, which is the difference between a delay and a disaster.
 */
contract Watch is Script {
    error WatchTimedOut(string what, uint256 seconds_);
    error UnknownTarget(string what);

    /// @dev Poll interval. Short enough that the counter feels live, long enough not to hammer
    ///      the RPC while an audience watches.
    uint256 internal constant INTERVAL = 10;

    /// @dev Default ceiling. Generous: a relay that has not landed in five minutes is a real
    ///      problem, not a slow block. Overridable via `WATCH_TIMEOUT` (seconds) — rehearsals want
    ///      to see the timeout branch without waiting the full five minutes for it.
    uint256 internal constant DEFAULT_TIMEOUT = 300;

    function _timeoutSeconds() internal view returns (uint256) {
        uint256 t = vm.envOr("WATCH_TIMEOUT", uint256(0));
        return t == 0 ? DEFAULT_TIMEOUT : t;
    }

    function run() external {
        string memory what = vm.envOr("WATCH", string("cea"));
        _dispatch(what);
    }

    function _dispatch(string memory what) internal {
        bytes32 k = keccak256(bytes(what));

        if (k == keccak256("cea")) return _watchCEA();
        if (k == keccak256("staked")) return _watchStaked();
        if (k == keccak256("unstaked")) return _watchUnstaked();
        if (k == keccak256("returned")) return _watchReturned();

        revert UnknownTarget(what);
    }

    // ──────────────────────────────── the four hops ────────────────────────────────

    /// @dev After act1d. The CEA is deployed by the first outbound Sepolia sees for this wallet,
    ///      at an address predicted before the wallet itself existed.
    function _watchCEA() internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");

        DemoLog.header("WATCH", "The CEA is deployed on Sepolia");
        DemoLog.addr("Predicted", cea, false);
        DemoLog.blank();

        uint256 elapsed = _pollSepolia(_hasCodeSelector(cea), "CEA deployed");

        DemoLog.ok("deployed", string.concat("after ", vm.toString(elapsed), "s"));
        DemoLog.line(DemoLog.bold("  The address matches the one printed before Act 1 sent anything."));
        DemoLog.footer();
    }

    /// @dev After act2. The assertion that matters is not "the transaction succeeded" but
    ///      "the money is staked" — so this reads StakeDummy's own ledger.
    function _watchStaked() internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");

        DemoLog.header("WATCH", "The agent's stake lands on Sepolia");
        DemoLog.addr("Beneficiary", cea, false);
        DemoLog.note("    Pinned at grant time. The agent could not have named another.");
        DemoLog.blank();

        uint256 before = _stakedBalance(cea);
        uint256 elapsed = _pollSepoliaBalance(cea, before, "staked");

        DemoLog.ok("staked", string.concat("after ", vm.toString(elapsed), "s"));
        DemoLog.money("Now staked", _stakedBalance(cea), 6, "USDC");
        DemoLog.footer();
    }

    /// @dev After act4a. The CEA should hold principal + the flat reward.
    function _watchUnstaked() internal {
        address cea = Ledger.addr("predictedCEA", "10_Arrive");

        DemoLog.header("WATCH", "The agent unwinds");
        DemoLog.blank();

        uint256 elapsed = _pollSepoliaUsdcRise(cea, _sepoliaUsdc(cea), "unstaked");

        DemoLog.ok("unstaked", string.concat("after ", vm.toString(elapsed), "s"));
        DemoLog.money("CEA holds", _sepoliaUsdc(cea), 6, "USDC");
        DemoLog.note("    Principal plus a flat reward. The agent earned it; it cannot take it home.");
        DemoLog.footer();
    }

    /// @dev After act4c. The return leg, watched on Donut rather than Sepolia.
    function _watchReturned() internal {
        address agw = Ledger.addr("agw", "10_Arrive");
        IERC20 prc20 = IERC20(AddressBook.donut("PRC20_USDC"));

        DemoLog.header("WATCH", "Bob brings the money home");
        DemoLog.blank();

        uint256 before = prc20.balanceOf(agw);
        uint256 elapsed;
        uint256 limit = _timeoutSeconds();
        for (uint256 t; t <= limit; t += INTERVAL) {
            if (prc20.balanceOf(agw) > before) {
                elapsed = t;
                break;
            }
            _tick(t);
            vm.sleep(INTERVAL * 1000);
            if (t + INTERVAL > limit) _timeout("returned", t);
        }

        DemoLog.ok("returned", string.concat("after ", vm.toString(elapsed), "s"));
        DemoLog.money("Wallet holds", prc20.balanceOf(agw), 6, "pUSDC");
        DemoLog.footer();
    }

    // ───────────────────────────────── polling ─────────────────────────────────

    /// @dev Poll Sepolia for code at an address. Re-selects the fork each round so the read is
    ///      fresh — a cached fork would return the same answer forever, which is exactly the kind
    ///      of stale read that once made a live result look wrong.
    function _pollSepolia(address target, string memory what) internal returns (uint256) {
        uint256 limit = _timeoutSeconds();
        for (uint256 t; t <= limit; t += INTERVAL) {
            vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
            if (target.code.length > 0) return t;
            _tick(t);
            vm.sleep(INTERVAL * 1000);
        }
        _timeout(what, limit);
        return limit;
    }

    function _pollSepoliaBalance(address cea, uint256 before, string memory what) internal returns (uint256) {
        uint256 limit = _timeoutSeconds();
        for (uint256 t; t <= limit; t += INTERVAL) {
            if (_stakedBalance(cea) > before) return t;
            _tick(t);
            vm.sleep(INTERVAL * 1000);
        }
        _timeout(what, limit);
        return limit;
    }

    function _pollSepoliaUsdcRise(address cea, uint256 before, string memory what) internal returns (uint256) {
        uint256 limit = _timeoutSeconds();
        for (uint256 t; t <= limit; t += INTERVAL) {
            if (_sepoliaUsdc(cea) > before) return t;
            _tick(t);
            vm.sleep(INTERVAL * 1000);
        }
        _timeout(what, limit);
        return limit;
    }

    function _stakedBalance(address cea) internal returns (uint256) {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        return IStakeView(AddressBook.sepolia("StakeDummy")).totalBalance(cea);
    }

    function _sepoliaUsdc(address who) internal returns (uint256) {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        return IERC20(AddressBook.sepolia("USDC")).balanceOf(who);
    }

    /// @dev Trivial helper so `_pollSepolia` can take an address without a lambda.
    function _hasCodeSelector(address a) internal pure returns (address) {
        return a;
    }

    function _tick(uint256 t) internal view {
        DemoLog.note(string.concat("    waiting... ", vm.toString(t), "s elapsed"));
    }

    /**
     * @dev A timeout names where to look. The Push-side decision is already complete and final —
     *      the outbound event is on Donut — and only Push's relay is outstanding. Saying that out
     *      loud, with a link, is a far better demo moment than silence.
     */
    function _timeout(string memory what, uint256 t) internal view {
        DemoLog.blank();
        DemoLog.fail(what, string.concat("not seen after ", vm.toString(t), "s"));
        DemoLog.note("The Push-side decision is COMPLETE - the outbound event is already on Donut.");
        DemoLog.note("What is outstanding is Push's relay to Sepolia, which is not ours.");
        DemoLog.blank();
        DemoLog.note("Show the outbound on the explorer and move to the gauntlet:");
        DemoLog.note("  the gauntlet needs no relay and fills the gap exactly.");
        DemoLog.footer();
        revert WatchTimedOut(what, t);
    }
}
