// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC721WrapperBase, UniswapPositionValueHelper, UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IMockUniswapWrapper} from "test/helpers/IMockUniswapWrapper.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

///This contract should follow IMockUniswapWrapper interface to make sure invariant tests work correctly
contract MockUniswapV3Wrapper is UniswapV3Wrapper {
    using SafeCast for uint256;

    constructor(address _evc, address _positionManager, address _oracle, address _unitOfAccount, address _pool)
        UniswapV3Wrapper(_evc, _positionManager, _oracle, _unitOfAccount, _pool)
    {}

    function syncFeesOwned(uint256 tokenId) external returns (uint256 actualFees0, uint256 actualFees1) {
        (,,,,,,,,,, uint256 tokensOwed0Before, uint256 tokensOwed1Before) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);

        INonfungiblePositionManager(address(underlying))
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId, recipient: address(0), amount0Max: 1, amount1Max: 1
                })
            );

        (,,,,,,,,,, uint256 tokensOwed0After, uint256 tokensOwed1After) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);

        actualFees0 = (tokensOwed0After - tokensOwed0Before);
        actualFees1 = (tokensOwed1After - tokensOwed1Before);
    }

    function getFeeGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        return _getFeeGrowthInside(tickLower, tickUpper);
    }

    function totalPositionValue(uint160 sqrtRatioX96, uint256 tokenId)
        external
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        return _totalPositionValue(sqrtRatioX96, tokenId);
    }

    function total(uint256 tokenId) external view returns (uint256 amount0Total, uint256 amount1Total) {
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        return _totalPositionValue(sqrtRatioX96, tokenId);
    }

    function pendingFees(uint256 tokenId) public view returns (uint256 totalPendingFees0, uint256 totalPendingFees1) {
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        (
            ,,,,,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(tickLower, tickUpper);

        //fees that are not accounted for yet
        (uint256 feesOwed0, uint256 feesOwed1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );

        totalPendingFees0 = feesOwed0 + tokensOwed0;
        totalPendingFees1 = feesOwed1 + tokensOwed1;
    }

    function tokensOwed(uint256 tokenId) external view returns (uint128 fees0Owed, uint128 fees1Owed) {
        (,,,,,,,,,, uint128 tokensOwed0, uint128 tokensOwed1) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        fees0Owed = tokensOwed0;
        fees1Owed = tokensOwed1;
    }

    //given unwrap amount, the UniswapV3Wrapper will calculate the liquidity to be removed
    //if the liquidity to be removed is zero, call to the UniswapV3Pool will fails
    //even if liquidity to be removed is non-zero, it may still result in amount0 and amount1 being zero
    //which will make the collect call fail as well
    function isZeroLiquidityDecreased(uint256 tokenId, uint256 unwrapAmount) public view returns (bool) {
        // in NonFungiblePositionManager, decrease liquidity fails if liquidity being removed is zero
        if (unwrapAmount == 0) {
            return true;
        }

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        uint128 liquidityToRemove = uint128(proportionalShare(liquidity, unwrapAmount, totalSupply(tokenId)));

        if (liquidityToRemove == 0) {
            return true;
        }

        // also make sure amount0 and amount1 resulting from liquidityToRemove is not zero either
        // call to collect it will fail otherwise
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        (uint256 amount0, uint256 amount1) =
            UniswapPositionValueHelper.principal(sqrtRatioX96, tickLower, tickUpper, liquidityToRemove);

        //even if amount0 and amount1 are both zero, if user's share of pending fees is non-zero, collect will still succeed
        (uint256 totalPendingFees0, uint256 totalPendingFees1) = pendingFees(tokenId);

        return (amount0 == 0 && amount1 == 0
                && proportionalShare(totalPendingFees0, unwrapAmount, totalSupply(tokenId)) == 0
                && proportionalShare(totalPendingFees1, unwrapAmount, totalSupply(tokenId)) == 0);
    }

    struct Local {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint160 sqrtRatioX96;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
    }

    function calculateExactedValueOfTokenIdAfterUnwrap(
        uint256 tokenId,
        uint256 unwrapAmount,
        uint256 balanceBeforeUnwrap
    ) public view returns (uint256) {
        uint256 totalAmountInUnitOfAccount;
        {
            Local memory local;
            (
                ,,,,,
                local.tickLower,
                local.tickUpper,
                local.liquidity,
                local.feeGrowthInside0LastX128,
                local.feeGrowthInside1LastX128,
                local.tokensOwed0,
                local.tokensOwed1
            ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

            uint128 liquidityToRemove =
                proportionalShare(local.liquidity, unwrapAmount, totalSupply(tokenId)).toUint128();

            local.liquidity -= liquidityToRemove;

            (local.sqrtRatioX96,,,,,,) = pool.slot0();

            (uint256 amount0Principal, uint256 amount1Principal) = UniswapPositionValueHelper.principal(
                local.sqrtRatioX96, local.tickLower, local.tickUpper, local.liquidity
            );

            (local.feeGrowthInside0X128, local.feeGrowthInside1X128) =
                _getFeeGrowthInside(local.tickLower, local.tickUpper);

            //fees that are not accounted for yet
            (uint256 feesOwed0, uint256 feesOwed1) = UniswapPositionValueHelper.feesOwed(
                local.feeGrowthInside0X128,
                local.feeGrowthInside1X128,
                local.feeGrowthInside0LastX128,
                local.feeGrowthInside1LastX128,
                local.liquidity
            );

            //remove proportional share from tokens owed as well
            local.tokensOwed0 -= proportionalShare(local.tokensOwed0, unwrapAmount, totalSupply(tokenId)).toUint128();
            local.tokensOwed1 -= proportionalShare(local.tokensOwed1, unwrapAmount, totalSupply(tokenId)).toUint128();

            totalAmountInUnitOfAccount = getQuote(amount0Principal + feesOwed0 + local.tokensOwed0, token0)
                + getQuote(amount1Principal + feesOwed1 + local.tokensOwed1, token1);
        }

        //avoid division by zero
        if (totalSupply(tokenId) == unwrapAmount) {
            return 0;
        }
        return proportionalShare(
            totalAmountInUnitOfAccount, balanceBeforeUnwrap - unwrapAmount, totalSupply(tokenId) - unwrapAmount
        );
    }

    //All of tests uses the spot price from the pool instead of the oracle
    function getSqrtRatioX96(address, address, uint256, uint256) public view override returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96,,,,,,) = pool.slot0();
    }

    function getSqrtRatioX96FromOracle(address token0, address token1, uint256 unit0, uint256 unit1)
        public
        view
        returns (uint160 sqrtRatioX96)
    {
        return super.getSqrtRatioX96(token0, token1, unit0, unit1);
    }
}
