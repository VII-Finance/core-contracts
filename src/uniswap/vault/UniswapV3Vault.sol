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

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault)
        BaseVault(_wrapper, _asset, _borrowVault)
    {
        pool = UniswapV3Wrapper(address(_wrapper)).pool();
        fee = UniswapV3Wrapper(address(_wrapper)).fee();
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

    function assetsReceiver() internal view override returns (address) {
        return address(this);
    }

    function _mintPosition(uint256 token0Amount, uint256 token1Amount, uint128)
        internal
        override
        returns (uint256 tokenId)
    {
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: isTokenBeingBorrowedToken0() ? borrowToken : address(asset()),
            token1: isTokenBeingBorrowedToken0() ? address(asset()) : borrowToken,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: token0Amount - 1,
            amount1Min: token1Amount - 1,
            recipient: address(wrapper),
            deadline: block.timestamp
        });

        (tokenId,,,) = INonfungiblePositionManager(address(positionManager)).mint(params);
    }

    function calculateAmounts(uint256 tokenId) public view override returns (uint256, uint256) {}
}
