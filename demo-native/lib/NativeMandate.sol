// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";

import { IURP } from "../../src/interfaces/IURP.sol";
import { MandateType } from "../../src/libraries/PushWalletTypes.sol";

import { AddressBook } from "./AddressBook.sol";
import { Amounts } from "./Amounts.sol";

/**
 * @title  NativeMandate
 * @notice Builds the `Session` and `NativeConfig` a Push-native mandate is granted with.
 *
 * @dev    DECLARED ONCE BECAUSE FOUR SCRIPTS GRANT MANDATES — the stake mandate, the unstake
 *         mandate, and Act 4f's unpinned/pinned `approve` pair. If each assembled its own shape,
 *         4f's two halves could differ in some way other than the pin, and the act would prove
 *         nothing.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantMandate` refuses anything
 *         but the canonical shape: 1..8 actions for NATIVE, the canonical validator, exactly one
 *         action policy per action which must be the deployed URP, no user-op policies, no
 *         ERC-7739 policies, and `permitERC4337Paymaster` false. The salt passed here is discarded
 *         — the wallet overwrites it with its own monotonic grant counter, so every grant yields a
 *         permission id that never recurs.
 *
 *         THE MODE WRAPPER IS NOT OPTIONAL. URP's `initData` is `abi.encode(uint8 mode, bytes body)`.
 *         A v2-style bare `abi.encode(Config)` does not mis-decode into something wrong — it
 *         REVERTS, unnamed, on an uninitialised config. That is deliberate upstream, and it is why
 *         `_initData` below exists rather than each caller encoding by hand.
 *
 *         THE PIN IS THE PRODUCT. `pins[0]` fixes the beneficiary word of `stakeFor` to the wallet
 *         itself. Without it the agent could stake the user's money naming ITSELF as beneficiary
 *         and then call `unstake()` directly from its own EOA — under no mandate at all — and walk
 *         away with principal plus reward. See `_stakeConfig`.
 */
library NativeMandate {
    /// @dev Mandate lifetime. Long enough to rehearse, short enough that expiry is real.
    uint48 internal constant VALIDITY = 7 days;

    /**
     * @dev `stakeFor(address beneficiary, uint256 amount)` — ABSOLUTE calldata offsets, SELECTOR
     *      INCLUDED. 4 is the first argument word, 36 the second.
     *
     *        bytes  0.. 3  selector
     *        bytes  4..35  beneficiary   <- ArgPin.offset   (gate N7)
     *        bytes 36..67  amount        <- AmountRule.offset (gate N8)
     *
     *      Getting either wrong by four fails CLOSED — `ArgPinMismatch` or a wrong metered amount —
     *      which is safe but wastes an act.
     */
    uint16 internal constant BENEFICIARY_OFFSET = 4;
    uint16 internal constant AMOUNT_OFFSET = 36;

    /// @dev `approve(address spender, uint256 amount)` — the spender is also the first word.
    uint16 internal constant SPENDER_OFFSET = 4;

    // ──────────────────────────────── sessions ────────────────────────────────

    /**
     * @notice The stake mandate: one action, `stakeFor` on `StakeDummy`, beneficiary pinned.
     * @param  agent  The agent key the mandate authorises.
     * @param  wallet The wallet that is both caller and pinned beneficiary.
     */
    function stakeSession(address agent, address wallet, address stakeDummy, bytes4 selector)
        internal
        view
        returns (Session memory)
    {
        return _session(agent, stakeDummy, selector, _initData(_stakeConfig(wallet, stakeDummy, selector)));
    }

    /**
     * @notice The unstake mandate: one action, `unstake()` on `StakeDummy`, NO pins.
     *
     * @dev    NO PIN IS CORRECT HERE, NOT AN OVERSIGHT. `unstake()` takes no arguments and credits
     *         `msg.sender`, which is the wallet — there is no argument to redirect. Do not "fix"
     *         this by adding one; a pin on a zero-argument call can never match and the mandate
     *         would authorise nothing.
     */
    function unstakeSession(address agent, address stakeDummy, bytes4 selector) internal view returns (Session memory) {
        return _session(agent, stakeDummy, selector, _initData(_unstakeConfig(stakeDummy, selector)));
    }

    /**
     * @notice Act 4f's `approve` mandate on `DemoUSDC`, with the spender pinned or not.
     *
     * @dev    THE ONLY PLACE IN THIS DEMO WHERE THE ACTION TARGET IS NOT `StakeDummy`. It is
     *         `DemoUSDC`, so `NativeIds.configId` must be derived with that target — deriving it
     *         against `StakeDummy` out of habit yields an id addressing an empty slot.
     *
     * @param  pinnedSpender The spender to pin, or `address(0)` for the deliberately unpinned
     *                       mandate that Act 4f exists to expose.
     */
    function approveSession(address agent, address token, bytes4 selector, address pinnedSpender)
        internal
        view
        returns (Session memory)
    {
        return _session(agent, token, selector, _initData(_approveConfig(token, selector, pinnedSpender)));
    }

    // ──────────────────────────────── configs ────────────────────────────────

    /**
     * @notice The stake rulebook. Every field is a gate; see the inline map.
     *
     * @dev    `maxValuePerCall` and `maxValueTotal` are ZERO, deliberately. Native actions in this
     *         demo carry no value, and zero is the honest ceiling — it is also what makes G5 a real
     *         refusal (`ValueExceedsCap(1, 0)`) rather than a contrived one. Do not set them
     *         non-zero "just in case".
     */
    function _stakeConfig(address wallet, address stakeDummy, bytes4 selector)
        private
        view
        returns (IURP.NativeConfig memory cfg)
    {
        IURP.ArgPin[] memory pins = new IURP.ArgPin[](1);
        // THE BENEFICIARY PIN. Full-word equality: an address is left-padded by the ABI, and URP
        // compares all 32 bytes on purpose — a non-zero high half is a MISMATCH, which also proves
        // the padding is clean. Masking would silently accept a dirty word.
        pins[0] = IURP.ArgPin({ offset: BENEFICIARY_OFFSET, expected: bytes32(uint256(uint160(wallet))) });

        cfg = IURP.NativeConfig({
            initialized: false, // forced true by URP
            validUntil: uint48(block.timestamp) + VALIDITY, // N2
            target: stakeDummy, // N4
            selector: selector, // N5
            maxValuePerCall: 0, // N6 — see the note above
            maxValueTotal: 0, // N6
            valueSpent: 0,
            amount: IURP.AmountRule({
                enabled: true, // N8 — the metering that makes the budget real
                offset: AMOUNT_OFFSET,
                maxPerCall: Amounts.PER_CALL,
                maxTotal: Amounts.TOTAL
            }),
            amountSpent: 0,
            maxCalls: Amounts.MAX_CALLS, // N9
            callsUsed: 0,
            pins: pins // N7
        });
    }

    /// @dev The unstake rulebook: nothing to meter, nothing to pin, one call.
    function _unstakeConfig(address stakeDummy, bytes4 selector) private view returns (IURP.NativeConfig memory cfg) {
        // HOISTED, NOT INLINED. Both of these as struct literals inside the outer one push the
        // via_ir stack past its limit in the calling script — measured, not guessed.
        IURP.ArgPin[] memory noPins = new IURP.ArgPin[](0);
        // `unstake()` carries no amount argument, so there is nothing at any offset to meter.
        IURP.AmountRule memory noAmount = IURP.AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });

        cfg.initialized = false;
        cfg.validUntil = uint48(block.timestamp) + VALIDITY;
        cfg.target = stakeDummy;
        cfg.selector = selector;
        cfg.maxValuePerCall = 0;
        cfg.maxValueTotal = 0;
        cfg.valueSpent = 0;
        cfg.amount = noAmount;
        cfg.amountSpent = 0;
        cfg.maxCalls = Amounts.UNSTAKE_MAX_CALLS; // ONE — and this is what G8 fires on
        cfg.callsUsed = 0;
        cfg.pins = noPins; // none, and that is correct — see `unstakeSession`
    }

    /**
     * @dev Act 4f's `approve` rulebook.
     *
     *      THE TWO HALVES DIFFER IN EXACTLY ONE FIELD — `pins`. Everything else is identical, which
     *      is the entire point of the act: the contract cannot tell a good mandate from a bad one,
     *      because a mandate without a pin is a perfectly valid mandate that simply permits more.
     */
    function _approveConfig(address token, bytes4 selector, address pinnedSpender)
        private
        view
        returns (IURP.NativeConfig memory cfg)
    {
        IURP.ArgPin[] memory pins;
        if (pinnedSpender == address(0)) {
            pins = new IURP.ArgPin[](0); // <- THE HOLE
        } else {
            pins = new IURP.ArgPin[](1);
            pins[0] = IURP.ArgPin({ offset: SPENDER_OFFSET, expected: bytes32(uint256(uint160(pinnedSpender))) });
        }

        // FIELD-BY-FIELD, for the same via_ir stack reason as `_unstakeConfig`.
        // The allowance amount is not metered: 4f is about the SPENDER argument, and metering the
        // amount would give the act a second reason to refuse, muddying which gate fired.
        IURP.AmountRule memory noAmount = IURP.AmountRule({ enabled: false, offset: 0, maxPerCall: 0, maxTotal: 0 });

        cfg.initialized = false;
        cfg.validUntil = uint48(block.timestamp) + VALIDITY;
        cfg.target = token;
        cfg.selector = selector;
        cfg.maxValuePerCall = 0;
        cfg.maxValueTotal = 0;
        cfg.valueSpent = 0;
        cfg.amount = noAmount;
        cfg.amountSpent = 0;
        cfg.maxCalls = 0; // unlimited — the act needs two calls on the unpinned half
        cfg.callsUsed = 0;
        cfg.pins = pins;
    }

    // ──────────────────────────────── internals ────────────────────────────────

    /**
     * @dev The canonical one-action native session. Every field is checked by `grantMandate`.
     */
    function _session(address agent, address target, bytes4 selector, bytes memory initData)
        private
        view
        returns (Session memory)
    {
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({ policy: AddressBook.ours("urp"), initData: initData });

        ActionData[] memory actions = new ActionData[](1);
        // SELECTOR BEFORE TARGET — that is the declaration order in `smartsessions/DataTypes.sol`.
        // Reversed, this compiles and fails confusingly.
        actions[0] =
            ActionData({ actionTargetSelector: selector, actionTarget: target, actionPolicies: actionPolicies });

        return Session({
            sessionValidator: ISessionValidator(AddressBook.ours("sessionValidator")),
            // Scheme 0 = ECDSA; the key is 20 RAW bytes, never padded. This blob is an input to the
            // permission id, so a 32-byte-padded key yields a DIFFERENT, valid-looking permission
            // that the validator then rejects at signature time.
            sessionValidatorInitData: abi.encode(uint8(0), abi.encodePacked(agent)),
            salt: bytes32(0), // discarded; the wallet substitutes its own grant counter
            userOpPolicies: new PolicyData[](0),
            erc7739Policies: ERC7739Data({
                allowedERC7739Content: new ERC7739Context[](0), erc1271Policies: new PolicyData[](0)
            }),
            actions: actions,
            permitERC4337Paymaster: false
        });
    }

    /// @dev The mode wrapper. See the contract notes — this is not optional and not cosmetic.
    function _initData(IURP.NativeConfig memory cfg) private pure returns (bytes memory) {
        return abi.encode(uint8(MandateType.NATIVE), abi.encode(cfg));
    }
}
