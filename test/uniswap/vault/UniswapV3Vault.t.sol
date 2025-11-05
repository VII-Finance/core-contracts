// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVaultTest} from "test/uniswap/vault/BaseVault.t.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {UniswapV3Vault} from "src/uniswap/vault/UniswapV3Vault.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";

// Mock wrapper for testing - defined inline like in UniswapV3Wrapper.t.sol
contract MockUniswapV3Wrapper is UniswapV3Wrapper {
    constructor(address _evc, address _positionManager, address _oracle, address _unitOfAccount, address _pool)
        UniswapV3Wrapper(_evc, _positionManager, _oracle, _unitOfAccount, _pool)
    {}
}

contract UniswapV3VaultTest is BaseVaultTest {
    // V3-specific variables
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;
    ISwapRouter swapRouter;
    IUniswapV3Pool pool;
    IUniswapV3Factory factory;
    int24 tickSpacing;

    function deployVault() internal override returns (BaseVault) {
        return new UniswapV3Vault(wrapper, IERC20(Addresses.USDT));
    }

    //copied over from test/uniswap/UniswapV3Wrapper.t.sol
    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(Addresses.NON_FUNGIBLE_POSITION_MANAGER);
        swapRouter = ISwapRouter(Addresses.SWAP_ROUTER);
        fee = 100; // 0.01% fee
        factory = IUniswapV3Factory(nonFungiblePositionManager.factory());
        tickSpacing = factory.feeAmountTickSpacing(fee);
        pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        ERC721WrapperBase uniswapV3Wrapper = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(pool)
        );

        mintPositionHelper =
            new UniswapMintPositionHelper(address(evc), address(nonFungiblePositionManager), address(0));

        return uniswapV3Wrapper;
    }
}
