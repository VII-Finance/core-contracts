// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IUniswapV3FlashCallback} from "lib/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract FeeDonator is IUniswapV3FlashCallback, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    address public pool;
    IPoolManager public poolManager;
    PoolKey public poolKey;

    constructor(address _pool, address _poolManager, PoolKey memory _poolKey) {
        pool = _pool;
        poolManager = IPoolManager(_poolManager);
        poolKey = _poolKey;
    }

    function isNonZeroLiquidity(bool isV3) public view returns (bool) {
        uint128 liquidity;
        if (isV3) {
            liquidity = IUniswapV3Pool(pool).liquidity();
        } else {
            liquidity = poolManager.getLiquidity(poolKey.toId());
        }
        return liquidity > 0;
    }

    function donate(uint256 amount0, uint256 amount1, bool isV3) external {
        if (isV3) {
            //the flashloan amounts are zero so the fees are zero that means any additional amount is donated to liquidity providers
            IUniswapV3Pool(pool).flash(address(this), 0, 0, abi.encode(amount0, amount1));
        } else {
            poolManager.unlock(abi.encode(amount0, amount1));
        }
    }

    function uniswapV3FlashCallback(uint256, uint256, bytes calldata data) external override {
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));
        if (amount0 > 0) {
            IERC20(IUniswapV3Pool(pool).token0()).safeTransfer(pool, amount0);
        }
        if (amount1 > 0) {
            IERC20(IUniswapV3Pool(pool).token1()).safeTransfer(pool, amount1);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));

        if (amount0 > 0 || amount1 > 0) {
            poolManager.donate(poolKey, amount0, amount1, "");

            if (amount0 > 0) {
                poolManager.sync(poolKey.currency0);
                poolKey.currency0.transfer(address(poolManager), amount0);
                poolManager.settle();
            }

            if (amount1 > 0) {
                poolManager.sync(poolKey.currency1);
                poolKey.currency1.transfer(address(poolManager), amount1);
                poolManager.settle();
            }
        }

        return "";
    }
}
