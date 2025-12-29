// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

library UniswapPositionValueHelper {
    function principal(uint160 sqrtRatioX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
    }

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

    function feesOwed(uint256 feeGrowthInsideX128, uint256 feeGrowthInsideLastX128, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        // calculate accumulated fees. overflow in the subtraction of fee growth is expected
        unchecked {
            return FullMath.mulDiv(feeGrowthInsideX128 - feeGrowthInsideLastX128, liquidity, FixedPoint128.Q128);
        }
    }
}
