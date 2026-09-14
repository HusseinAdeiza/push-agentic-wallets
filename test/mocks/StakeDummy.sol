// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/**
 * @title  StakeDummy — TEST AND DEMO ONLY. NEVER DEPLOY TO MAINNET.
 * @notice The Push-native protocol the native-door tests point a mandate at. It is the TEST TARGET,
 *         not a product: no owner, no pause, no reward pool, no access control of any kind.
 *
 * @dev    ITS SHAPE IS THE POINT. Each function exercises one native gate combination:
 *
 *         - `stakeFor(address,uint256)` — an `ArgPin` on the beneficiary at offset 4 AND an
 *           `AmountRule` on the amount at offset 36. The pinned-beneficiary case.
 *         - `depositFor(address) payable` — an `ArgPin` at offset 4 plus the NATIVE VALUE caps.
 *           Pins and value metering together, with no amount rule.
 *         - `unstake()` — four bytes of selector and no arguments. NOT the value-only shape: it
 *           still carries a selector, so it binds to a normal selector action. This is the
 *           distinction that makes `VALUE_SELECTOR` mean *empty calldata* and nothing else.
 *         - `claim()` — the ascetic shape: no value cap, no amount rule, no pins, `maxCalls == 0`.
 *         - `receive()` — the TRUE value-only path: empty calldata, so the engine derives
 *           `VALUE_SELECTOR` and URP matches a `0xFFFFFFFF` config.
 *
 *         OBSERVER, NEVER ORACLE. It records what it was sent and reverts on nonsense, but it
 *         supplies nothing to the code under test: URP validates BEFORE this contract is ever
 *         reached, reading arguments out of calldata rather than asking anyone. A test that used
 *         this contract's state to decide whether a gate fired would be the oracle mistake.
 */
contract StakeDummy {
    MockERC20 public immutable token;

    /// @dev Token units staked per beneficiary.
    mapping(address => uint256) public totalBalance;

    /// @dev Native PC deposited per beneficiary.
    mapping(address => uint256) public pcBalance;

    event Staked(address indexed beneficiary, uint256 amount);
    event Deposited(address indexed beneficiary, uint256 value);
    event Unstaked(address indexed account, uint256 amount);
    event Claimed(address indexed account);

    error ZeroBeneficiary();
    error ZeroAmount();
    error ZeroValue();
    error NothingStaked();
    error TransferFailed();

    constructor(MockERC20 token_) {
        token = token_;
    }

    /// @dev Beneficiary word at offset 4, amount word at offset 36 — the two offsets the worked
    ///      configs pin. Non-payable.
    function stakeFor(address beneficiary, uint256 amount) external {
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (amount == 0) revert ZeroAmount();

        token.transferFrom(msg.sender, address(this), amount);
        totalBalance[beneficiary] += amount;

        emit Staked(beneficiary, amount);
    }

    /// @dev Payable, one address argument at offset 4. Exercises value caps beside a pin.
    function depositFor(address beneficiary) external payable {
        if (beneficiary == address(0)) revert ZeroBeneficiary();
        if (msg.value == 0) revert ZeroValue();

        pcBalance[beneficiary] += msg.value;

        emit Deposited(beneficiary, msg.value);
    }

    /// @dev No arguments, but STILL FOUR BYTES of selector — a normal selector action.
    function unstake() external {
        uint256 amount = totalBalance[msg.sender];
        if (amount == 0) revert NothingStaked();

        // Effects before the interaction, as the real thing would.
        totalBalance[msg.sender] = 0;
        token.transfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @dev The ascetic shape: no value, no arguments, no state beyond an event.
    function claim() external {
        emit Claimed(msg.sender);
    }

    /// @dev THE TRUE VALUE-ONLY PATH — empty calldata, so the engine derives `VALUE_SELECTOR` and a
    ///      `0xFFFFFFFF` native config matches. A no-argument function cannot reach this branch.
    receive() external payable {
        pcBalance[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }
}
