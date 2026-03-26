// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

library UniswapPositionValueHelper {
    /// @param sqrtRatioX96  QX96{sqrt(tok1/tok0)} current pool sqrt price
    /// @param tickLower     {tick} lower bound of the position range
    /// @param tickUpper     {tick} upper bound of the position range
    /// @param liquidity     {liq} position liquidity
    /// @return amount0      {tok0} token0 principal amount
    /// @return amount1      {tok1} token1 principal amount
    function principal(uint160 sqrtRatioX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
    }

    /// @param feeGrowthInside0X128     QX128{tok0/liq} current cumulative fee growth inside range for token0
    /// @param feeGrowthInside1X128     QX128{tok1/liq} current cumulative fee growth inside range for token1
    /// @param feeGrowthInside0LastX128 QX128{tok0/liq} last-recorded fee growth inside range for token0
    /// @param feeGrowthInside1LastX128 QX128{tok1/liq} last-recorded fee growth inside range for token1
    /// @param liquidity                {liq} position liquidity
    /// @return amount0                 {tok0} token0 fees owed
    /// @return amount1                 {tok1} token1 fees owed
    function feesOwed(
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        amount0 = feesOwed(feeGrowthInside0X128, feeGrowthInside0LastX128, liquidity);
        amount1 = feesOwed(feeGrowthInside1X128, feeGrowthInside1LastX128, liquidity);
    }

    /// @param feeGrowthInsideX128     QX128{tok/liq} current cumulative fee growth inside range
    /// @param feeGrowthInsideLastX128 QX128{tok/liq} last-recorded fee growth inside range
    /// @param liquidity               {liq} position liquidity
    /// @return                        {tok} fees owed (tok0 or tok1 depending on caller context)
    function feesOwed(uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        // {tok} = QX128{tok/liq} * {liq} / Q128  (overflow in subtraction is protocol-correct wrapping)
        // calculate accumulated fees. overflow in the subtraction of fee growth is expected
        unchecked {
            return FullMath.mulDiv(feeGrowthInsideX128 - feeGrowthInsideLastX128, liquidity, FixedPoint128.Q128);
        }
    }
}
