// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {
    INonfungiblePositionManager,
    IERC721Enumerable
} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";

/// @title EVC aware collateral only vault for Uniswap V3 liquidity positions
/// @author VII Finance
/// @notice This contract allows EVK vaults to accept Uniswap V3 liquidity positions as collateral
contract UniswapV3Wrapper is ERC721WrapperBase {
    IUniswapV3Pool public immutable pool;
    IUniswapV3Factory public immutable factory;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint256 public immutable unit0;
    uint256 public immutable unit1;

    error InvalidPoolAddress();

    using SafeCast for uint256;

    constructor(
        address _evc,
        address _nonFungiblePositionManager,
        address _oracle,
        address _unitOfAccount,
        address _poolAddress
    ) ERC721WrapperBase(_evc, _nonFungiblePositionManager, _oracle, _unitOfAccount) {
        pool = IUniswapV3Pool(_poolAddress);
        fee = pool.fee();
        address token0_ = pool.token0();
        address token1_ = pool.token1();

        token0 = token0_;
        token1 = token1_;

        unit0 = 10 ** _getDecimals(token0_);
        unit1 = 10 ** _getDecimals(token1_);

        factory = IUniswapV3Factory(INonfungiblePositionManager(address(underlying)).factory());
    }

    /// @notice Validates that the position belongs to the pool that this wrapper is associated with
    /// @param tokenId The token ID to validate
    function validatePosition(uint256 tokenId) public view override {
        (,, address token0OfTokenId, address token1OfTokenId, uint24 feeOfTokenId,,,,,,,) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        address poolOfTokenId = factory.getPool(token0OfTokenId, token1OfTokenId, feeOfTokenId);
        if (poolOfTokenId != address(pool)) revert InvalidPoolAddress();
    }

    /// @notice Unwraps a position by removing proportional liquidity and send the resulting tokens and proportional fees to the recipient
    /// @param to The recipient address
    /// @param tokenId The position token ID
    /// @param totalSupplyOfTokenId The total supply of the token ID
    /// @param amount The proportion of the position to unwrap
    /// @param extraData Additional parameters for the unwrap operation (uint256 amount0Min, uint256 amount1Min, uint256 deadline encoded)
    function _unwrap(
        address to,
        uint256 tokenId,
        uint256 totalSupplyOfTokenId,
        uint256 amount,
        bytes calldata extraData
    ) internal override {
        uint256 amount0;
        uint256 amount1;
        {
            (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

            (amount0, amount1) = _decreaseLiquidity(
                tokenId, proportionalShare(uint256(liquidity), amount, totalSupplyOfTokenId).toUint128(), extraData
            );
        }

        (,,,,,,,,,, uint256 tokensOwed0, uint256 tokensOwed1) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);

        //amount0 and amount1 is the part of the liquidity
        //token0Owed - amount0 and token1Owed - amount1 are the total fees (the principal is always collected in the same tx). part of the fees needs to be sent to the recipient as well

        INonfungiblePositionManager(address(underlying))
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: to,
                    amount0Max: (amount0 + proportionalShare((tokensOwed0 - amount0), amount, totalSupplyOfTokenId))
                    .toUint128(),
                    amount1Max: (amount1 + proportionalShare((tokensOwed1 - amount1), amount, totalSupplyOfTokenId))
                    .toUint128()
                })
            );
    }

    function _settleFullUnwrap(uint256 tokenId, address to) internal override {}

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, bytes calldata extraData)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        (uint256 amount0Min, uint256 amount1Min, uint256 deadline) =
            extraData.length == 96 ? abi.decode(extraData, (uint256, uint256, uint256)) : (0, 0, block.timestamp);

        (amount0, amount1) = INonfungiblePositionManager(address(underlying))
            .decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                })
            );
    }

    /// @dev Returns the last tokenId owned by this contract from the NonFungiblePositionManager,
    ///      which implements ERC721Enumerable.
    /// @notice This function assumes that a user mints an NFT, sends it to this contract,
    ///         and then calls skim in the same tx. If any unwrap occurs in between, this logic may not work as expected.
    function getTokenIdToSkim() public view override returns (uint256) {
        uint256 totalTokensOwnedByThis = IERC721Enumerable(address(underlying)).balanceOf(address(this));
        return IERC721Enumerable(address(underlying)).tokenOfOwnerByIndex(address(this), totalTokensOwnedByThis - 1);
    }

    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view override returns (uint256) {
        uint160 sqrtRatioX96 = getSqrtRatioX96(token0, token1, unit0, unit1);

        (uint256 amount0, uint256 amount1) = previewUnwrap(tokenId, sqrtRatioX96, amount);

        uint256 amount0InUnitOfAccount = getQuote(amount0, token0);
        uint256 amount1InUnitOfAccount = getQuote(amount1, token1);

        return amount0InUnitOfAccount + amount1InUnitOfAccount;
    }

    struct PositionInfo {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function previewUnwrap(uint256 tokenId, uint160 sqrtRatioX96, uint256 unwrapAmount)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PositionInfo memory position;
        (
            ,,,,,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

        uint256 totalSupplyOfTokenId = totalSupply(tokenId);

        // principal amount but only corresponding to the unwrap amount
        (amount0, amount1) = UniswapPositionValueHelper.principal(
            sqrtRatioX96,
            position.tickLower,
            position.tickUpper,
            proportionalShare(uint256(position.liquidity), unwrapAmount, totalSupplyOfTokenId).toUint128()
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            _getFeeGrowthInside(position.tickLower, position.tickUpper);
        // fees that are not accounted for yet for the entire tokenId
        (uint256 pendingFees0, uint256 pendingFees1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );

        // we take the proportional share of the pending fees and the tokens owed + principal
        amount0 += proportionalShare(pendingFees0 + position.tokensOwed0, unwrapAmount, totalSupplyOfTokenId);
        amount1 += proportionalShare(pendingFees1 + position.tokensOwed1, unwrapAmount, totalSupplyOfTokenId);
    }

    function _getFeeGrowthInside(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,,,,) = pool.slot0();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        // calculate fee growth inside. the calculation relied on unchecked arithmetic
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
                uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }
}
