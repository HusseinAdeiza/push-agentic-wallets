// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SmartSession } from "smartsessions/SmartSession.sol";
import { PushSessionValidator } from "../src/validators/PushSessionValidator.sol";
import { URP } from "../src/policies/URP.sol";
import { PushAgentWallet } from "../src/PushAgentWallet.sol";
import { AGWFactory } from "../src/AGWFactory.sol";

/**
 * @title  Deploy — the v3 contract set, in the dependency order of the deployment spec §2.
 *
 * @dev    THE ORDER IS A DEPENDENCY GRAPH, not a preference. Each step consumes only addresses
 *         recorded by earlier steps:
 *
 *           engine -> validator -> URP (needs engine)
 *                  -> wallet implementation (needs engine, URP, validator, gateway)
 *                  -> factory (needs the wallet implementation)
 *
 *         The validator has no on-chain dependencies and could go first; it is second only to keep
 *         the record in a stable order.
 *
 * @dev    NO ADDRESS IS EVER PASTED INTO SOURCE. The wallet takes its four wiring addresses as
 *         CONSTRUCTOR ARGUMENTS, so nothing is recompiled per network — which is also what makes
 *         honest tests possible (the alternative would force etching code at a hardcoded address,
 *         the pattern that once hid a critical bug in this repo).
 *
 * @dev    `SmartSessionCompatibilityFallback` is NOT deployed. Nothing in v3 uses it; the wallet
 *         refuses module type 3 entirely.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast
 * Required environment: UNIVERSAL_GATEWAY_PC, UNIVERSAL_EXECUTOR_MODULE, CHAIN_ID
 * Optional:            FACTORY_ADMIN (defaults to the broadcasting address)
 */
contract Deploy is Script {
    /// @dev The vendored SmartSession fork pin. A SEPARATE key from `commit` in the record: the two
    ///      share a value only until this repo's first commit, and S-05 comparing the wrong one
    ///      would pass silently forever.
    string internal constant ENGINE_FORK_COMMIT = "7dc20e4";

    error MissingEnv(string name);

    /// @dev The environment disagrees with the chain actually being deployed to.
    error ChainIdMismatch(uint256 fromEnv, uint256 fromChain);

    function run() external {
        address gatewayPC = vm.envAddress("UNIVERSAL_GATEWAY_PC");
        address executorModule = vm.envAddress("UNIVERSAL_EXECUTOR_MODULE");
        uint256 chainId = vm.envUint("CHAIN_ID");

        if (gatewayPC == address(0)) revert MissingEnv("UNIVERSAL_GATEWAY_PC");
        if (executorModule == address(0)) revert MissingEnv("UNIVERSAL_EXECUTOR_MODULE");

        // ASK THE CHAIN, DO NOT TRUST THE ENVIRONMENT.
        //
        // `CHAIN_ID` decides the record's filename AND its `chainId` field, so without this check
        // the env value is the only input and nothing ever contradicts it. `.env.example` ships
        // `CHAIN_ID=31337`; deploying to mainnet with that default left behind would write
        // `deployments/31337.json` describing MAINNET addresses — and S-05 would pass it green,
        // because every address genuinely has code on the mainnet fork.
        if (chainId != block.chainid) revert ChainIdMismatch(chainId, block.chainid);

        // THE UPGRADE AUTHORITY IS THE ONE POWER THAT CAN STRAND COUNTERFACTUALLY FUNDED ADDRESSES,
        // so outside a local chain it must be named deliberately rather than defaulted to whichever
        // hot key happened to broadcast.
        address admin = block.chainid == 31_337 ? vm.envOr("FACTORY_ADMIN", msg.sender) : vm.envAddress("FACTORY_ADMIN");
        if (admin == address(0)) revert MissingEnv("FACTORY_ADMIN");

        vm.startBroadcast();

        // 1 · SmartSession — plain deploy: no constructor, no arguments, no admin, no owner.
        SmartSession engine = new SmartSession();

        // 2 · PushSessionValidator — stateless; never installed, only named inside each permission.
        PushSessionValidator validator = new PushSessionValidator();

        // 3 · URP — three constructor args. The engine is a STATED dependency here, not a
        //     coincidence of ordering: URP keys its storage on a SESSION_ENGINE immutable.
        URP urp = new URP(gatewayPC, executorModule, address(engine));

        // 4 · The wallet implementation. Its constructor rejects any zero.
        PushAgentWallet walletImplementation =
            new PushAgentWallet(address(engine), address(urp), address(validator), gatewayPC);

        // 5 · The factory: logic + proxy, initialised in the SAME transaction so no initialisation
        //     front-run window exists. THE PROXY ADDRESS IS PERMANENT and user-facing.
        AGWFactory factoryLogic = new AGWFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryLogic), abi.encodeCall(AGWFactory.initialize, (admin, address(walletImplementation)))
        );

        vm.stopBroadcast();

        _writeRecord(
            chainId,
            address(engine),
            address(validator),
            address(urp),
            gatewayPC,
            executorModule,
            address(walletImplementation),
            address(factoryProxy),
            address(factoryLogic)
        );
    }

    /**
     * @dev Writes `deployments/<chainId>.json`. THE KEYS ARE EXACT — the four wiring keys are named
     *      after the wallet's view functions so S-05's comparison is mechanical.
     *
     *      Local records are NEVER committed (see deployments/README.md).
     */
    function _writeRecord(
        uint256 chainId,
        address sessionEngine,
        address sessionValidator,
        address urp,
        address universalGateway,
        address universalExecutorModule,
        address walletImplementation,
        address factoryProxy,
        address factoryLogic
    ) internal {
        string memory obj = "record";

        vm.serializeUint(obj, "chainId", chainId);
        vm.serializeString(obj, "commit", _repoCommit());
        vm.serializeString(obj, "engineForkCommit", ENGINE_FORK_COMMIT);
        vm.serializeAddress(obj, "sessionEngine", sessionEngine);
        vm.serializeAddress(obj, "sessionValidator", sessionValidator);
        vm.serializeAddress(obj, "urp", urp);
        vm.serializeAddress(obj, "universalGateway", universalGateway);
        vm.serializeAddress(obj, "universalExecutorModule", universalExecutorModule);
        vm.serializeAddress(obj, "walletImplementation", walletImplementation);
        vm.serializeAddress(obj, "factoryLogic", factoryLogic);
        string memory json = vm.serializeAddress(obj, "factoryProxy", factoryProxy);

        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        vm.writeJson(json, path);

        console2.log("deployment record written to", path);
        console2.log("  factoryProxy (PERMANENT, user-facing)", factoryProxy);
    }

    /**
     * @dev The repo HEAD the script ran from. `ffi = true` is already set in foundry.toml.
     *
     *      `git rev-parse HEAD` emits a 40-char hex string, and `vm.ffi` HEX-DECODES output that
     *      looks like hex — so returning it directly writes 20 raw bytes into the record instead of
     *      the commit text (observed). Piping through `tr -d` and prefixing a non-hex marker is what
     *      keeps it a readable string.
     */
    function _repoCommit() internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "-c";
        cmd[2] = "printf 'git:' && git rev-parse HEAD | tr -d '\n'";
        try vm.ffi(cmd) returns (bytes memory out) {
            return string(out);
        } catch {
            return "unknown";
        }
    }
}
