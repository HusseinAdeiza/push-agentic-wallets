// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { Session, ActionData, PolicyData, ERC7739Data, ERC7739Context } from "smartsessions/DataTypes.sol";
import { ISessionValidator } from "smartsessions/interfaces/ISessionValidator.sol";
import { AddressBook } from "../../lib/AddressBook.sol";
import { DemoLog } from "../../lib/DemoLog.sol";
import { Keys } from "../../lib/Keys.sol";
import { Ledger } from "../../lib/Ledger.sol";
import { Amounts } from "../../lib/Amounts.sol";
import { BobPayload, IUEA, UniversalPayload } from "../../lib/BobPayload.sol";
import { IURP } from "../../../src/interfaces/IURP.sol";
import { IPushAgentWallet } from "../../../src/interfaces/IPushAgentWallet.sol";
import { SEND_OUTBOUND_SELECTOR, MandateType } from "../../../src/libraries/PushWalletTypes.sol";
import { StakeDummy } from "../../contracts/StakeDummy.sol";

/// @dev `IPushAgentWallet` carries the wallet's EVENTS only — it deliberately declares no
///      functions — so the one call this script encodes is declared here. The signature mirrors
///      `PushAgentWallet.grantMandate` exactly; `Session` is the same `smartsessions` type the
///      wallet takes, so `abi.encodeCall` type-checks against the real ABI.
///
/// @dev  THE SECOND ARGUMENT IS NEW. URP became a two-mode policy, and the type is now an explicit
///       parameter rather than something inferred from the action's target — so the SELECTOR
///       CHANGED. A payload built against the old one-argument shape does not fail a shape check;
///       it misses the function entirely.
interface IWalletGrant {
    function grantMandate(Session calldata session, MandateType mandateType) external returns (bytes32 permissionId);
}

/**
 * @title  GrantMandate
 * @notice ACT 1e · Chain: Donut · broadcasts with the relayer key, on a payload BOB signed.
 *         THE MOST IMPORTANT OUTPUT ANY SCRIPT IN THIS DEMO PRODUCES.
 *
 * @dev    The mandate summary this prints is the demo's thesis on one screen, and it is where the
 *         live demo opens. Everything else exists to make it credible.
 *
 *         WHAT THE MANDATE SAYS, in one sentence: this agent key may call two functions on one
 *         contract on one chain, only ever for Bob's own account, up to 50 USDC per action and
 *         60 USDC in total, for seven days. Nothing else.
 *
 *         THE SHAPE IS ENFORCED BY THE WALLET, NOT BY CONVENTION. `grantMandate` refuses anything
 *         but the canonical shape: exactly one action, the canonical validator, exactly one action
 *         policy which must be the deployed URP, no user-op policies, no ERC-7739 policies, and
 *         `permitERC4337Paymaster` false. The salt passed here is discarded — the wallet overwrites
 *         it with its own monotonic grant counter, so every grant yields a permission id that never
 *         recurs.
 *
 *         `expectedCEA` IS THE FIELD THAT MAKES THE DEMO. It is committed at grant time, before the
 *         CEA has done anything, and gates 14 and 15 measure every agent request against it. It is
 *         why the agent can stake for Bob and for nobody else.
 *
 *         `approve` IS DELIBERATELY NOT IN THE ALLOW-LIST — see `13_ApproveStakeDummyOnCEA`.
 */
contract GrantMandate is Script {
    error MandateNotGranted();
    error CEAMismatch(address predicted, address deployed);

    uint48 internal constant VALIDITY = 7 days;
    uint256 internal constant VALID_FOR = 1 hours;

    /// @dev `stakeFor(address beneficiary, uint256 amount)` — the beneficiary is the FIRST argument
    ///      word, immediately after the 4-byte selector. Gate 15 reads a 32-byte word at this
    ///      offset and asserts it equals `expectedCEA`.
    uint16 internal constant BENEFICIARY_OFFSET = 4;

    function run() external {
        uint256 bobPk = Keys.load("BOB_KEY", "Bob signs every owner action");
        uint256 relayerPk = Keys.load("PC_RELAYER_KEY", "the relayer submits");
        address agent = Keys.addressOf("AGENT_KEY", "the agent key the mandate authorises");

        address uea = Ledger.addr("uea", "10_Arrive");
        address agw = Ledger.addr("agw", "10_Arrive");
        address cea = Ledger.addr("predictedCEA", "10_Arrive");
        address stakeDummy = AddressBook.sepolia("StakeDummy");
        address prc20 = AddressBook.donut("PRC20_USDC");
        address validator = AddressBook.ours("sessionValidator");
        address urp = AddressBook.ours("urp");

        uint256 maxPCPerCall = Ledger.num("quote.maxPCPerCall", "01_Quote");

        Session memory session = _session(validator, urp, agent, cea, prc20, stakeDummy, maxPCPerCall);

        // UNIVERSAL: this mandate's one action is the gateway's outbound send. The wallet asserts
        // the declared type against the action target, so a mismatch is `MandateTypeMismatch` rather
        // than a silent acceptance.
        (UniversalPayload memory payload, bytes memory signature) = BobPayload.signedCall(
            uea, agw, abi.encodeCall(IWalletGrant.grantMandate, (session, MandateType.UNIVERSAL)), bobPk, VALID_FOR
        );

        vm.recordLogs();
        vm.startBroadcast(relayerPk);
        IUEA(uea).executeUniversalTx(payload, signature);
        vm.stopBroadcast();

        bytes32 permissionId = _readPermissionId();
        Ledger.setWord("permissionId", permissionId);
        Ledger.setNum("mandate.maxPCPerCall", maxPCPerCall);
        Ledger.setNum("nonceSeq", 0);

        _printMandate(agent, cea, stakeDummy, permissionId);
    }

    /// @dev The canonical session shape. Every field is checked by `grantMandate`; see the contract.
    function _session(
        address validator,
        address urp,
        address agent,
        address cea,
        address prc20,
        address stakeDummy,
        uint256 maxPCPerCall
    ) internal view returns (Session memory) {
        // THE MODE WRAPPER. URP's `initData` is `abi.encode(uint8 mode, bytes body)` — no longer a
        // bare `abi.encode(Config)`. A legacy bare struct does not mis-decode into something wrong;
        // it reverts, UNNAMED, which is the one unnamed revert `initializeWithMultiplexer` has. That
        // is a deliberate design choice upstream, and it is why this wrapper is not optional.
        PolicyData[] memory actionPolicies = new PolicyData[](1);
        actionPolicies[0] = PolicyData({
            policy: urp,
            initData: abi.encode(
                uint8(MandateType.UNIVERSAL), abi.encode(_config(cea, prc20, stakeDummy, maxPCPerCall))
            )
        });

        ActionData[] memory actions = new ActionData[](1);
        // Selector BEFORE target — that is the declaration order in DataTypes.sol.
        actions[0] = ActionData({
            actionTargetSelector: SEND_OUTBOUND_SELECTOR,
            actionTarget: AddressBook.donut("UniversalGatewayPC"),
            actionPolicies: actionPolicies
        });

        return Session({
            sessionValidator: ISessionValidator(validator),
            // Scheme 0 = ECDSA; the key is 20 RAW bytes, never padded. This encoding feeds the
            // permission id, so changing it changes every id.
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

    /// @dev The terms. `initialized` and `spent` are forced by the contract whatever is passed.
    function _config(address cea, address prc20, address stakeDummy, uint256 maxPCPerCall)
        internal
        view
        returns (IURP.Config memory)
    {
        IURP.AllowedCall[] memory allowed = new IURP.AllowedCall[](2);

        // The agent may stake — but the beneficiary is pinned to the CEA, one argument deep.
        allowed[0] = IURP.AllowedCall({
            target: stakeDummy,
            selector: StakeDummy.stakeFor.selector,
            beneficiaryOffset: BENEFICIARY_OFFSET,
            hasBeneficiary: true,
            maxValue: 0 // not payable; gate 16 rejects any entry carrying value
        });

        // And unstake, which takes no arguments — the caller is the staker.
        allowed[1] = IURP.AllowedCall({
            target: stakeDummy,
            selector: StakeDummy.unstake.selector,
            beneficiaryOffset: 0,
            hasBeneficiary: false,
            maxValue: 0
        });

        return IURP.Config({
            initialized: false,
            validUntil: uint48(block.timestamp) + VALIDITY,
            destChainHash: BobPayload.chainHash("11155111"),
            expectedCEA: cea,
            asset: prc20,
            maxAmountPerCall: Amounts.perCall(),
            maxAmountTotal: Amounts.total(),
            maxPCPerCall: maxPCPerCall,
            spent: 0,
            allowedCalls: allowed
        });
    }

    /// @dev The permission id comes from the wallet's own event, never recomputed here — the
    ///      derivation mixes `abi.encode` and `abi.encodePacked` across levels, and an SDK that
    ///      assumes one throughout derives every id wrong.
    function _readPermissionId() internal returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IPushAgentWallet.MandateGranted.selector;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic) return logs[i].topics[1];
        }
        revert MandateNotGranted();
    }

    /**
     * @dev THE DEMO'S THESIS ON ONE SCREEN. Get this right before anything else — it is where the
     *      live demo opens, and it is the block the audience reads while everything else scrolls.
     */
    function _printMandate(address agent, address cea, address stakeDummy, bytes32 permissionId) internal view {
        DemoLog.header("", "The mandate");
        DemoLog.line(DemoLog.bold("This agent key may:"));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("stakeFor()"), " on StakeDummy"));
        DemoLog.note(string.concat("      but only ever for ", vm.toString(cea)));
        DemoLog.line(string.concat(unicode"  · call ", DemoLog.bold("unstake()"), " on StakeDummy"));
        DemoLog.blank();
        DemoLog.money("Per action", Amounts.perCall(), 6, "USDC");
        DemoLog.money("Lifetime", Amounts.total(), 6, "USDC");
        DemoLog.kv("Expires", "in 7 days");
        DemoLog.blank();
        DemoLog.line(DemoLog.dim("Nothing else. No other contract, no other function,"));
        DemoLog.line(DemoLog.dim("no other beneficiary, no other chain."));
        DemoLog.footer();

        DemoLog.header("", "For the record");
        DemoLog.addrPlain("Agent key", agent);
        DemoLog.note("    Holds no funds. Owns nothing. Cannot be topped up.");
        DemoLog.addrPlain("StakeDummy", stakeDummy);
        DemoLog.kv("Permission id", vm.toString(permissionId));
        DemoLog.footer();
    }
}
