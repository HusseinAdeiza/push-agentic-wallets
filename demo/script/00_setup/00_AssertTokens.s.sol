// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { IUniversalCore } from "../../lib/PushCore.sol";

/**
 * @title  AssertTokens
 * @notice Chain: Donut (read only) · never broadcasts. Run before Act 1.
 *
 * @dev    ASSERTS THE SEEDED PAIR, RATHER THAN DISCOVERING IT. The token is the single input that
 *         pins the destination chain — the gateway derives the destination from the PRC20, and
 *         there is no chain selector anywhere in the flow. A wrong token therefore does not revert:
 *         it produces an outbound that passes every Push-side check, emits its event, and does
 *         nothing useful on Sepolia. That failure is invisible until minutes later, in front of an
 *         audience. This script is what makes it visible in five seconds instead.
 *
 *         THE `.old` CHECK IS NOT COSMETIC. Donut carries deprecated PRC20s — `USDC.eth.old` and
 *         `USDT.eth.old` — that still quote successfully and still resolve to `eip155:11155111`.
 *         Choosing one fails silently in exactly the way described above, so a symbol ending in
 *         `.old` is rejected outright.
 */
contract AssertTokens is Script {
    error WrongDestinationChain(string got, string expected);
    error DeprecatedToken(string symbol);
    error DecimalsMismatch(uint8 prc20, uint8 external_);
    error UnregisteredToken(address prc20);

    string internal constant EXPECTED_NAMESPACE = "eip155:11155111";

    function run() external view {
        address prc20 = AddressBook.donut("PRC20_USDC");
        address core = AddressBook.donut("UniversalCore");
        address sepoliaUSDC = AddressBook.sepolia("USDC");

        DemoLog.header("SETUP", "Token pair");

        string memory prcSymbol = IERC20Metadata(prc20).symbol();
        uint8 prcDecimals = IERC20Metadata(prc20).decimals();

        DemoLog.addr("PRC20", prc20, true);
        DemoLog.kv("  symbol", prcSymbol);
        DemoLog.kv("  decimals", vm.toString(prcDecimals));

        // The Sepolia side is read from the address book only — this script runs against Donut, so
        // its symbol and decimals cannot be read here. Preflight checks that side on its own fork.
        DemoLog.addr("Sepolia USDC", sepoliaUSDC, false);

        DemoLog.blank();

        // A deprecated token still answers every call it is asked. Reject it by name.
        if (_endsWithOld(prcSymbol)) revert DeprecatedToken(prcSymbol);
        DemoLog.ok("not deprecated", "symbol does not end in .old");

        (address gasToken,, uint256 protocolFee,, string memory namespace,) =
            IUniversalCore(core).getOutboundTxGasAndFees(prc20, 0);

        if (gasToken == address(0)) revert UnregisteredToken(prc20);
        DemoLog.ok("registered", "UniversalCore quotes this token");

        if (keccak256(bytes(namespace)) != keccak256(bytes(EXPECTED_NAMESPACE))) {
            revert WrongDestinationChain(namespace, EXPECTED_NAMESPACE);
        }
        DemoLog.ok("destination", string.concat("resolves to ", namespace));

        DemoLog.blank();
        DemoLog.note("The destination chain is not a parameter anywhere in this flow.");
        DemoLog.note("Pinning this token is what pins the destination to Sepolia.");

        if (protocolFee == 0) {
            DemoLog.blank();
            DemoLog.note("protocolFee is currently 0. Read every run, never assumed:");
            DemoLog.note("Push core can switch it on, and the mandate's PC cap is set at grant.");
        }

        DemoLog.footer();
    }

    /// @dev True when `s` ends in ".old". Byte comparison; symbols are ASCII.
    function _endsWithOld(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        if (b.length < 4) return false;
        uint256 n = b.length;
        return b[n - 4] == "." && b[n - 3] == "o" && b[n - 2] == "l" && b[n - 1] == "d";
    }
}
