// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { Session, PermissionId } from "smartsessions/DataTypes.sol";
import { IdLib } from "smartsessions/lib/IdLib.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";

/// @notice Phase 0 smoke suite. Proves the harness itself is sound before any contract uses it.
contract BaseSmokeTest is BaseTest {
    function test_engineDeploys() public view {
        assertGt(address(engine).code.length, 0, "engine has code");
        assertTrue(engine.isModuleType(1), "engine is a validator module");
    }

    function test_validatorDeploys() public view {
        assertTrue(validator.isModuleType(7), "validator is a stateless validator module");
        assertEq(validator.USV(), USV, "harness USV matches the validator's constant");
    }

    /// Pins the selector every PRD hashes by hand against the interface the wallet will call.
    function test_sendOutboundSelectorMatchesInterface() public pure {
        assertEq(
            SEND_OUTBOUND_SELECTOR,
            IUniversalGatewayPC.sendUniversalTxOutbound.selector,
            "hand-hashed selector == interface selector"
        );
    }

    /// U-21 pulled forward: the constant is declared here, so it is pinned here.
    /// THIS TEST EXISTS TO FAIL. If a field is added to UniversalOutboundTxRequest it breaks
    /// immediately, instead of silently loosening URP's gate 4c into a check that passes everything.
    function test_minBodyLenMatchesStruct() public pure {
        assertEq(abi.encode(emptyOutboundRequest()).length, MIN_OUTBOUND_BODY_LEN, "352 pin");
    }

    /// Proves the harness's session matches the engine's id derivation — including the
    /// abi.encode (NOT encodePacked) choice at IdLib.sol:79.
    function test_canonicalSessionDerivesPermissionId() public view {
        bytes memory initData = ecdsaConfig(AGENT);
        Session memory s = canonicalSession(initData, hex"");

        bytes32 fromEngine = PermissionId.unwrap(IdLib.toPermissionIdMemory(s));
        bytes32 byHand = keccak256(abi.encode(address(validator), initData, bytes32(0)));

        assertEq(fromEngine, byHand, "harness session id == engine derivation");
    }

    /// The observer must survive a STATICCALL — that is how the validator reaches USV.
    /// Which method was called is proven by vm.expectCall, at the assertion site.
    function test_usvObserverAnswersStaticcallAndRecordsViaExpectCall() public {
        etchUSVObserver();
        bytes memory expected = abi.encodeWithSignature("verifyEd25519RawMessage(bytes,bytes,bytes)", "", "", "");

        expectUSVCall(expected);
        (bool ok, bytes memory ret) = USV.staticcall(expected);

        assertTrue(ok, "observer answers a staticcall");
        assertTrue(abi.decode(ret, (bool)), "observer returns its fixed value");

        stripUSV();
        assertEq(USV.code.length, 0, "USV stripped");
    }

    /// Both branches of the recorder shown, which is the whole point of replacing
    /// `vm.expectCall(target, "", 0)`: a cheatcode-level expectation failure is not catchable,
    /// so that helper's negative branch could never be demonstrated.
    ///
    /// DEVIATION from the ruling's specified shape, verified by probe: a STATICCALL against a
    /// storage-writing recorder REVERTS (it cannot SSTORE) and therefore cannot increment to 2.
    /// Asserting the revert is the honest form — and it is still informative for W-28, because a
    /// caller that staticcalls the recorder has demonstrably reached it.
    function test_callRecorder_semantics() public {
        address probe = makeAddr("recorderProbe");
        etchCallRecorder(probe);

        assertEq(callsRecorded(probe), 0, "starts at zero");
        assertNoCallsTo(probe); // positive branch: passes when silent

        (bool okCall,) = probe.call(hex"11223344");
        assertTrue(okCall, "plain call succeeds");
        assertEq(callsRecorded(probe), 1, "negative branch: counter moved");

        (bool okStatic,) = probe.staticcall(hex"55667788");
        assertFalse(okStatic, "staticcall reverts against a storage-writing recorder");
        assertEq(callsRecorded(probe), 1, "and therefore does not increment");

        (bool okValue,) = probe.call{ value: 0 }("");
        assertTrue(okValue, "receive() path also counts");
        assertEq(callsRecorded(probe), 2, "empty calldata routed to receive");
    }

    function test_ecdsaConfigShape() public view {
        (uint8 scheme0, bytes memory key0) = abi.decode(ecdsaConfig(AGENT), (uint8, bytes));
        assertEq(scheme0, 0, "ecdsa scheme byte");
        assertEq(key0.length, 20, "ecdsa key length");

        (uint8 scheme1, bytes memory key1) = abi.decode(ed25519Config(keccak256("pk")), (uint8, bytes));
        assertEq(scheme1, 1, "ed25519 scheme byte");
        assertEq(key1.length, 32, "ed25519 key length");
    }
}
