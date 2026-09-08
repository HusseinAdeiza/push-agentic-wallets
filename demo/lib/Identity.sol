// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AddressBook } from "./AddressBook.sol";
import { BobPayload } from "./BobPayload.sol";
import { ICEAFactory } from "./PushCore.sol";
import { Requests } from "./Requests.sol";
import { IAGWFactory } from "../../src/interfaces/IAGWFactory.sol";
import { Multicall } from "../../src/libraries/PushWalletTypes.sol";
import { ExecutionLib } from "../../src/libraries/ExecutionLib.sol";

/**
 * @title  Identity
 * @notice The four-address chain — Bob's EOA, his UEA, his AGW, and its CEA — resolved on demand.
 *
 * @dev    THREE OF THE FOUR ARE COMPUTABLE BEFORE THEY EXIST, and that is what makes the demo
 *         possible: Bob's single Sepolia transaction references an AGW that does not exist yet, and
 *         the mandate he grants names a CEA that will not exist for another two acts.
 *
 *         WHY A LIBRARY RATHER THAN FOUR COPIES. Each derivation reads a factory on a specific
 *         chain, and two of them live on the chain a given script is NOT broadcasting to. Getting
 *         that wrong produces `call to non-contract address`, which is at least loud — but the
 *         subtler error is passing the wrong chain id into `computeUEA`, which silently yields a
 *         different, equally valid-looking address. One implementation, used everywhere.
 *
 *         THE CHAIN ID IS THE OWNER'S, NEVER THE SCRIPT'S. `UniversalAccountId.chainId` identifies
 *         where the owner lives — Sepolia — regardless of which chain the factory runs on or which
 *         chain the caller is broadcasting to. Never pass `block.chainid`.
 */
library Identity {
    // `Vm`, not `VmSafe`: fork switching is a state-changing cheatcode, and `resolveAll`
    // reads factories that live on two different chains.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Bob's home chain, as Push core keys identities.
    string internal constant SOURCE_CHAIN_ID = "11155111";

    /// @dev Every AGW in the demo is wallet index 0 of its owner.
    uint256 internal constant WALLET_INDEX = 0;

    /**
     * @notice Bob's UEA on Push Chain. Deterministic; exists or not, the address is the same.
     * @dev    Must be called while the active fork is DONUT — `UEAFactory` lives there.
     * @param  bobEOA Bob's Ethereum address.
     */
    function uea(address bobEOA) internal view returns (address) {
        return BobPayload.predictUEA(AddressBook.donut("UEAFactory"), SOURCE_CHAIN_ID, bobEOA);
    }

    /**
     * @notice The AGW that UEA owns, at index 0.
     * @dev    Must be called while the active fork is DONUT. The factory's derivation is frozen
     *         forever, so this address is safe to reference before deployment — counterfactual
     *         funding is a supported flow with no recovery path.
     * @param  ueaAddress The owner, which is always a UEA in this demo.
     * @return wallet   The address the wallet has or will have.
     * @return deployed Whether it exists yet.
     */
    function agw(address ueaAddress) internal view returns (address wallet, bool deployed) {
        return IAGWFactory(AddressBook.ours("factoryProxy")).predictWallet(ueaAddress, WALLET_INDEX);
    }

    /**
     * @notice The AGW's CEA on Sepolia — its hands on the destination chain.
     *
     * @dev    Must be called while the active fork is SEPOLIA.
     *
     *         THE CEA DOES NOT REQUIRE A UEA. `Vault.finalizeUniversalTx` asks
     *         `CEAFactory.getCEAForPushAccount(pushAccount)` and deploys if absent, with no check
     *         that the account is a UEA. The AGW is a plain contract and gets a CEA like any other
     *         Push-side sender. The interface docs say "UEA address on Push Chain"; the
     *         implementation accepts any address, and this demo relies on the implementation.
     *
     * @param agwAddress The Push-side account whose CEA is wanted.
     */
    function cea(address agwAddress) internal view returns (address) {
        return ICEAFactory(AddressBook.sepolia("CEAFactory")).computeCEA(agwAddress);
    }

    /**
     * @notice Resolve the whole chain in one call, switching forks as each factory requires.
     *
     * @dev    Leaves the active fork wherever it started, so a caller mid-broadcast is unaffected.
     *         Two of the three reads happen on a chain the caller is probably not on, which is the
     *         entire reason this exists.
     *
     * @param bobEOA     Bob's Ethereum address.
     * @param donutRpc   Donut endpoint.
     * @param sepoliaRpc Sepolia endpoint.
     * @return ueaAddr  Bob's UEA on Push Chain.
     * @return agwAddr  Bob's agent wallet on Push Chain.
     * @return ceaAddr  The wallet's CEA on Sepolia.
     * @return agwLive  Whether the AGW is already deployed.
     */
    function resolveAll(address bobEOA, string memory donutRpc, string memory sepoliaRpc)
        internal
        returns (address ueaAddr, address agwAddr, address ceaAddr, bool agwLive)
    {
        uint256 startingFork = vm.activeFork();

        vm.createSelectFork(donutRpc);
        ueaAddr = uea(bobEOA);
        (agwAddr, agwLive) = agw(ueaAddr);

        vm.createSelectFork(sepoliaRpc);
        ceaAddr = cea(agwAddr);

        vm.selectFork(startingFork);
    }

    // ─────────────────────────── the arrival payload ───────────────────────────

    /**
     * @notice The three entries that turn a credited UEA into a funded, armed agent wallet.
     *
     * @dev    DECLARED ONCE, HERE, because two scripts submit these same entries by different
     *         routes: `10_Arrive` attaches them to the inbound bridge (inert on today's build) and
     *         `11_ArriveComplete` relays them as a signed payload (the path that works). Two
     *         hand-maintained copies of a three-entry multicall is precisely the duplication that
     *         stays correct until one of them is edited.
     *
     *         WHY EACH ENTRY WORKS:
     *
     *           1. The UEA is `msg.sender`, so the UEA becomes the wallet's owner. `deployWallet`
     *              initialises the wallet atomically, so it is live for entry 3.
     *           2. The pUSDC was minted to the UEA before this payload runs, so the balance is
     *              there — and the destination was computed before the wallet existed.
     *           3. THE OWNER DOOR, and the least obvious prerequisite in the whole flow. Without
     *              this allowance `UniversalGatewayPC._burnPRC20` cannot `transferFrom` the wallet,
     *              and EVERY agent request would revert inside the gateway, long after passing
     *              every policy gate.
     *
     * @param factory   The AGW factory proxy.
     * @param prc20     The PRC20 being bridged.
     * @param agwAddr   The wallet's predicted address.
     * @param gatewayPC `UniversalGatewayPC`, the allowance's spender.
     * @param amount    How much to move into the wallet.
     * @param label     The wallet label recorded by the factory.
     */
    function arrivalCalls(
        address factory,
        address prc20,
        address agwAddr,
        address gatewayPC,
        uint256 amount,
        string memory label
    ) internal pure returns (Multicall[] memory calls) {
        calls = new Multicall[](3);

        calls[0] = Multicall({ to: factory, value: 0, data: abi.encodeWithSignature("deployWallet(string)", label) });

        calls[1] = Multicall({ to: prc20, value: 0, data: abi.encodeCall(IERC20.transfer, (agwAddr, amount)) });

        calls[2] = Multicall({
            to: agwAddr,
            value: 0,
            data: abi.encodeWithSignature(
                "execute(bytes32,bytes)",
                Requests.singleMode(),
                ExecutionLib.encodeSingle(prc20, 0, abi.encodeCall(IERC20.approve, (gatewayPC, type(uint256).max)))
            )
        });
    }
}
