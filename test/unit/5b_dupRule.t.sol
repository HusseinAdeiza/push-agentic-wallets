// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

import { BaseTest } from "../Base.t.sol";
import { ConfigId } from "smartsessions/DataTypes.sol";
import { AllowedCall, AssetCapState, Config, Multicall } from "../../src/libraries/Types.sol";
import { MockPRC20 } from "../mocks/MockUniversalGateway.sol";
import { VALIDATION_SUCCESS } from "erc7579/interfaces/IERC7579Module.sol";

/// @notice `_initUniversal` allow-list ambiguity — the EVM counterpart of the SVM rulebook's
///         existing `AmbiguousRule` guard.
///
/// @dev `_requireAllowed` is first-match, so two rules on the SAME (target, selector) pair make
///      the later one dead: its beneficiary pin and value cap never run. An owner who appends a
///      rule to TIGHTEN an existing one gets the older, LOOSER rule in force instead, silently.
///      That is fail-OPEN, which is why it is refused at grant rather than documented.
contract URPAllowedCallAmbiguityTest is BaseTest {
    address internal PROTOCOL;
    address internal PROTOCOL_B;
    address internal CEA;
    address internal ACCOUNT;
    address internal ASSET;

    bytes4 internal constant SWAP_SELECTOR = bytes4(keccak256("swap(uint256,address)"));
    bytes4 internal constant POKE_SELECTOR = bytes4(keccak256("poke()"));
    uint16 internal constant BENEFICIARY_OFFSET = 36;
    uint48 internal constant VALID_UNTIL = 2_000_000_000;
    ConfigId internal constant CID = ConfigId.wrap(bytes32(uint256(0xD00D)));

    function setUp() public override {
        super.setUp();
        PROTOCOL = makeAddr("farChainProtocol");
        PROTOCOL_B = makeAddr("otherProtocol");
        CEA = makeAddr("destinationAccount");
        ACCOUNT = makeAddr("agentWallet");
        ASSET = address(new MockPRC20());
        vm.warp(1_000_000_000);
    }

    function _cfgWith(AllowedCall[] memory rules) internal view returns (Config memory) {
        return Config({
            initialized: false,
            validUntil: VALID_UNTIL,
            expectedCEA: CEA,
            assets: oneAsset(ASSET, 100 ether, 1000 ether),
            maxGasPerCall: 5 ether,
            allowedCalls: rules
        });
    }

    /// @dev The loose rule an owner writes first: no beneficiary pin, unbounded value.
    function _loose() internal view returns (AllowedCall memory) {
        return AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: type(uint256).max
        });
    }

    /// @dev The tightening rule they append: pin the beneficiary, cap the value.
    function _tight() internal view returns (AllowedCall memory) {
        return AllowedCall({
            target: PROTOCOL,
            selector: SWAP_SELECTOR,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 1 ether
        });
    }

    /// @dev THE FIX: the ambiguous pair is refused at grant, naming both indices.
    function test_ambiguousPairRefusedAtInit() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _loose();
        rules[1] = _tight();

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousAllowedCall.selector, uint256(0), uint256(1))
        );
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
    }

    /// @dev Reversed order is refused too. A scan that only compared forward would let this pass.
    function test_ambiguousPairRefusedRegardlessOfOrder() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _tight();
        rules[1] = _loose();

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousAllowedCall.selector, uint256(0), uint256(1))
        );
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
    }

    /// @dev The refusal names the pair that actually collided, not the first two entries.
    function test_errorNamesTheCollidingIndices() public {
        AllowedCall[] memory rules = new AllowedCall[](3);
        rules[0] = _loose();
        AllowedCall memory other = _loose();
        other.target = PROTOCOL_B;
        other.selector = POKE_SELECTOR;
        rules[1] = other;
        rules[2] = _tight(); // collides with rules[0], not rules[1]

        vm.prank(address(engine));
        vm.expectRevert(
            abi.encodeWithSelector(UniversalRulesPolicyErrors.AmbiguousAllowedCall.selector, uint256(0), uint256(2))
        );
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
    }

    /// @dev CONTROL 1 — two rules differing only in SELECTOR match different requests: both live.
    function test_distinctSelectorsOnOneTargetAccepted() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _loose();
        rules[1] = _tight();
        rules[1].selector = POKE_SELECTOR;

        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
        assertEq(urp.getConfig(CID, ACCOUNT).allowedCalls.length, 2, "both rules stored");
    }

    /// @dev CONTROL 2 — two rules differing only in TARGET likewise both stay reachable.
    function test_distinctTargetsOnOneSelectorAccepted() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _loose();
        rules[1] = _tight();
        rules[1].target = PROTOCOL_B;

        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
        assertEq(urp.getConfig(CID, ACCOUNT).allowedCalls.length, 2, "both rules stored");
    }

    /// @dev CONTROL 3 — a pair equal in BOTH target and selector is what first-match cannot
    ///      distinguish, and it is the only thing the guard refuses. A rule that differs in
    ///      either component matches a different request, so both stay reachable.
    function test_ambiguityNeedsBothTargetAndSelectorToMatch() public {
        AllowedCall[] memory rules = new AllowedCall[](2);
        rules[0] = _loose();
        rules[1] = _tight();
        rules[1].target = PROTOCOL_B;
        rules[1].selector = POKE_SELECTOR;
        rules[1].maxValue = 0;
        rules[1].hasBeneficiary = false;

        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));
        assertEq(urp.getConfig(CID, ACCOUNT).allowedCalls.length, 2, "both rules stored");
    }

    /// @dev CONTROL 4 — the single tight rule still refuses BOTH violations it was written to
    ///      refuse. Proves the ambiguity is what the pair test exercises, not the harness.
    function test_singleTightRuleStillRefusesBothViolations() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = _tight();
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));

        Multicall[] memory stranger = new Multicall[](1);
        stranger[0] = Multicall({
            to: PROTOCOL,
            value: 2 ether,
            data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), makeAddr("stranger"))
        });
        vm.prank(address(engine));
        vm.expectRevert();
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, stranger));

        Multicall[] memory overCap = new Multicall[](1);
        overCap[0] = Multicall({
            to: PROTOCOL,
            value: 2 ether,
            data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA)
        });
        vm.prank(address(engine));
        vm.expectRevert();
        urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, overCap));
    }

    /// @dev CONTROL 5 — an in-cap, correctly-pinned request still validates, so the guard costs a
    ///      legitimate single-rule rules set nothing.
    function test_legitimateSingleRuleStillValidates() public {
        AllowedCall[] memory rules = new AllowedCall[](1);
        rules[0] = _tight();
        vm.prank(address(engine));
        urp.initializeWithMultiplexer(ACCOUNT, CID, universalInitData(_cfgWith(rules)));

        Multicall[] memory calls = new Multicall[](1);
        calls[0] = Multicall({
            to: PROTOCOL,
            value: 1 ether,
            data: abi.encodeWithSelector(SWAP_SELECTOR, uint256(1), CEA)
        });

        vm.prank(address(engine));
        uint256 vd =
            urp.checkAction(CID, ACCOUNT, GATEWAY, 0, outboundRequest(ASSET, 1 ether, 1 ether, ACCOUNT, calls));
        assertEq(vd, VALIDATION_SUCCESS, "in-cap, correctly-pinned call still validates");
    }
}
