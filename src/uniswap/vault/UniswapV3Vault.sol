// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

contract UniswapV3Vault is BaseVault {
    IUniswapV3Pool public immutable pool;
    uint24 public immutable fee;

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault, uint256 _targetLeverage)
        BaseVault(_wrapper, _asset, _borrowVault, _targetLeverage)
    {
        pool = UniswapV3Wrapper(address(_wrapper)).pool();
        fee = UniswapV3Wrapper(address(_wrapper)).fee();
        tickSpacing = pool.tickSpacing();
    }

    function _getTokens(address _wrapper) public view virtual override returns (address, address) {
        return (UniswapV3Wrapper(_wrapper).token0(), UniswapV3Wrapper(_wrapper).token1());
    }

    function isTokenBeingBorrowedToken0() internal view override returns (bool) {
        return borrowToken < asset();
    }

    function getCurrentSqrtPriceX96() public view override returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = pool.slot0();
    }

    function _mintPosition(uint256 token0Amount, uint256 token1Amount, uint128)
        internal
        override
        returns (uint256 newTokenId)
    {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: isTokenBeingBorrowedToken0() ? borrowToken : address(asset()),
            token1: isTokenBeingBorrowedToken0() ? address(asset()) : borrowToken,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: token0Amount > 0 ? token0Amount - 1 : 0,
            amount1Min: token1Amount > 0 ? token1Amount - 1 : 0,
            recipient: address(wrapper),
            deadline: block.timestamp
        });

        (newTokenId,,,) = INonfungiblePositionManager(address(positionManager)).mint(params);
    }

    function _increaseLiquidity(uint256 token0Amount, uint256 token1Amount, uint128) internal override {
        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: token0Amount,
                amount1Desired: token1Amount,
                amount0Min: token0Amount > 0 ? token0Amount - 1 : 0,
                amount1Min: token1Amount > 0 ? token1Amount - 1 : 0,
                deadline: block.timestamp
            });

        INonfungiblePositionManager(address(positionManager)).increaseLiquidity(params);
    }

    function _decreaseLiquidity(uint256 token0Amount, uint256 token1Amount, uint128 liquidity) internal override {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: token0Amount > 0 ? token0Amount - 1 : 0,
                amount1Min: token1Amount > 0 ? token1Amount - 1 : 0,
                deadline: block.timestamp
            });

        (uint256 amount0, uint256 amount1) =
            INonfungiblePositionManager(address(positionManager)).decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: uint128(amount0), amount1Max: uint128(amount1)
        });

        INonfungiblePositionManager(address(positionManager)).collect(collectParams);
    }

    /// @dev Collects ALL accrued fees + any owed tokens from the current position.
    function _collectAll() internal override {
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });
        INonfungiblePositionManager(address(positionManager)).collect(collectParams);
    }

    function _getCurrentLiquidity() internal view override returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(address(positionManager)).positions(tokenId);
    }
}
