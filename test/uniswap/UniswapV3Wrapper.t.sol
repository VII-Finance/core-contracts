// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IPriceOracle} from "lib/euler-price-oracle/src/interfaces/IPriceOracle.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISwapRouter} from "lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {MockUniswapV3Wrapper} from "test/helpers/MockUniswapV3Wrapper.sol";
import {FeeDonator} from "test/helpers/FeeDonator.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract UniswapV3WrapperTest is Test, UniswapBaseTest {
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;
    ISwapRouter swapRouter;
    IUniswapV3Pool pool;
    IUniswapV3Factory factory;
    int24 tickSpacing;

    FeeDonator feeDonator;

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(Addresses.NON_FUNGIBLE_POSITION_MANAGER);
        swapRouter = ISwapRouter(Addresses.SWAP_ROUTER);
        fee = 100; // 0.01% fee
        factory = IUniswapV3Factory(nonFungiblePositionManager.factory());
        tickSpacing = factory.feeAmountTickSpacing(fee);
        pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        PoolKey memory poolKey;
        feeDonator = new FeeDonator(address(pool), address(0), poolKey);

        ERC721WrapperBase uniswapV3Wrapper = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(pool)
        );
        mintPositionHelper =
            new UniswapMintPositionHelper(address(evc), address(nonFungiblePositionManager), address(0));

        return uniswapV3Wrapper;
    }

    function setUp() public override {
        super.setUp();
        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(swapRouter), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(swapRouter), type(uint256).max);

        SafeERC20.forceApprove(IERC20(token0), address(mintPositionHelper), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(mintPositionHelper), type(uint256).max);

        (tokenId,,) = mintPosition(
            borrower,
            100 * unit0,
            100 * unit1,
            -887272, //minimum tick
            887272 //maximum tick
        );
    }

    function mintPosition(
        address owner,
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 tickLower,
        int24 tickUpper
    ) public returns (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) {
        startHoax(owner);
        deal(address(token0), borrower, amount0Desired * 2);
        deal(address(token1), borrower, amount1Desired * 2);

        (tokenIdMinted,, amount0, amount1) = mintPositionHelper.mintPosition(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp
            })
        );

        assertEq(IERC20(token0).balanceOf(address(mintPositionHelper)), 0);
        assertEq(IERC20(token1).balanceOf(address(mintPositionHelper)), 0);
    }

    function boundLiquidityParamsAndMint(LiquidityParams memory params)
        internal
        returns (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent)
    {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();

        params = createFuzzyLiquidityParams(params, tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        (tokenIdMinted, amount0Spent, amount1Spent) = mintPosition(
            borrower, estimatedAmount0Required, estimatedAmount1Required, params.tickLower, params.tickUpper
        );
    }

    function testGetSqrtRatioX96() public view {
        uint256 fixedDecimals = 10 ** 18;
        uint160 sqrtRatioX96FromOracle = MockUniswapV3Wrapper(address(wrapper))
            .getSqrtRatioX96FromOracle(address(token0), address(token1), unit0, unit1);

        uint256 sqrtPriceInFixed18Decimal = Math.mulDiv(sqrtRatioX96FromOracle, fixedDecimals, 1 << 96);
        uint256 priceInFixed18Decimal = Math.mulDiv(sqrtPriceInFixed18Decimal, sqrtPriceInFixed18Decimal, fixedDecimals);

        uint256 token0PerToken1InFixed18Decimal = Math.mulDiv(
            oracle.getQuote(unit0, token0, unitOfAccount), fixedDecimals, oracle.getQuote(unit1, token1, unitOfAccount)
        );

        assertApproxEqAbs(priceInFixed18Decimal, token0PerToken1InFixed18Decimal, 1e4);
    }

    function testWrapFailIfNotTheSamePoolAddress() public {
        //we know the first 10 tokenIds are not from the same pool
        for (uint256 i = 1; i < 10; i++) {
            startHoax(wrapper.underlying().ownerOf(i));
            wrapper.underlying().approve(address(wrapper), i);

            vm.expectRevert(UniswapV3Wrapper.InvalidPoolAddress.selector);
            wrapper.wrap(i, borrower);
        }
    }

    function testSkimV3() public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: -19999
        });
        (uint256 tokenId,,) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().transferFrom(borrower, address(wrapper), tokenId);

        startHoax(address(1));
        wrapper.skim(borrower);

        assertEq(wrapper.balanceOf(borrower, tokenId), wrapper.FULL_AMOUNT());

        startHoax(borrower);
        wrapper.enableCurrentSkimCandidateAsCollateral();

        uint256[] memory enabledTokenIds = wrapper.getEnabledTokenIds(borrower);
        assertEq(enabledTokenIds.length, 1);
        assertEq(enabledTokenIds[0], tokenId);

        vm.expectRevert(ERC721WrapperBase.TokenIdIsAlreadyWrapped.selector);
        wrapper.skim(borrower);
    }

    function testFuzzWrapAndUnwrapUniV3(LiquidityParams memory params) public {
        (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent) = boundLiquidityParamsAndMint(params);
        tokenId = tokenIdMinted;

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        uint256 amount0InUnitOfAccount = wrapper.getQuote(amount0Spent, address(token0));
        uint256 amount1InUnitOfAccount = wrapper.getQuote(amount1Spent, address(token1));

        {
            uint256 expectedBalance = (amount0InUnitOfAccount + amount1InUnitOfAccount);

            assertApproxEqAbs(wrapper.balanceOf(borrower), expectedBalance, ALLOWED_PRECISION_IN_TESTS);
        }

        uint256 amount0BalanceBefore = IERC20(token0).balanceOf(borrower);
        uint256 amount1BalanceBefore = IERC20(token1).balanceOf(borrower);

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        // make sure the preview unwrap matches the actual unwrap
        (uint256 previewUnwrapAmount0, uint256 previewUnwrapAmount1) =
            UniswapV3Wrapper(address(wrapper)).previewUnwrap(tokenId, sqrtPriceX96, wrapper.FULL_AMOUNT());

        //unwrap to get the underlying tokens back
        wrapper.unwrap(
            borrower,
            tokenId,
            borrower,
            wrapper.FULL_AMOUNT(),
            abi.encode(
                (amount0Spent > 0 ? amount0Spent - 1 : 0), (amount1Spent > 0 ? amount1Spent - 1 : 0), block.timestamp
            )
        );

        assertEq(IERC20(token0).balanceOf(borrower), amount0BalanceBefore + previewUnwrapAmount0);
        assertEq(IERC20(token1).balanceOf(borrower), amount1BalanceBefore + previewUnwrapAmount1);

        assertEq(wrapper.balanceOf(borrower, tokenId), 0);

        assertApproxEqAbs(IERC20(token0).balanceOf(borrower), amount0BalanceBefore + amount0Spent, 1);
        assertApproxEqAbs(IERC20(token1).balanceOf(borrower), amount1BalanceBefore + amount1Spent, 1);
    }

    function testFuzzTotalPositionValue(LiquidityParams memory params) public {
        uint256 amount0Spent;
        uint256 amount1Spent;

        (tokenId, amount0Spent, amount1Spent) = boundLiquidityParamsAndMint(params);

        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);

        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();

        (uint256 token0Principal, uint256 token1Principal) =
            MockUniswapV3Wrapper(address(wrapper)).totalPositionValue(sqrtRatioX96, tokenId);

        //since no swap has been the principal amount should be the same as the amount0 and amount1
        assertApproxEqAbs(token0Principal, amount0Spent, 1 wei);
        assertApproxEqAbs(token1Principal, amount1Spent, 1 wei);
    }

    function swapExactInput(address swapper, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        bool zeroForOne = tokenIn < tokenOut;
        deal(tokenIn, swapper, amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: swapper,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        return swapRouter.exactInputSingle(params);
    }

    function testFuzzFeeMath(int256 liquidityDelta, uint256 swapAmount) public {
        // liquidityDelta = -19999;
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: liquidityDelta
        });

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);
        // swapAmount = 100_00000 * unit0;

        (tokenId,,) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        //swap so that some fees are generated
        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        (
            ,,,,,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,,
        ) = nonFungiblePositionManager.positions(tokenId);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            MockUniswapV3Wrapper(address(wrapper)).getFeeGrowthInside(tickLower, tickUpper);

        (uint256 expectedFees0, uint256 expectedFees1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );

        (uint256 actualFees0, uint256 actualFees1) = MockUniswapV3Wrapper(address(wrapper)).syncFeesOwned(tokenId);

        assertApproxEqAbs(actualFees0, expectedFees0, 1); //1 wei of error because it's because of the way we are calculating the actual fees is not ideal way of doing it
        assertApproxEqAbs(actualFees1, expectedFees1, 1);
    }
    //make sure v3 version of this test is working as expected

    function testFuzzFeeMathWithPartialUnwrapV3(
        int256 liquidityDelta,
        uint256 fees0ToDonate,
        uint256 fees1ToDonate,
        uint256 partialUnwrapAmount
    ) public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: liquidityDelta
        });

        (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenIdMinted);
        wrapper.wrap(tokenIdMinted, borrower);
        wrapper.enableTokenIdAsCollateral(tokenIdMinted);

        uint256 totalBalanceBefore = wrapper.balanceOf(borrower);

        fees0ToDonate = bound(fees0ToDonate, 1, amount0);
        fees1ToDonate = bound(fees1ToDonate, 1, amount1);

        deal(address(token0), address(feeDonator), fees0ToDonate);
        deal(address(token1), address(feeDonator), fees1ToDonate);

        //donate some fees to the position
        feeDonator.donate(fees0ToDonate, fees1ToDonate, true);

        (uint256 expectedFees0, uint256 expectedFees1) =
            MockUniswapV3Wrapper(payable(address(wrapper))).pendingFees(tokenIdMinted);

        uint256 expectedFeesValue = oracle.getQuote(expectedFees0, token0, unitOfAccount)
            + oracle.getQuote(expectedFees1, token1, unitOfAccount);

        assertApproxEqAbs(wrapper.balanceOf(borrower), totalBalanceBefore + expectedFeesValue, 1);

        //now if a user does partial unwrap feesOwed should be deducted proportionally

        partialUnwrapAmount = bound(partialUnwrapAmount, 1, wrapper.FULL_AMOUNT());
        bool isZeroLiquidityDecreased =
            MockUniswapV3Wrapper((address(wrapper))).isZeroLiquidityDecreased(tokenIdMinted, partialUnwrapAmount);

        uint256 expectedValueAfter = MockUniswapV3Wrapper(payable(address(wrapper)))
            .calculateExactedValueOfTokenIdAfterUnwrap(tokenIdMinted, partialUnwrapAmount, wrapper.FULL_AMOUNT());

        if (isZeroLiquidityDecreased) {
            vm.expectRevert();
        }
        wrapper.unwrap(borrower, tokenIdMinted, borrower, partialUnwrapAmount, "");

        assertApproxEqAbs(wrapper.balanceOf(borrower), expectedValueAfter, 1e17);

        if (!isZeroLiquidityDecreased) {
            (uint256 currentFees0Owed, uint256 currentFees1Owed) =
                MockUniswapV3Wrapper(payable(address(wrapper))).tokensOwed(tokenIdMinted);

            assertEq(currentFees0Owed, expectedFees0 - (expectedFees0 * partialUnwrapAmount) / wrapper.FULL_AMOUNT());
            assertEq(currentFees1Owed, expectedFees1 - (expectedFees1 * partialUnwrapAmount) / wrapper.FULL_AMOUNT());
        }

        //now if a user does full unwrap, the ownership needs to be transferred to the unwraper
        //the tokensOwned can be non zero but that doesn't matter as this is handled by the nonFungiblePositionManager and not our contracts
        wrapper.unwrap(borrower, tokenIdMinted, borrower);
        assertEq(wrapper.underlying().ownerOf(tokenIdMinted), borrower);
    }

    function testFuzzTransfer(LiquidityParams memory params, uint256 swapAmount, uint256 transferAmount) public {
        (tokenId,,) = boundLiquidityParamsAndMint(params);

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        uint256 totalValueBefore = wrapper.balanceOf(borrower);

        transferAmount = bound(transferAmount, 1 + (totalValueBefore / ALLOWED_PRECISION_IN_TESTS), totalValueBefore); // make sure there is some minimum transfer amount

        uint256 tokenIdBalance = wrapper.balanceOf(borrower, tokenId);
        uint256 erc6909TokensTransferred = wrapper.normalizedToFull(tokenIdBalance, transferAmount, totalValueBefore); // (transferAmount * wrapper.FULL_AMOUNT()) / totalValueBefore;

        assertTrue(wrapper.transfer(liquidator, transferAmount));

        assertEq(wrapper.balanceOf(liquidator, tokenId), erc6909TokensTransferred); //erc6909 check (rounding error)
        assertEq(wrapper.balanceOf(borrower, tokenId), wrapper.FULL_AMOUNT() - erc6909TokensTransferred);

        assertEq(wrapper.balanceOf(liquidator), 0); // because tokenId is not enabled as collateral
        assertApproxEqAbs(wrapper.balanceOf(borrower), totalValueBefore - transferAmount, ALLOWED_PRECISION_IN_TESTS);

        startHoax(liquidator);
        wrapper.enableTokenIdAsCollateral(tokenId);

        assertApproxEqAbs(wrapper.balanceOf(liquidator), transferAmount, ALLOWED_PRECISION_IN_TESTS);
        assertApproxEqRel(
            totalValueBefore, wrapper.balanceOf(borrower) + wrapper.balanceOf(liquidator), ALLOWED_PRECISION_IN_TESTS
        );
    }

    function test_BasicBorrowV3() public {
        borrowTest();
    }

    function test_basicLiquidation() public {
        basicLiquidationTest();
    }
}
