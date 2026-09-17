// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

/**
 * @title  DemoLog
 * @notice Terminal presentation for the demo. The terminal is the only interface the audience
 *         sees, so this is not decoration.
 *
 * @dev    THE PALETTE, and one choice in it is load-bearing:
 *
 *         EXPECTED REFUSALS ARE AMBER, NEVER RED. The five gauntlet refusals are the system
 *         working exactly as designed — they are the best part of the demo. Painting them red
 *         trains the audience to read success as failure. Red is reserved for something actually
 *         going wrong.
 *
 *         TWO ABSOLUTE RULES, both enforced by the helpers rather than by discipline:
 *           · Every amount printed is human-readable. `money()` exists so that no script has to
 *             format one by hand, because an audience cannot parse six decimal places at speed.
 *           · Every transaction prints an explorer link. The explorer is the credibility layer —
 *             it is the proof this is a real chain and not a local fork.
 *
 *         NO_COLOR is honoured. Foundry output is often piped or captured, and ANSI escapes in a
 *         log file are noise.
 */
library DemoLog {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Label column width. Fixed so values align vertically down an entire run; misaligned
    ///      columns are what make terminal output look amateur.
    uint256 private constant LABEL_WIDTH = 14;

    uint256 private constant BOX_WIDTH = 74;

    string private constant PUSH_EXPLORER = "https://donut.push.network";
    string private constant SEPOLIA_EXPLORER = "https://sepolia.etherscan.io";

    // ───────────────────────────────── colour ─────────────────────────────────

    function _colorOn() private view returns (bool) {
        // Any non-empty NO_COLOR disables colour, per the no-color.org convention.
        return bytes(vm.envOr("NO_COLOR", string(""))).length == 0;
    }

    function _wrap(string memory code, string memory s) private view returns (string memory) {
        if (!_colorOn()) return s;
        return string.concat("\x1b[", code, "m", s, "\x1b[0m");
    }

    function cyan(string memory s) internal view returns (string memory) {
        return _wrap("96", s);
    }

    function dim(string memory s) internal view returns (string memory) {
        return _wrap("2;37", s);
    }

    function bold(string memory s) internal view returns (string memory) {
        return _wrap("1;97", s);
    }

    function green(string memory s) internal view returns (string memory) {
        return _wrap("32", s);
    }

    function amber(string memory s) internal view returns (string memory) {
        return _wrap("33", s);
    }

    function red(string memory s) internal view returns (string memory) {
        return _wrap("31", s);
    }

    function link(string memory s) internal view returns (string memory) {
        return _wrap("4;34", s);
    }

    // ───────────────────────────────── layout ─────────────────────────────────

    /**
     * @notice Open a box.
     * @param act   Act label, printed uppercase — e.g. "ACT 2". Empty for an unnumbered box.
     * @param title Sentence-case title.
     */
    function header(string memory act, string memory title) internal view {
        string memory label = bytes(act).length == 0 ? title : string.concat(act, " . ", title);
        string memory open = string.concat(unicode"┌─ ", label, " ");
        console.log(cyan(_padRule(open)));
    }

    /// @notice Close a box.
    function footer() internal view {
        console.log(cyan(_rule(unicode"└", unicode"─")));
    }

    /// @notice A full-width divider between acts.
    function rule() internal view {
        console.log(cyan(_rule("", unicode"─")));
    }

    /// @notice A blank line inside a box.
    function blank() internal view {
        console.log(cyan(unicode"│"));
    }

    /**
     * @notice The padded two-column primitive every other helper builds on.
     * @param label Left column, padded to a fixed width.
     * @param value Right column.
     */
    function kv(string memory label, string memory value) internal view {
        console.log(string.concat(cyan(unicode"│  "), dim(_pad(label)), "  ", value));
    }

    /// @notice A free-form note line inside a box.
    function note(string memory s) internal view {
        console.log(string.concat(cyan(unicode"│  "), dim(s)));
    }

    /// @notice A plain line inside a box, no label column.
    function line(string memory s) internal view {
        console.log(string.concat(cyan(unicode"│  "), s));
    }

    // ───────────────────────────────── status ─────────────────────────────────

    /// @notice A check clearing. Green.
    function ok(string memory label, string memory detail) internal view {
        console.log(string.concat(cyan(unicode"│  "), green(unicode"✓ "), dim(_pad(label)), "  ", detail));
    }

    /**
     * @notice An EXPECTED refusal — the system working. Amber, never red.
     * @param label Short label, e.g. the gate name.
     * @param detail What was refused.
     */
    function refused(string memory label, string memory detail) internal view {
        console.log(string.concat(cyan(unicode"│  "), amber(unicode"✗ "), dim(_pad(label)), "  ", amber(detail)));
    }

    /// @notice Something actually going wrong. Red.
    function fail(string memory label, string memory detail) internal view {
        console.log(string.concat(cyan(unicode"│  "), red(unicode"✗ "), dim(_pad(label)), "  ", red(detail)));
    }

    // ──────────────────────────────── values ────────────────────────────────

    /**
     * @notice Print an address with a checksummed rendering and an explorer link.
     * @param label   Left column.
     * @param a       The address.
     * @param isPush  True for Donut, false for Sepolia — selects the explorer.
     */
    function addr(string memory label, address a, bool isPush) internal view {
        string memory base = isPush ? PUSH_EXPLORER : SEPOLIA_EXPLORER;
        kv(label, string.concat(bold(vm.toString(a)), "  ", link(string.concat(base, "/address/", vm.toString(a)))));
    }

    /// @notice An address with no explorer link, for when the line would be too wide.
    function addrPlain(string memory label, address a) internal view {
        kv(label, bold(vm.toString(a)));
    }

    /**
     * @notice Print an amount HUMAN-READABLE — `50.00 USDC`, never `50000000`.
     * @dev    Two decimal places shown regardless of the token's real precision: the audience is
     *         reading money, not auditing precision. Truncates rather than rounds, so a displayed
     *         figure is never larger than the real one.
     * @param label    Left column.
     * @param amount   Raw on-chain amount.
     * @param decimals Token decimals.
     * @param symbol   Token symbol.
     */
    function money(string memory label, uint256 amount, uint8 decimals, string memory symbol) internal view {
        kv(label, bold(formatAmount(amount, decimals, symbol)));
    }

    /**
     * @notice Format an amount as a human-readable string. Exposed so callers can compose it into
     *         a sentence rather than a labelled row.
     *
     * @dev    PRECISION ADAPTS TO MAGNITUDE, and it has to. Two decimal places is right for USDC —
     *         `50.00 USDC` is exactly how an audience reads money. It is useless for native PC,
     *         where a gas fee of ~0.00115 PC renders as `0.00 PC`: three different values all
     *         printing as zero, which is worse than printing the raw integer because it looks
     *         authoritative while saying nothing.
     *
     *         So: amounts at or above 1 whole unit get 2 places; smaller non-zero amounts get 6,
     *         enough to separate a fee from a budget from a cap. A genuine zero still prints
     *         `0.00`, since there is nothing to reveal.
     *
     * @param amount   Raw on-chain amount.
     * @param decimals Token decimals.
     * @param symbol   Token symbol; may be empty.
     */
    function formatAmount(uint256 amount, uint8 decimals, string memory symbol) internal pure returns (string memory) {
        uint256 scale = 10 ** decimals;
        uint256 whole = amount / scale;

        uint8 places = (whole == 0 && amount != 0) ? 6 : 2;
        if (places > decimals) places = decimals;

        string memory body;
        if (places == 0) {
            body = _thousands(whole);
        } else {
            uint256 frac = (amount % scale) / (10 ** (decimals - places));
            body = string.concat(_thousands(whole), ".", _padFrac(frac, places));
        }

        return bytes(symbol).length == 0 ? body : string.concat(body, " ", symbol);
    }

    /// @dev Left-pad the fractional part with zeros to `places` digits, so `.5` renders as `.500000`
    ///      rather than `.5` — otherwise column alignment breaks and magnitudes misread.
    function _padFrac(uint256 frac, uint8 places) private pure returns (string memory) {
        string memory s = vm.toString(frac);
        uint256 have = bytes(s).length;
        for (uint256 i = have; i < places; ++i) {
            s = string.concat("0", s);
        }
        return s;
    }

    /// @notice A transaction hash with its explorer link. Every transaction must print one.
    function txLink(string memory label, bytes32 h, bool isPush) internal view {
        string memory base = isPush ? PUSH_EXPLORER : SEPOLIA_EXPLORER;
        kv(label, link(string.concat(base, "/tx/", vm.toString(h))));
    }

    // ──────────────────────────────── internals ────────────────────────────────

    /// @dev Right-pad to the fixed label column. Over-long labels are left intact rather than
    ///      truncated — a clipped label is worse than a nudged column.
    function _pad(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= LABEL_WIDTH) return s;
        bytes memory out = new bytes(LABEL_WIDTH);
        for (uint256 i; i < LABEL_WIDTH; ++i) {
            out[i] = i < b.length ? b[i] : bytes1(" ");
        }
        return string(out);
    }

    /// @dev Extend an opening string with box rule to the full width.
    function _padRule(string memory open) private pure returns (string memory) {
        uint256 visible = _displayWidth(open);
        if (visible >= BOX_WIDTH) return open;
        string memory out = open;
        for (uint256 i = visible; i < BOX_WIDTH; ++i) {
            out = string.concat(out, unicode"─");
        }
        return out;
    }

    /// @dev A full-width rule, optionally with a corner glyph.
    function _rule(string memory corner, string memory fill) private pure returns (string memory) {
        string memory out = corner;
        uint256 start = bytes(corner).length == 0 ? 0 : 1;
        for (uint256 i = start; i < BOX_WIDTH; ++i) {
            out = string.concat(out, fill);
        }
        return out;
    }

    /**
     * @dev Count display columns, not bytes. The box glyphs are multi-byte UTF-8, so `bytes().length`
     *      over-counts them and the rules come out short. Counts non-continuation bytes
     *      (`0b10xxxxxx`), which is exact for the BMP glyphs used here.
     */
    function _displayWidth(string memory s) private pure returns (uint256 w) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (uint8(b[i]) & 0xC0 != 0x80) ++w;
        }
    }

    /// @dev Thousands separators. `1000000` reads as `1,000,000` — an audience parses that at a
    ///      glance and does not parse the bare digits.
    function _thousands(uint256 n) private pure returns (string memory) {
        bytes memory digits = bytes(vm.toString(n));
        uint256 len = digits.length;
        uint256 commas = (len - 1) / 3;
        if (commas == 0) return string(digits);

        bytes memory out = new bytes(len + commas);
        uint256 w = out.length;
        for (uint256 i; i < len; ++i) {
            if (i > 0 && i % 3 == 0) out[--w] = ",";
            out[--w] = digits[len - 1 - i];
        }
        return string(out);
    }
}
