// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../Base.t.sol";
import { AGW } from "../../src/AGW.sol";
import { AGWFactory } from "../../src/AGWFactory.sol";
import { IAGW } from "../../src/interfaces/IAGW.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { IUniversalRulesPolicy } from "../../src/interfaces/IUniversalRulesPolicy.sol";
import { AGWErrors, UniversalRulesPolicyErrors } from "../../src/libraries/Errors.sol";

/**
 * @title  NamingTest — pins the wire format the nomenclature change introduced.
 * @notice Every renamed event topic, error selector and function selector is compared against its
 *         canonical signature written as a LITERAL, so a future rename cannot happen silently: it
 *         changes a selector, and a selector change fails here. Also proves `IAGW` declares exactly
 *         the wallet's external surface and that no legacy name survives in a compiled ABI.
 *         Source: docs-internal/sdk-first-changes/N-nomenclature_prd.md §5.3.
 */
contract NamingTest is BaseTest {
    /// @dev `Session` as the ABI spells it: (validator, initData, salt, userOpPolicies,
    ///      erc7739Policies, actions, permitERC4337Paymaster).
    string internal constant SESSION_TUPLE =
        "(address,bytes,bytes32,(address,bytes)[],((bytes32,string[])[],(address,bytes)[]),(bytes4,address,(address,bytes)[])[],bool)";

    /// @dev `OwnerIntent` as the ABI spells it.
    string internal constant INTENT_TUPLE =
        "(address,address,address,uint96,bytes32,bytes32,bytes32,uint192,uint64,uint64,uint48,uint256)";

    function test_naming_eventTopics() public pure {
        assertEq(IAGW.RulesGranted.selector, keccak256("RulesGranted(bytes32,uint8,bytes32,string)"));
        assertEq(IAGW.RulesRevoked.selector, keccak256("RulesRevoked(bytes32)"));
        assertEq(
            IAGW.RulesActionAuthorized.selector, keccak256("RulesActionAuthorized(bytes32,uint192,uint64,bytes32)")
        );
        assertEq(
            IUniversalRulesPolicy.RulesConfigured.selector,
            keccak256("RulesConfigured(bytes32,address,address,uint8,uint8,bytes32)")
        );
        assertEq(IAGWFactory.WalletDeployed.selector, keccak256("WalletDeployed(address,uint256,address,string)"));
    }

    function test_naming_renamedErrorSelectors() public pure {
        assertEq(AGWErrors.CallerIsNotOwner.selector, bytes4(keccak256("CallerIsNotOwner()")));
        assertEq(AGWErrors.CallerIsNotFactory.selector, bytes4(keccak256("CallerIsNotFactory()")));
        assertEq(AGWErrors.RulesTypeMismatch.selector, bytes4(keccak256("RulesTypeMismatch(uint8,uint256,address)")));
        assertEq(UniversalRulesPolicyErrors.RulesExpired.selector, bytes4(keccak256("RulesExpired(uint48)")));
        assertEq(
            UniversalRulesPolicyErrors.CallerIsNotUEModule.selector, bytes4(keccak256("CallerIsNotUEModule(address)"))
        );
    }

    function test_naming_renamedFunctionSelectors() public pure {
        assertEq(AGW.grantRules.selector, bytes4(keccak256(bytes(string.concat("grantRules(", SESSION_TUPLE, ")")))));
        assertEq(
            AGW.grantRulesWithSig.selector,
            bytes4(keccak256(bytes(string.concat("grantRulesWithSig(", SESSION_TUPLE, ",", INTENT_TUPLE, ",bytes)"))))
        );
        assertEq(AGW.revokeRules.selector, bytes4(keccak256("revokeRules(bytes32)")));
        assertEq(AGW.revokeAllRules.selector, bytes4(keccak256("revokeAllRules()")));
        assertEq(AGW.domainSeparator.selector, bytes4(keccak256("domainSeparator(uint256)")));
        assertEq(IAGW.SESSION_ENGINE.selector, bytes4(keccak256("SESSION_ENGINE()")));
        assertEq(IAGW.RULES_POLICY.selector, bytes4(keccak256("RULES_POLICY()")));
        assertEq(IAGW.SESSION_VALIDATOR.selector, bytes4(keccak256("SESSION_VALIDATOR()")));
        assertEq(IAGW.UNIVERSAL_GATEWAY_PC.selector, bytes4(keccak256("UNIVERSAL_GATEWAY_PC()")));
        assertEq(
            AGWFactory.deployWalletWithSig.selector,
            bytes4(keccak256(bytes(string.concat("deployWalletWithSig(", INTENT_TUPLE, ",bytes,string)"))))
        );
    }

    /// @dev XOR of the wallet's 28 external selectors — taken from the CONTRACT, or as literals for the
    ///      four auto-getters — equals `type(IAGW).interfaceId`, so `IAGW` declares exactly the wallet's
    ///      surface. `assertSelectorSet` in the owner-door suite proves the contract has exactly these.
    function test_naming_IAGWIsTheWholeSurface() public pure {
        bytes4[28] memory s = [
            AGW.initializeAccount.selector,
            AGW.execute.selector,
            AGW.grantRules.selector,
            AGW.grantRulesWithSig.selector,
            AGW.executeWithSig.selector,
            AGW.domainSeparator.selector,
            AGW.revokeRules.selector,
            AGW.revokeAllRules.selector,
            AGW.executeWithSession.selector,
            AGW.installModule.selector,
            AGW.uninstallModule.selector,
            AGW.isModuleInstalled.selector,
            AGW.supportsModule.selector,
            AGW.supportsExecutionMode.selector,
            AGW.owner.selector,
            AGW.factory.selector,
            AGW.getNonce.selector,
            AGW.grantNonce.selector,
            AGW.accountId.selector,
            bytes4(keccak256("SESSION_ENGINE()")),
            bytes4(keccak256("RULES_POLICY()")),
            bytes4(keccak256("SESSION_VALIDATOR()")),
            bytes4(keccak256("UNIVERSAL_GATEWAY_PC()")),
            AGW.onERC721Received.selector,
            AGW.onERC1155Received.selector,
            AGW.onERC1155BatchReceived.selector,
            AGW.supportsInterface.selector,
            AGW.isValidSignature.selector
        ];
        bytes4 x;
        for (uint256 i; i < s.length; ++i) {
            x ^= s[i];
        }
        assertEq(x, type(IAGW).interfaceId, "IAGW declares exactly the wallet's 28 external functions");
    }

    function test_naming_noLegacyVocabularyInABIs() public view {
        string[4] memory artifacts = [
            "out/AGW.sol/AGW.json",
            "out/UniversalRulesPolicy.sol/UniversalRulesPolicy.json",
            "out/AGWFactory.sol/AGWFactory.json",
            "out/AgentValidator.sol/AgentValidator.json"
        ];
        string[4] memory legacy = ["andate", "PushAgentWallet", "PushSessionValidator", "URPPolicySet"];
        for (uint256 a; a < artifacts.length; ++a) {
            string memory abiSection = _abiOf(artifacts[a]);
            for (uint256 k; k < legacy.length; ++k) {
                assertEq(
                    vm.indexOf(abiSection, legacy[k]),
                    type(uint256).max,
                    string.concat(artifacts[a], " ABI still contains ", legacy[k])
                );
            }
        }
        assertEq(
            vm.indexOf(_abiOf(artifacts[0]), "\"permissionId\""),
            type(uint256).max,
            "every wallet-ABI parameter is rulesId, never permissionId"
        );
    }

    function test_naming_identityStrings() public {
        AGW wallet = newWallet(makeAddr("namingOwner"));
        assertEq(wallet.accountId(), "push.agw.1.0.0", "ERC-7579 account id");
        assertEq(urp.version(), "2.0.0", "policy version");
    }

    /// @dev The `abi` section of a forge artifact: everything before the `bytecode` key. NatSpec
    ///      (devdoc/userdoc) and metadata come later in the file and are deliberately excluded.
    function _abiOf(string memory path) internal view returns (string memory) {
        return vm.split(vm.readFile(path), "\"bytecode\"")[0];
    }
}
