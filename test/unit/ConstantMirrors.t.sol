// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";
import { ActionId } from "smartsessions/DataTypes.sol";
import {
    FALLBACK_TARGET_FLAG,
    FALLBACK_TARGET_SELECTOR_FLAG,
    FALLBACK_TARGET_SELECTOR_FLAG_PERMITTED_TO_CALL_SMARTSESSION
} from "smartsessions/DataTypes.sol";

import {
    MandateType,
    VALUE_SELECTOR,
    ENGINE_FALLBACK_TARGET,
    ENGINE_FALLBACK_SELECTOR,
    ENGINE_FALLBACK_SELECTOR_SMARTSESSION
} from "../../src/libraries/PushWalletTypes.sol";

/**
 * @title  ConstantMirrors — Phase 1's gate.
 * @notice `PushWalletTypes` mirrors four engine constants that cannot be imported into production
 *         code: `IdLib.VALUE_SELECTOR` is `internal` to a library, and the three fallback flags are
 *         file-level constants in the vendored fork that the wallet would otherwise have to reach
 *         through a dependency it does not want.
 *
 * @dev    THE POINT OF THIS SUITE. A mirror is a hand-copied value, and a hand-copied value stays
 *         correct only until the thing it copies moves. These tests fail the build in that case
 *         rather than letting the wallet silently permit an action it means to forbid — a wrong
 *         `ENGINE_FALLBACK_TARGET` would make `_requireGrantableTarget` compare against the wrong
 *         address and wave the wildcard action straight through.
 *
 *         THE THREE FALLBACK FLAGS ARE ASSERTED AGAINST THE UPSTREAM SYMBOLS, NOT AGAINST LITERALS.
 *         Asserting `ENGINE_FALLBACK_TARGET == address(1)` would be a test that agrees with the
 *         source by construction and proves nothing about the fork. Importing the upstream constant
 *         and comparing is what makes this a mirror test — if the fork changes the value, this
 *         breaks.
 *
 *         `VALUE_SELECTOR` CANNOT BE IMPORTED — `IdLib.sol:7` declares it `internal`. It is
 *         therefore pinned BEHAVIOURALLY, through `IdLib.toActionId`, which is the only way to
 *         observe the value the engine actually uses. That is stronger than a literal comparison
 *         anyway: it pins the value AND the rule that produces it.
 */
contract ConstantMirrorsTest is BaseTest {
    using IdLib for address;

    /// The wildcard target. The wallet is the ONLY grant-time layer that refuses this value — the
    /// engine lets it through `enableSessions` and only rejects it at check time
    /// (`PolicyLib.sol:200`) — so a drifted mirror here is a real hole, not a redundant one.
    function test_mirror_engineFallbackTarget() public pure {
        assertEq(ENGINE_FALLBACK_TARGET, FALLBACK_TARGET_FLAG, "ENGINE_FALLBACK_TARGET drifted from the fork");
    }

    /// The wildcard selector.
    function test_mirror_engineFallbackSelector() public pure {
        assertEq(
            ENGINE_FALLBACK_SELECTOR, FALLBACK_TARGET_SELECTOR_FLAG, "ENGINE_FALLBACK_SELECTOR drifted from the fork"
        );
    }

    /// The sentinel that routes a request to the engine itself. An agent reaching this could
    /// configure sessions, so this is the most severe of the three.
    function test_mirror_engineFallbackSelectorSmartSession() public pure {
        assertEq(
            ENGINE_FALLBACK_SELECTOR_SMARTSESSION,
            FALLBACK_TARGET_SELECTOR_FLAG_PERMITTED_TO_CALL_SMARTSESSION,
            "ENGINE_FALLBACK_SELECTOR_SMARTSESSION drifted from the fork"
        );
    }

    /**
     * `VALUE_SELECTOR` pinned through observable engine behaviour rather than a literal.
     *
     * `IdLib.toActionId(target, callData)` returns `toActionId(target, VALUE_SELECTOR)` whenever
     * calldata is under four bytes (`IdLib.sol:13-15`). So if the action id the engine derives for
     * EMPTY calldata equals the id it derives for our mirrored selector, the mirror is the value the
     * engine uses. If upstream changed `VALUE_SELECTOR`, these two ids diverge and this fails.
     */
    function test_mirror_valueSelector_isWhatTheEngineUsesForShortCalldata() public view {
        address target = address(0xBEEF);

        // Through `this.` so the blob arrives as `bytes calldata` — `IdLib.toActionId(address,bytes)`
        // takes calldata, which is exactly how the engine calls it in `checkSingle7579Exec`.
        bytes32 idFromEmptyCalldata = this.actionIdFor(target, bytes(""));
        bytes32 idFromMirroredSelector = ActionId.unwrap(target.toActionId(VALUE_SELECTOR));

        assertEq(idFromEmptyCalldata, idFromMirroredSelector, "VALUE_SELECTOR is not the engine's short-calldata id");
    }

    /**
     * @dev External so `callData` is `bytes calldata`, matching `IdLib.toActionId`'s signature and
     *      the engine's own call site. Not a mock: it calls the real upstream library.
     *
     *      CALLED AS `IdLib.toActionId(...)`, NOT THROUGH `using IdLib for address`. With a 4-byte
     *      blob the bound form resolves to this contract's own function rather than the library's
     *      `bytes4` overload and recurses until StackOverflow — measured, not theorised. The
     *      qualified call is unambiguous.
     */
    function actionIdFor(address target, bytes calldata callData) external pure returns (bytes32) {
        return ActionId.unwrap(IdLib.toActionId(target, callData));
    }

    /**
     * The boundary the mirror rides on: UNDER four bytes is value-only, four bytes is a real
     * selector. This is what makes `unstake()` a normal selector action rather than a value-only
     * one — it carries its own four bytes. Getting it wrong would mean a native config for
     * `unstake()` written with `selector: 0xFFFFFFFF`, which could never match.
     *
     * ⚠️ ASSERTED THROUGH THE `bytes4` OVERLOAD, WHICH IS THE ONE THE ENGINE ACTUALLY USES.
     * Every engine call site extracts the selector itself and calls `toActionId(address,bytes4)` —
     * `SmartSession.sol:319`, `ConfigLib.sol:133`, `PolicyLib.sol:215,405`. The `bytes` overload is
     * never reached in production, which is fortunate: `IdLib.sol:14` recurses into ITSELF, because
     * `callData[:4]` is a `bytes calldata` slice rather than a `bytes4`, so the `else` branch calls
     * the same overload forever and any 4-byte input StackOverflows. Measured, not theorised — an
     * earlier draft of this test called it and blew the stack.
     *
     * That upstream defect is REPORTED, NOT WORKED AROUND, and it is genuinely inert here: the
     * wallet never calls `toActionId`, and the engine never reaches the broken branch. Asserting
     * against the live overload is also the more honest mirror — it pins the value the engine reads.
     */
    function test_mirror_valueSelector_boundaryIsFourBytes() public view {
        address target = address(0xBEEF);
        bytes32 valueOnlyId = ActionId.unwrap(target.toActionId(VALUE_SELECTOR));

        // Under four bytes: the engine's own short-calldata rule maps to the value-only id. This
        // arm goes through the `bytes` overload deliberately — with <4 bytes it returns on
        // IdLib.sol:13 and never reaches the recursive branch.
        assertEq(
            this.actionIdFor(target, hex"aabbcc"),
            valueOnlyId,
            "three bytes of calldata must map to the value-only action id"
        );
        assertEq(this.actionIdFor(target, bytes("")), valueOnlyId, "empty calldata is the value-only action id");

        // A real four-byte selector is a DIFFERENT action id — the id an `unstake()` config binds to.
        assertTrue(
            ActionId.unwrap(target.toActionId(bytes4(hex"aabbccdd"))) != valueOnlyId,
            "a four-byte selector is a selector action, never value-only"
        );
    }

    /**
     * `MandateType`'s zero value is `UNIVERSAL`.
     *
     * This is why URP's `ModeSlot` carries an explicit `initialized` flag: an empty storage slot
     * decodes as `UNIVERSAL`, so the mode alone can never distinguish "universal mandate" from
     * "no mandate here". Decision 17 rests on this fact; the test states it so a future reordering
     * of the enum fails loudly instead of silently routing empty slots to the wrong rulebook.
     */
    function test_mandateTypeZeroValueIsUniversal() public pure {
        assertEq(uint8(MandateType.UNIVERSAL), 0, "UNIVERSAL must be the zero value");
        assertEq(uint8(MandateType.NATIVE), 1, "NATIVE must be 1");
    }
}
