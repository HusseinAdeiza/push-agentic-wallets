// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console } from "forge-std/Script.sol";

import { PushAgentWallet } from "../src/PushAgentWallet.sol";
import { AgentWalletFactory } from "../src/AgentWalletFactory.sol";
import { PushSessionValidator } from "../src/validators/PushSessionValidator.sol";
import { ACPActionPolicy } from "../src/policies/ACPActionPolicy.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { ERC20SpendingLimitPolicy } from "smartsessions/external/policies/ERC20SpendingLimitPolicy.sol";
import { TimeFramePolicy } from "smartsessions/external/policies/TimeFramePolicy.sol";
import { ValueLimitPolicy } from "smartsessions/external/policies/ValueLimitPolicy.sol";
import { UsageLimitPolicy } from "smartsessions/external/policies/UsageLimitPolicy.sol";
import { ContractWhitelistPolicy } from "smartsessions/external/policies/ContractWhitelistPolicy.sol";

/**
 * @title  Deploy
 * @notice Single deployment entry point for the whole system (PRD §10.2, Step 15).
 *
 * @dev    MERGED from v1's `DeployCore` + `DeployModules` deliberately. Under v2 the
 *         wallet implementation takes SmartSession and three policy addresses in its
 *         constructor, which INVERTS v1's order: v1 ran Core (wallet, factory) before
 *         Modules. Keeping two scripts would leave the broken order expressible; one
 *         script makes it unrepresentable.
 *
 * @dev    `UNIVERSAL_GATEWAY_PC` is a deployment input — supply it via the env var. It
 *         becomes immutable in BOTH `ACPActionPolicy` and the wallet implementation, so a
 *         wrong value means redeploying both.
 *
 * @dev    A-13 — the implementation's initializer is burned to `0xdead` immediately after
 *         deployment so nobody can initialize the logic contract directly. That burn now
 *         takes TWO arguments; the guardian is set to address(0) since the implementation
 *         is never used as a wallet.
 */
contract Deploy is Script {
    address internal constant DEAD = address(0xdead);

    struct Deployed {
        address smartSession;
        address pushSessionValidator;
        address timeFramePolicy;
        address valueLimitPolicy;
        address usageLimitPolicy;
        address contractWhitelistPolicy;
        address erc20SpendingLimitPolicy;
        address acpActionPolicy;
        address walletImplementation;
        address factory;
    }

    function run() external returns (Deployed memory d) {
        string memory network = vm.envOr("NETWORK", string("anvil"));
        address gatewayPC = vm.envAddress("UNIVERSAL_GATEWAY_PC");
        require(gatewayPC != address(0), "UNIVERSAL_GATEWAY_PC required");

        vm.startBroadcast();

        // ── 1. Session engine and validator ──
        d.smartSession = address(new SmartSession());
        d.pushSessionValidator = address(new PushSessionValidator());

        // ── 2. Adopted policies. TimeFrame and ValueLimit are MANDATORY on every
        //       mandate (F-09) and are pinned into the wallet implementation below.
        //       The remaining three are deployed because tests depend on them;
        //       `ERC20SpendingLimitPolicy` is NOT in the live session path (§0.2), and
        //       `SimpleGasPolicy` is deliberately never deployed (§0.5).
        d.timeFramePolicy = address(new TimeFramePolicy());
        d.valueLimitPolicy = address(new ValueLimitPolicy());
        d.usageLimitPolicy = address(new UsageLimitPolicy());
        d.contractWhitelistPolicy = address(new ContractWhitelistPolicy());
        d.erc20SpendingLimitPolicy = address(new ERC20SpendingLimitPolicy());

        // ── 3. Our policy. Must precede the wallet: the wallet pins it. ──
        d.acpActionPolicy = address(new ACPActionPolicy(gatewayPC));

        // ── 4. Wallet implementation. Needs every address above. ──
        PushAgentWallet impl =
            new PushAgentWallet(d.smartSession, gatewayPC, d.acpActionPolicy, d.timeFramePolicy, d.valueLimitPolicy);
        d.walletImplementation = address(impl);

        // A-13 — burn the implementation's initializer.
        impl.initialize(DEAD, address(0));

        // ── 5. Factory, last. ──
        d.factory = address(new AgentWalletFactory(d.walletImplementation));

        vm.stopBroadcast();

        _assertSealed(impl);
        _assertWiring(d, gatewayPC);

        console.log("SmartSession:             ", d.smartSession);
        console.log("PushSessionValidator:     ", d.pushSessionValidator);
        console.log("TimeFramePolicy:          ", d.timeFramePolicy);
        console.log("ValueLimitPolicy:         ", d.valueLimitPolicy);
        console.log("UsageLimitPolicy:         ", d.usageLimitPolicy);
        console.log("ContractWhitelistPolicy:  ", d.contractWhitelistPolicy);
        console.log("ERC20SpendingLimitPolicy: ", d.erc20SpendingLimitPolicy);
        console.log("ACPActionPolicy:          ", d.acpActionPolicy);
        console.log("PushAgentWallet impl:     ", d.walletImplementation);
        console.log("AgentWalletFactory:       ", d.factory);

        _write(network, d);
    }

    /// @dev A-13. The implementation must be permanently un-initializable.
    function _assertSealed(PushAgentWallet impl) internal {
        require(impl.owner() == DEAD, "implementation not sealed");
        (bool ok,) = address(impl).call(abi.encodeCall(PushAgentWallet.initialize, (address(1), address(0))));
        require(!ok, "implementation must reject a second initialize");
    }

    /// @dev Smoke assertion (Step 15): the implementation's immutables must match what we
    ///      just deployed. Catches a mis-ordered or mis-wired run before anything is used.
    function _assertWiring(Deployed memory d, address gatewayPC) internal view {
        PushAgentWallet impl = PushAgentWallet(payable(AgentWalletFactory(d.factory).WALLET_IMPLEMENTATION()));
        require(address(impl) == d.walletImplementation, "factory points elsewhere");
        require(impl.SMART_SESSION() == d.smartSession, "SMART_SESSION mismatch");
        require(impl.UNIVERSAL_GATEWAY_PC() == gatewayPC, "UNIVERSAL_GATEWAY_PC mismatch");
        require(impl.ACP_ACTION_POLICY() == d.acpActionPolicy, "ACP_ACTION_POLICY mismatch");
        require(impl.TIMEFRAME_POLICY() == d.timeFramePolicy, "TIMEFRAME_POLICY mismatch");
        require(impl.VALUE_LIMIT_POLICY() == d.valueLimitPolicy, "VALUE_LIMIT_POLICY mismatch");
        require(ACPActionPolicy(d.acpActionPolicy).UNIVERSAL_GATEWAY_PC() == gatewayPC, "ACP gateway mismatch");
    }

    function _write(string memory network, Deployed memory d) internal {
        string memory json = string.concat(
            '{\n  "smartSession": "',
            vm.toString(d.smartSession),
            '",\n  "pushSessionValidator": "',
            vm.toString(d.pushSessionValidator),
            '",\n  "timeFramePolicy": "',
            vm.toString(d.timeFramePolicy),
            '",\n  "valueLimitPolicy": "',
            vm.toString(d.valueLimitPolicy),
            '",\n  "usageLimitPolicy": "',
            vm.toString(d.usageLimitPolicy),
            '",\n  "contractWhitelistPolicy": "',
            vm.toString(d.contractWhitelistPolicy),
            '",\n  "erc20SpendingLimitPolicy": "',
            vm.toString(d.erc20SpendingLimitPolicy),
            '",\n  "acpActionPolicy": "',
            vm.toString(d.acpActionPolicy),
            '",\n  "pushAgentWalletImplementation": "',
            vm.toString(d.walletImplementation),
            '",\n  "agentWalletFactory": "',
            vm.toString(d.factory),
            '"\n}\n'
        );
        vm.writeFile(string.concat("deployments/", network, ".json"), json);
    }
}
