// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVaultTest} from "test/uniswap/vault/BaseVault.t.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {UniswapV4Vault} from "src/uniswap/vault/UniswapV4Vault.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";

contract UniswapV4VaultTest is BaseVaultTest {
    // V4-specific variables
    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;
    bool public constant TEST_NATIVE_ETH = true;

    function setUp() public override {
        BaseVaultTest.setUp();
        initialAmount = 1e18;
    }

    function deployVault() internal override returns (BaseVault) {
        return new UniswapV4Vault(wrapper, IERC20(Addresses.WETH), eVault);
    }

    //copied over from test/uniswap/UniswapV3Wrapper.t.sol
    function deployWrapper() internal override returns (ERC721WrapperBase) {
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 10, //0.001% fee
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        if (TEST_NATIVE_ETH) {
            currency0 = Currency.wrap(address(0)); //use native ETH as currency0
            currency1 = Currency.wrap(address(Addresses.USDC));

            token0 = Addresses.WETH;
            token1 = Addresses.USDC;

            poolKey = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: 500, //0.05% fee
                tickSpacing: 10,
                hooks: IHooks(address(0))
            });

            // poolId = 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27
        }

        poolId = poolKey.toId();

        ///@dev A weird coincidence that happened here was that this wrapper was getting deployed at this address: 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
        ///which actually has some ETH balance on ethereum mainnet. It broke some accounting in the tests and took me a while to figure out why. As a workaround I simply added a salt to the constructor
        ERC721WrapperBase uniswapV4Wrapper = new MockUniswapV4Wrapper{salt: bytes32(uint256(1))}(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, Addresses.WETH
        );
        mintPositionHelper = new UniswapMintPositionHelper(
            address(evc), Addresses.NON_FUNGIBLE_POSITION_MANAGER, address(positionManager)
        );

        return uniswapV4Wrapper;
    }
}
