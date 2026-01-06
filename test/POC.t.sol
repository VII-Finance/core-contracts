// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {BaseSetup, INonfungiblePositionManager} from "test/invariant/BaseSetup.sol";

contract SamplePOC is Test, BaseSetup {
    function setUp() public override {
        // All necessary setup is done locally.
        // Uniswap V4, Uniswap V3, and EthereumVaultConnector are deployed.
        // A pool is initialized in the V4 PoolManager and corresponding UniswapV4Wrapper is deployed.
        // A pool is created using UniswapV3Factory and corresponding UniswapV3Wrapper is deployed.
        // Two Euler vaults are created using Euler Vault Kit that accept the UniswapV3Wrapper and UniswapV4Wrapper as collateral.
        // Both Euler vaults use the same oracleRouter as they should and the oracleRouter is properly configured to return price = 1 USD for both wrappers.
        // UniswapMintPositionHelper can be used to mint positions in both V3 and V4 pools.
        super.setUp();
    }

    function test_sample() public {}

    // Here's an attack vector that we wanted to highlight.
    // In Uniswap V3, where NonFungiblePositionManager is used to represent LP positions as NFTs,
    // anyone can increase the liquidity of a position even if the NFT is not owned by them.
    // An attacker can mint an LP position, wrap it using UniswapV3Wrapper, partially unwrap all but 1 wei of ERC6909 tokens.
    // At this point, the NFT will still be held by the UniswapV3Wrapper, but the attacker can now increase the liquidity of the position
    // and enable it as collateral.
    // So, this 1 wei of ERC6909 token now represents a large amount of collateral.
    // They can borrow against this collateral and take advantage of a rounding error if we missed anything.
    // We round up in liquidator's favor to avoid any issues with liquidator receiving less than expected, but there can be something we missed.
    // You can pick this up from where we left off and try to exploit this vector.
    // UniswapV4Wrapper doesn't have this potential issue as PositionManager doesn't allow anyone to increase liquidity of a position they don't own.
    // Users have to unwrap the entire position to get back the NFT and then they can increase liquidity, and when they wrap again, they always get minted FULL_AMOUNT of ERC6909 tokens.
    function test_1_wei_worth_a_lot_attack_vector() public {
        address attacker = makeAddr("attacker");
        address liquidator = makeAddr("liquidator");

        // Deal tokens to attacker.
        deal(address(tokenA), attacker, 1000000 * 10 ** 18);
        deal(address(tokenB), attacker, 1000000 * 10 ** 18);

        // Attacker mints a small LP position.
        vm.startPrank(attacker);
        tokenA.approve(address(nonFungiblePositionManager), type(uint256).max);
        tokenB.approve(address(nonFungiblePositionManager), type(uint256).max);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: fee,
            tickLower: -60,
            tickUpper: 60,
            amount0Desired: 100 * 10 ** 18,
            amount1Desired: 100 * 10 ** 18,
            amount0Min: 0,
            amount1Min: 0,
            recipient: attacker,
            deadline: block.timestamp + 1000
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonFungiblePositionManager.mint(params);

        // Attacker wraps the position.
        nonFungiblePositionManager.approve(address(uniswapV3Wrapper), tokenId);
        uniswapV3Wrapper.wrap(tokenId, attacker);

        // Attacker partially unwraps all but 1 wei of ERC6909 tokens.
        uint256 totalSupply = uniswapV3Wrapper.totalSupply(tokenId);
        uint256 unwrapAmount = totalSupply - 1;
        uniswapV3Wrapper.unwrap(attacker, tokenId, attacker, unwrapAmount, "");

        // Now attacker has 1 wei of ERC6909 token representing the large position.
        assertEq(uniswapV3Wrapper.balanceOf(attacker, tokenId), 1);

        // Attacker increases liquidity to make the position large.
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: 100000 * 10 ** 18,
                amount1Desired: 100000 * 10 ** 18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1000
            });

        nonFungiblePositionManager.increaseLiquidity(increaseParams);


        // Enable the tokenId as collateral.
        uniswapV3Wrapper.enableTokenIdAsCollateral(tokenId);

        // Attacker now has a large amount of collateral represented by 1 wei of ERC6909 token.
        uint256 collateralValue = uniswapV3Wrapper.balanceOf(attacker);

        assertEq(collateralValue, 200000 * 10 ** 18, "Collateral value should be significantly larger than 1 wei");

        // Complete this attack by finding a rounding error to exploit...
    }
}
