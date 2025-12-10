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
        return previewUnwrap(tokenId, sqrtRatioX96, totalSupply(tokenId));
    }

    function total(uint256 tokenId) external view returns (uint256 amount0Total, uint256 amount1Total) {
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        return previewUnwrap(tokenId, sqrtRatioX96, totalSupply(tokenId));
    }

    function pendingFees(uint256 tokenId) external view returns (uint256 totalPendingFees0, uint256 totalPendingFees1) {
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

    struct Local {
        uint160 sqrtRatioX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint256 feeGrowthInside0X128;
        uint256 feeGrowthInside1X128;
        uint256 totalSupplyOfTokenId;
        uint256 pendingFees0;
        uint256 pendingFees1;
        uint256 amount0;
        uint256 amount1;
    }

    function calculateExactedValueOfTokenIdAfterUnwrap(
        uint256 tokenId,
        uint256 unwrapAmount,
        uint256 balanceBeforeUnwrap
    ) public view returns (uint256) {
        // this should be same as previewUnwrap except it should assume that totalSupply has reduced by unwrapAmount
        // our of total liquidity proportional liquidity has been removed
        // also proportional tokensOwed has been removed as well

        if (totalSupply(tokenId) == unwrapAmount) {
            //if we are unwrapping the entire tokenId, then the value after unwrap is zero
            return 0;
        }
        Local memory local;
        (local.sqrtRatioX96,,,,,,) = pool.slot0();
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

        // to be exact on how much tokensOwed to reduce by, we calculate total pending fees
        // and then reduce the tokenOwed by pendingFees + tokensOwed - proportional (pendingFees + tokensOwed) for unwrapAmount
        (local.feeGrowthInside0X128, local.feeGrowthInside1X128) = _getFeeGrowthInside(local.tickLower, local.tickUpper);
        // fees that are not accounted for yet for the entire tokenId
        (local.pendingFees0, local.pendingFees1) = UniswapPositionValueHelper.feesOwed(
            local.feeGrowthInside0X128,
            local.feeGrowthInside1X128,
            local.feeGrowthInside0LastX128,
            local.feeGrowthInside1LastX128,
            local.liquidity
        );

        local.tokensOwed0 = (local.pendingFees0.toUint128() + local.tokensOwed0)
            - proportionalShare(local.pendingFees0 + local.tokensOwed0, unwrapAmount, totalSupply(tokenId)).toUint128();
        local.tokensOwed1 = (local.pendingFees1.toUint128() + local.tokensOwed1)
            - proportionalShare(local.pendingFees1 + local.tokensOwed1, unwrapAmount, totalSupply(tokenId)).toUint128();

        local.feeGrowthInside0LastX128 = local.feeGrowthInside0X128;
        local.feeGrowthInside1LastX128 = local.feeGrowthInside1X128;

        local.liquidity -= proportionalShare(uint256(local.liquidity), unwrapAmount, totalSupply(tokenId)).toUint128();

        local.totalSupplyOfTokenId = totalSupply(tokenId) - unwrapAmount;

        // principal amount but only corresponding to the unwrap amount
        (local.amount0, local.amount1) = UniswapPositionValueHelper.principal(
            local.sqrtRatioX96,
            local.tickLower,
            local.tickUpper,
            proportionalShare(uint256(local.liquidity), balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId)
                .toUint128()
        );
        // we know that the pending fees will be zero here because it was just realized in the last unwrap. we still calculate it even though we know it's zero

        (local.pendingFees0, local.pendingFees1) = UniswapPositionValueHelper.feesOwed(
            local.feeGrowthInside0X128,
            local.feeGrowthInside1X128,
            local.feeGrowthInside0LastX128,
            local.feeGrowthInside1LastX128,
            local.liquidity
        );

        // we take the proportional share of the pending fees and the tokens owed + principal
        local.amount0 += proportionalShare(
            local.pendingFees0 + local.tokensOwed0, balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId
        ); //conditional to avoid division by zero
        local.amount1 += proportionalShare(
            local.pendingFees1 + local.tokensOwed1, balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId
        ); //conditional to avoid division by zero if totalSupplyOfTokenId is zero
        return getQuote(local.amount0, token0) + getQuote(local.amount1, token1);
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
