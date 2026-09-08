// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AddressBook } from "./AddressBook.sol";

/// @dev The slices of Push core and Uniswap V3 needed to price the gas swap.
interface IUniversalCoreSwap {
    function WPC() external view returns (address);
    function uniswapV3Factory() external view returns (address);
    function defaultFeeTier(address gasToken) external view returns (uint24);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function token0() external view returns (address);
}

/**
 * @title  GasSwap
 * @notice Prices the PC an outbound's gas swap will actually consume.
 *
 * @dev    ── THE UNIT ERROR THIS LIBRARY EXISTS TO PREVENT ──
 *
 *         `getOutboundTxGasAndFees` returns TWO DIFFERENT CURRENCIES in one tuple:
 *
 *           · `gasFee`      is denominated in the GAS TOKEN (pETH)
 *           · `protocolFee` is denominated in NATIVE PC
 *
 *         Treating `gasFee` as PC — the obvious reading, and the one the demo spec originally
 *         carried — undersizes the swap by whatever the pETH/PC price happens to be. Measured on
 *         Donut that price is ~2,460 PC per pETH, so a "2x gasFee" budget was roughly **1/1000th**
 *         of what the swap needed. Every outbound reverted `STF`.
 *
 *         ── WHY `STF` AND NOT SOMETHING LEGIBLE ──
 *
 *         `UniversalCore.swapAndBurnGas` wraps the PC it receives and calls `exactOutputSingle`
 *         with `amountInMaximum = msg.value`. In Uniswap V3's router the callback's `transferFrom`
 *         runs BEFORE the `amountInMaximum` check, so an undersized budget surfaces as Uniswap's
 *         `STF` rather than "too much requested". The error names a transfer; the cause is a price.
 *
 *         ── AND WHY SWEEPING `msg.value` PROVED NOTHING ──
 *
 *         `UniversalGatewayPC` caps the swap at `maxPCForGas` and REFUNDS the rest
 *         (`UniversalGatewayPC.sol:145-148`). So raising `msg.value` while holding `maxPCForGas`
 *         fixed feeds the swap an identical amount every time. `maxPCForGas` is the only knob that
 *         moves the outcome.
 *
 *         ── THE PRICE COMES FROM THE POOL, NOT A GUESS ──
 *
 *         No QuoterV2 is deployed on Donut, so the cost is computed from the pool's own
 *         `slot0.sqrtPriceX96`. Cross-checked against a binary search over live `eth_call`s: the
 *         pool maths said 1.406 PC and the search found 1.428 PC — a 1.5% gap, which is the 0.05%
 *         pool fee plus slippage. Two independent methods agreeing is why this is trusted.
 */
library GasSwap {
    error PoolNotFound(address gasToken);
    error NoFeeTier(address gasToken);

    /// @dev Headroom over the spot cost, for price movement between quoting and landing, plus the
    ///      pool fee and slippage the spot price does not include. Surplus is refunded by the
    ///      gateway, so this costs nothing but a larger PC float in the wallet.
    uint256 internal constant HEADROOM_MULTIPLE = 3;

    /**
     * @notice PC required to buy `gasFeeInGasToken` of the gas token, at spot.
     *
     * @param gasToken         The gas token the swap must obtain — from the fee quote.
     * @param gasFeeInGasToken `gasFee` from `getOutboundTxGasAndFees`, in GAS-TOKEN units.
     * @return PC in, at spot, before fee and slippage.
     */
    function spotCost(address gasToken, uint256 gasFeeInGasToken) internal view returns (uint256) {
        IUniversalCoreSwap core = IUniversalCoreSwap(AddressBook.donut("UniversalCore"));

        address wpc = core.WPC();
        uint24 feeTier = core.defaultFeeTier(gasToken);
        if (feeTier == 0) revert NoFeeTier(gasToken);

        address pool = IUniswapV3Factory(core.uniswapV3Factory())
            .getPool(wpc < gasToken ? wpc : gasToken, wpc < gasToken ? gasToken : wpc, feeTier);
        if (pool == address(0)) revert PoolNotFound(gasToken);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        // price = (sqrtPriceX96 / 2^96)^2 expresses token1 per token0. Which side is which decides
        // whether we multiply or divide, so it is read rather than assumed.
        bool gasTokenIsToken0 = IUniswapV3Pool(pool).token0() == gasToken;

        // Split the shift to keep the intermediate inside 256 bits: sqrtPriceX96 is ~2^101 here,
        // and squaring it directly overflows.
        uint256 priceX96 = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 96;

        return gasTokenIsToken0
            ? (gasFeeInGasToken * priceX96) >> 96  // PC per gas token
            : (gasFeeInGasToken << 96) / priceX96;
    }

    /// @notice The `maxPCForGas` to send: spot cost with headroom for fee, slippage and drift.
    function budget(address gasToken, uint256 gasFeeInGasToken) internal view returns (uint256) {
        return spotCost(gasToken, gasFeeInGasToken) * HEADROOM_MULTIPLE;
    }
}
