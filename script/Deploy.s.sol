// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

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

    /// @dev URP's logic contract and the ProxyAdmin that owns its upgrade right. Held here rather
    ///      than threaded through `_writeRecord`'s already-long parameter list. THE ADMIN ADDRESS
    ///      MUST BE RECORDED — TUP creates it internally and returns it nowhere, and without it the
    ///      deployment can never be upgraded.
    address internal _urpImplementation;
    address internal _urpProxyAdmin;

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

        // 3 · URP — logic + Transparent proxy, INITIALISED IN THE SAME TRANSACTION. A proxy left
        //     uninitialised is front-runnable: whoever calls `initialize` first chooses the engine
        //     the policy trusts. The engine is a STATED dependency here, not a coincidence of
        //     ordering: URP keys its storage on SESSION_ENGINE.
        //
        //     THE PROXY ADDRESS IS PERMANENT — it is what every wallet pins as its canonical
        //     policy, and it must not change across upgrades.
        URP urpLogic = new URP();
        TransparentUpgradeableProxy urpProxy = new TransparentUpgradeableProxy(
            address(urpLogic), admin, abi.encodeCall(URP.initialize, (gatewayPC, executorModule, address(engine)))
        );
        URP urp = URP(address(urpProxy));

        // TUP creates its own ProxyAdmin and returns it nowhere, so read it from the ERC-1967 admin
        // slot and RECORD IT. Without that address the deployment cannot be upgraded later.
        _urpImplementation = address(urpLogic);
        _urpProxyAdmin = address(uint160(uint256(vm.load(address(urpProxy), ERC1967Utils.ADMIN_SLOT))));

        // 3b · THE CHAIN-IDENTITY ASSERTIONS. Run here — after URP exists, before the wallet and
        //      factory do — so a disagreement aborts the broadcast with nothing user-facing deployed.
        //
        //      WHAT COULD GO WRONG WITHOUT THEM: the mandate mode is derived from a chain string,
        //      and `PushChainLib` computes this chain's identity from `block.chainid`. If Push named
        //      itself differently from that, every native mandate would derive UNIVERSAL and be
        //      refused at grant — after deployment, on a user's first attempt, with a diagnostic
        //      pointing at the action target rather than the cause.
        _assertChainIdentity(urp);

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

        // URP's implementation and admin travel in storage rather than as two more parameters:
        // this function is already at nine, and via_ir's 16-slot reach is not worth spending here.
        vm.serializeAddress(obj, "urpImplementation", _urpImplementation);
        vm.serializeAddress(obj, "urpProxyAdmin", _urpProxyAdmin);

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
        console2.log("  urp          (PERMANENT, pinned by every wallet)", urp);
        console2.log("  urpProxyAdmin (KEEP THIS - no upgrade is possible without it)", _urpProxyAdmin);
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

    /**
     * @dev THREE ASSERTIONS ON ONE FACT: what this chain calls itself.
     *
     *      The mandate mode is derived, not declared — `PushChainLib` hashes
     *      `"eip155:" ‖ decimal(block.chainid)` and a mandate on that chain is NATIVE. Nothing is
     *      configured, so there is no constant to set wrongly; what remains is the possibility that
     *      Push's own contracts disagree with `block.chainid` about Push's identity. That is what
     *      (3) checks, and it is the only one of the three that can fail on a correctly-built
     *      deployment.
     *
     *      (1) URP derives what the formula says it should — catches an implementation that was
     *          upgraded to a different derivation than this script was written against.
     *      (2) On Donut specifically, that value equals the pin every test hard-codes. Independently
     *          computed with `cast keccak "eip155:42101"`.
     *      (3) Core agrees. `UEAFactory.getOriginForUEA` on a NON-UEA address returns the identity
     *          core synthesises for Push-native accounts.
     *
     *      ⚠️ `pushChainId()` IS DELIBERATELY NOT CALLED. It exists in core's source but REVERTS on
     *      the deployed implementation (`0xb6dc…5b2f`, read from the EIP-1967 slot) — a
     *      source-versus-deployed drift measured on 2026-09-17. `getOriginForUEA` reads the same
     *      admin-set string through a function that is actually live.
     *
     *      (3) is skipped rather than failed when `UEA_FACTORY` is unset or has no code, because a
     *      local anvil run has no core deployment and must still be able to deploy.
     */
    function _assertChainIdentity(URP urp) internal view {
        bytes32 expected = keccak256(bytes(string.concat("eip155:", vm.toString(block.chainid))));
        require(urp.pushChainHash() == expected, "URP derives a different chain identity than this script");

        if (block.chainid == 42_101) {
            require(
                urp.pushChainHash() == 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9,
                "Donut chain hash does not match the pin"
            );
        }

        address ueaFactory = vm.envOr("UEA_FACTORY", address(0));
        if (ueaFactory == address(0) || ueaFactory.code.length == 0) return;

        (UniversalAccountId memory origin, bool isUEA) = IUEAFactoryOrigin(ueaFactory).getOriginForUEA(address(0xdEaD));
        require(!isUEA, "the probe address is a registered UEA - pick another");
        require(keccak256(bytes(origin.chainNamespace)) == keccak256(bytes("eip155")), "core namespace disagrees");
        require(
            keccak256(bytes(origin.chainId)) == keccak256(bytes(vm.toString(block.chainid))),
            "core and block.chainid disagree about this chain's id"
        );
    }
}

/**
 * @dev Deploy-only mirror of push-chain-core's `Types.UniversalAccountId`. FIELD ORDER IS
 *      ABI-LOAD-BEARING and is pinned by the live read documented in `_assertChainIdentity`.
 *
 *      Declared HERE rather than in `src/interfaces/` on purpose: it is used by one deploy-time
 *      sanity check and nothing in production reads it, so it should not enter the production
 *      interface surface that changes only by proposed diff.
 */
struct UniversalAccountId {
    string chainNamespace;
    string chainId;
    bytes owner;
}

interface IUEAFactoryOrigin {
    function getOriginForUEA(address addr) external view returns (UniversalAccountId memory, bool);
}
