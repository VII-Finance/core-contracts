// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUniswapV3Wrapper {
    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IUniswapV4Wrapper {
    function poolId() external view returns (bytes32);
    function poolManager() external view returns (address);
    function weth() external view returns (address);
    function currency0() external view returns (address);
    function currency1() external view returns (address);
    function poolKey()
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

struct UniswapWrapperInfo {
    address wrapper;
    address underlying;
    address oracle;
    address unitOfAccount;
    uint8 decimals; // D{unitOfAccountDecimals} decimal count of the unit of account token
    address token0;
    string token0Name;
    string token0Symbol;
    uint8 token0Decimals; // D{token0Decimals} decimal count of token0
    address token1;
    string token1Name;
    string token1Symbol;
    uint8 token1Decimals; // D{token1Decimals} decimal count of token1
    uint24 fee; // {bps} pool fee tier (e.g. 3000 = 0.3%)
    address pool;
    bytes32 poolId;
    address weth;
    bool isV4;
}

/// @title UniswapWrapperLens
/// @notice Read-only lens contract for fetching UniswapV3Wrapper and UniswapV4Wrapper state in a single call.
/// @dev Detects V3 vs V4 by checking if the wrapper has a `poolManager()` function.
contract UniswapWrapperLens {
    function getWrapperInfo(address wrapper) external view returns (UniswapWrapperInfo memory info) {
        IERC721WrapperBase base = IERC721WrapperBase(wrapper);

        info.wrapper = wrapper;
        info.underlying = address(base.underlying());
        info.oracle = address(base.oracle());
        info.unitOfAccount = base.unitOfAccount();
        info.decimals = _getDecimals(info.unitOfAccount); // D{unitOfAccountDecimals} decimal count of the unit of account

        // Detect V4 by checking for poolManager()
        bool isV4 = _hasPoolManager(wrapper);
        info.isV4 = isV4;

        if (isV4) {
            IUniswapV4Wrapper v4 = IUniswapV4Wrapper(wrapper);
            info.poolId = v4.poolId();
            info.weth = v4.weth();

            // Get token addresses from currency fields, replacing address(0) with weth for native ETH
            address rawCurrency0 = v4.currency0();
            address rawCurrency1 = v4.currency1();
            info.token0 = rawCurrency0 == address(0) ? info.weth : rawCurrency0;
            info.token1 = rawCurrency1 == address(0) ? info.weth : rawCurrency1;

            // Get fee from poolKey
            (,, uint24 fee,,) = v4.poolKey();
            // fee: {bps} pool fee tier (e.g. 3000 = 0.3%) → stored in info.fee: {bps}
            info.fee = fee;

            // V4 has no pool address
            info.pool = address(0);
        } else {
            IUniswapV3Wrapper v3 = IUniswapV3Wrapper(wrapper);
            info.token0 = v3.token0();
            info.token1 = v3.token1();
            info.fee = v3.fee(); // {bps} propagated from UniswapV3Wrapper.fee state variable
            info.pool = address(v3.pool());
            info.poolId = bytes32(0);
            info.weth = address(0);
        }

        // Fetch token metadata
        info.token0Name = _getName(info.token0);
        info.token0Symbol = _getSymbol(info.token0);
        info.token0Decimals = _getDecimals(info.token0); // D{token0Decimals} decimal count of token0
        info.token1Name = _getName(info.token1);
        info.token1Symbol = _getSymbol(info.token1);
        info.token1Decimals = _getDecimals(info.token1); // D{token1Decimals} decimal count of token1
    }

    function _hasPoolManager(address wrapper) internal view returns (bool) {
        (bool success,) = wrapper.staticcall(abi.encodeWithSelector(IUniswapV4Wrapper.poolManager.selector));
        return success;
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _getName(address token) internal view returns (string memory) {
        try IERC20Metadata(token).name() returns (string memory n) {
            return n;
        } catch {
            return "";
        }
    }

    function _getSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "";
        }
    }
}
