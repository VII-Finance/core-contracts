// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {ChainlinkInfrequentOracle} from "lib/euler-price-oracle/src/adapter/chainlink/ChainlinkInfrequentOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";

contract CreateV4WrappersScript is Script {
    IEulerRouter eulerRouter = IEulerRouter(0x4267e3012799A804738A73A2Fa9eB4fD441ceEFF);
    address unitOfAccount = 0x0000000000000000000000000000000000000348;
    IHooks yieldHarvestingHook = IHooks(0x777ef319C338C6ffE32A2283F603db603E8F2A80);

    address asset0 = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; //USDC
    address asset1 = 0x9151434b16b9763660705744891fA906F660EcC5; //USDT0

    address vaultWrapper0 = 0x9C383Fa23Dd981b361F0495Ba53dDeB91c750064; //VII-eUSDC-5
    address vaultWrapper1 = 0x7b793B1388e14F03e19dc562470e7D25B2Ae9b97; //VII-eUSDT0-2

    uint24 fee = 18;
    int24 tickSpacing = 1;

    function createChainlinkInfrequentOracle(address base, ChainlinkInfrequentOracle referenceOracle)
        internal
        returns (address)
    {
        ChainlinkInfrequentOracle oracleInstance = new ChainlinkInfrequentOracle(
            base, referenceOracle.quote(), referenceOracle.feed(), referenceOracle.maxStaleness()
        );
        return address(oracleInstance);
    }

    function run() public {
        // Create instances of the UniswapV4WrapperFactory
        UniswapV4WrapperFactory v4Factory = UniswapV4WrapperFactory(0x7777943712740f9877c95411FC0C606C524fc777);

        PoolKey memory vaultWrappersPoolKey = PoolKey({
            currency0: vaultWrapper0 < vaultWrapper1 ? Currency.wrap(vaultWrapper0) : Currency.wrap(vaultWrapper1),
            currency1: vaultWrapper0 < vaultWrapper1 ? Currency.wrap(vaultWrapper1) : Currency.wrap(vaultWrapper0),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: yieldHarvestingHook
        });

        vm.startBroadcast();

        (address uniswapV4Wrapper, address fixedPriceOracleUniswapV4Wrapper) =
            v4Factory.createUniswapV4Wrapper(address(eulerRouter), unitOfAccount, vaultWrappersPoolKey);

        //let's also deploy chainlinkInfrequentOracle as well
        address vaultWrapper0Oracle = createChainlinkInfrequentOracle(
            vaultWrapper0, ChainlinkInfrequentOracle(eulerRouter.getConfiguredOracle(asset0, unitOfAccount))
        );
        address vaultWrapper1Oracle = createChainlinkInfrequentOracle(
            vaultWrapper1, ChainlinkInfrequentOracle(eulerRouter.getConfiguredOracle(asset1, unitOfAccount))
        );

        //set the oracles
        eulerRouter.govSetConfig(vaultWrapper0, unitOfAccount, vaultWrapper0Oracle);
        eulerRouter.govSetConfig(vaultWrapper1, unitOfAccount, vaultWrapper1Oracle);

        eulerRouter.govSetConfig(uniswapV4Wrapper, unitOfAccount, fixedPriceOracleUniswapV4Wrapper);

        vm.stopBroadcast();
    }
}
