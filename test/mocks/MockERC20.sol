// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title  MockERC20 — TEST AND DEMO ONLY. NEVER DEPLOY TO MAINNET.
 * @notice A minimal, 6-decimal, openly-mintable ERC20. It exists so the native-door tests have a
 *         token to meter, nothing more.
 *
 * @dev    AUTHORED RATHER THAN ADOPTED, deliberately. OpenZeppelin ships `ERC20Mock`, but it is
 *         18-decimal and carries the full ERC20 implementation; §7.4 asks for a 6-decimal token with
 *         an open `mint`, because the worked configs meter amounts in 6-decimal units and a decimals
 *         mismatch would make every cap in those examples wrong by 10^12.
 *
 *         OBSERVER, NEVER ORACLE: this supplies no behaviour to the code under test. URP never calls
 *         it — the policy reads the AMOUNT ARGUMENT out of calldata and never touches the token — so
 *         nothing here can make a dead branch look live.
 */
contract MockERC20 {
    string public constant name = "Mock USD";
    string public constant symbol = "mUSD";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();

    /// @dev Open by design; this is a test token.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
