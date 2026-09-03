// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalOutboundTxRequest } from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  MockUniversalGateway
 * @notice OBSERVER, NEVER ORACLE. It records the exact bytes it was called with and nothing else.
 *
 * @dev    It supplies NO behaviour the code under test depends on: it does not validate the
 *         request, does not decide whether a request is legal, and returns nothing. Every judgement
 *         about whether a request should have been sent belongs to UCEP and the wallet, upstream.
 *         That separation is the point — this repo's one shipped critical bug survived review
 *         because a mock supplied the behaviour under test.
 *
 * @dev     WHAT IT RECORDS, and why the raw bytes matter: the wallet must dispatch THE EXACT
 *          VALIDATED BYTES. Recording the full calldata (not a decoded struct) is what lets E2E
 *          assert byte equality against what the agent signed. A decoded mirror would re-encode and
 *          could hide a divergence.
 *
 * @dev     `msg.sender` is recorded because it is what decides which destination account executes
 *          on the far chain. If the wallet ever stopped being the caller, every CEA derivation
 *          would move — so it is asserted, not assumed.
 */
contract MockUniversalGateway {
    /// @dev Set true to make every call revert, for the failure-atomicity paths (W-18 / U-18).
    bool public shouldRevert;

    error GatewayRejected();

    struct Received {
        address sender;
        uint256 value;
        bytes rawCalldata;
    }

    Received[] internal _received;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function callCount() external view returns (uint256) {
        return _received.length;
    }

    function lastCall() external view returns (Received memory) {
        return _received[_received.length - 1];
    }

    function callAt(uint256 i) external view returns (Received memory) {
        return _received[i];
    }

    /// @dev The real signature, so the wallet's dispatch reaches a matching function rather than a
    ///      fallback — a fallback would still "work" and would hide a selector mistake.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata) external payable {
        if (shouldRevert) revert GatewayRejected();
        _received.push(Received({ sender: msg.sender, value: msg.value, rawCalldata: msg.data }));
    }

    receive() external payable { }
}

/**
 * @title  MockPRC20
 * @notice A minimal transferable token, standing in for pUSDC.
 * @dev    Deliberately not a full ERC-20: it implements exactly what the flow exercises. `burn` is
 *         what the gateway would do on a real outbound — here the E2E test calls it explicitly so
 *         the fund ledger is observable at each stage.
 */
contract MockPRC20 {
    string public constant name = "Push USDC";
    string public constant symbol = "pUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
