// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TestRouter, SwapParams} from "lib/v4-periphery/test/shared/TestRouter.sol";
import {PoolDonateTest} from "lib/v4-periphery/lib/v4-core/src/test/PoolDonateTest.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";

contract UniswapV4WrapperTest is Test, UniswapBaseTest {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    IPoolManager public poolManager = IPoolManager(Addresses.POOL_MANAGER);
    IPermit2 public permit2 = IPermit2(Addresses.PERMIT2);

    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;

    TestRouter public router;
    PoolDonateTest public poolDonateRouter;

    bool public constant TEST_NATIVE_ETH = true;

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

    function currencyToToken(Currency currency) internal pure returns (IERC20) {
        return IERC20(address(uint160(currency.toId())));
    }

    function setUp() public override {
        super.setUp();

        router = new TestRouter(poolManager);
        poolDonateRouter = new PoolDonateTest(poolManager);
        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(router), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(router), type(uint256).max);

        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(mintPositionHelper), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(mintPositionHelper), type(uint256).max);

        (tokenId,,) = mintPosition(
            poolKey,
            TickMath.minUsableTick(poolKey.tickSpacing),
            TickMath.maxUsableTick(poolKey.tickSpacing),
            100 * unit0,
            100 * unit1,
            0,
            borrower
        );
    }

    function mintPosition(
        PoolKey memory targetPoolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 liquidityToAdd,
        address owner
    ) internal returns (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) {
        deal(address(token0), owner, amount0Desired * 2 + 1);
        deal(address(token1), owner, amount1Desired * 2 + 1);

        tokenIdMinted = positionManager.nextTokenId();

        if (liquidityToAdd == 0) {
            (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

            liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0Desired,
                amount1Desired
            );
        }

        uint256 token0BalanceBefore = targetPoolKey.currency0.balanceOf(owner);
        uint256 token1BalanceBefore = targetPoolKey.currency1.balanceOf(owner);

        mintPositionHelper.mintPosition{value: targetPoolKey.currency0.isAddressZero() ? amount0Desired * 2 + 1 : 0}(
            targetPoolKey,
            tickLower,
            tickUpper,
            liquidityToAdd,
            uint128(amount0Desired) * 2 + 1,
            uint128(amount1Desired) * 2 + 1,
            owner,
            new bytes(0)
        );

        // mintPositionHelper.mintPosition{value: 0}(
        //     targetPoolKey,
        //     tickLower,
        //     tickUpper,
        //     liquidityToAdd,
        //     uint128(amount0Desired) * 2 + 1,
        //     uint128(amount1Desired) * 2 + 1,
        //     owner,
        //     new bytes(0)
        // );

        //ensure any unused tokens are returned to the borrower and position manager balance is zero
        assertEq(targetPoolKey.currency0.balanceOf(address(positionManager)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(positionManager)), 0);

        //for some reason, there is 1 wei of dust native eth left in the mintPositionHelper contract
        assertEq(targetPoolKey.currency0.balanceOf(address(mintPositionHelper)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(mintPositionHelper)), 0);

        amount0 = token0BalanceBefore - targetPoolKey.currency0.balanceOf(owner);
        amount1 = token1BalanceBefore - targetPoolKey.currency1.balanceOf(owner);
    }

    function swapExactInput(address swapper, address tokenIn, address tokenOut, uint256 inputAmount)
        internal
        returns (uint256 outputAmount)
    {
        deal(tokenIn, swapper, inputAmount);

        bool zeroForOne = tokenIn == Addresses.WETH ? true : tokenIn < tokenOut;

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta balanceDelta =
            router.swap{value: tokenIn == Addresses.WETH ? inputAmount : 0}(poolKey, swapParams, new bytes(0));

        outputAmount = zeroForOne ? uint256(int256(balanceDelta.amount1())) : uint256(int256(balanceDelta.amount0()));
    }

    function test_swapExactInputV4() public {
        uint256 inputAmount = 1e18;
        startHoax(borrower);
        uint256 outputAmount = swapExactInput(borrower, address(token0), address(token1), inputAmount);
        assertGt(outputAmount, 0);
    }

    function boundLiquidityParamsAndMint(LiquidityParams memory params)
        internal
        returns (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent)
    {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);
        params = createFuzzyLiquidityParams(params, poolKey.tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        startHoax(borrower);

        (tokenIdMinted, amount0Spent, amount1Spent) = mintPosition(
            poolKey,
            params.tickLower,
            params.tickUpper,
            estimatedAmount0Required,
            estimatedAmount1Required,
            uint256(params.liquidityDelta),
            borrower
        );
    }

    function testGetSqrtRatioX96() public view {
        uint256 fixedDecimals = 10 ** 18;
        uint160 sqrtRatioX96FromOracle = MockUniswapV4Wrapper(payable(address(wrapper))).getSqrtRatioX96FromOracle(
            address(token0), address(token1), unit0, unit1
        );

        uint256 sqrtPriceInFixed18Decimal = Math.mulDiv(sqrtRatioX96FromOracle, fixedDecimals, 1 << 96);

        uint256 priceInFixed18Decimal = Math.mulDiv(sqrtPriceInFixed18Decimal, sqrtPriceInFixed18Decimal, fixedDecimals);

        uint256 token0PerToken1InFixed18Decimal = Math.mulDiv(
            oracle.getQuote(unit0, token0, unitOfAccount), fixedDecimals, oracle.getQuote(unit1, token1, unitOfAccount)
        );

        assertApproxEqAbs(priceInFixed18Decimal, token0PerToken1InFixed18Decimal, 1e6);
    }

    function testWrapFailIfNotTheSamePoolId() public {
        for (uint256 i = 1; i < 20; i++) {
            (PoolKey memory poolKeyOfTokenId,) = positionManager.getPoolAndPositionInfo(i);

            startHoax(wrapper.underlying().ownerOf(i));
            wrapper.underlying().approve(address(wrapper), i);

            if (PoolId.unwrap(poolKeyOfTokenId.toId()) == PoolId.unwrap(poolId)) {
                wrapper.wrap(i, borrower); // wrap should succeed if the poolId matches
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(UniswapV4Wrapper.InvalidPoolId.selector, poolKeyOfTokenId.toId(), poolId)
                );
                wrapper.wrap(i, borrower);
            }
        }
    }

    function testSkim() public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1,
            tickUpper: TickMath.MAX_TICK - 1,
            liquidityDelta: -19999
        });
        (tokenId,,) = boundLiquidityParamsAndMint(params);

        //fail if trying to skim the last minted tokenId but wrapper is not the owner
        vm.expectRevert(ERC721WrapperBase.TokenIdNotOwnedByThisContract.selector);
        wrapper.skim(borrower);

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

    function testFuzzWrapAndUnwrap(LiquidityParams memory params) public {
        (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent) = boundLiquidityParamsAndMint(params);
        tokenId = tokenIdMinted;

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        uint256 amount0InUnitOfAccount = wrapper.getQuote(amount0Spent, address(token0));
        uint256 amount1InUnitOfAccount = wrapper.getQuote(amount1Spent, address(token1));

        uint256 expectedBalance = (amount0InUnitOfAccount + amount1InUnitOfAccount);

        assertApproxEqAbs(wrapper.balanceOf(borrower), expectedBalance, ALLOWED_PRECISION_IN_TESTS);

        uint256 amount0BalanceBefore = poolKey.currency0.balanceOf(borrower);
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOf(borrower);

        //unwrap to get the underlying tokens back

        wrapper.unwrap(
            borrower,
            tokenId,
            borrower,
            wrapper.FULL_AMOUNT(),
            abi.encode(
                uint128(amount0Spent > 0 ? amount0Spent - 1 : 0),
                uint128(amount1Spent > 0 ? amount1Spent - 1 : 0),
                block.timestamp
            )
        );
        assertEq(wrapper.balanceOf(borrower, tokenId), 0);

        assertApproxEqAbs(poolKey.currency0.balanceOf(borrower), amount0BalanceBefore + amount0Spent, 1);
        assertApproxEqAbs(poolKey.currency1.balanceOf(borrower), amount1BalanceBefore + amount1Spent, 1);
    }

    function testFuzzFeeMath(int256 liquidityDelta, uint256 swapAmount) public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1,
            tickUpper: TickMath.MAX_TICK - 1,
            liquidityDelta: liquidityDelta
        });

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        (tokenId,,) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        //swap so that some fees are generated
        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        (uint256 expectedFees0, uint256 expectedFees1) =
            MockUniswapV4Wrapper(payable(address(wrapper))).pendingFees(tokenId);

        (uint256 actualFees0, uint256 actualFees1) =
            MockUniswapV4Wrapper(payable(address(wrapper))).syncFeesOwned(tokenId);

        assertEq(actualFees0, expectedFees0);
        assertEq(actualFees1, expectedFees1);
    }

    function testFuzzFeeMathWithPartialUnwrap(
        int256 liquidityDelta,
        uint256 fees0ToDonate,
        uint256 fees1ToDonate,
        uint256 partialUnwrapAmount
    ) public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1,
            tickUpper: TickMath.MAX_TICK - 1,
            liquidityDelta: liquidityDelta
        });

        (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenIdMinted);
        wrapper.wrap(tokenIdMinted, borrower);
        wrapper.enableTokenIdAsCollateral(tokenIdMinted);

        uint256 totalBalanceBefore = wrapper.balanceOf(borrower);

        fees0ToDonate = bound(fees0ToDonate, 1, amount0);
        fees1ToDonate = bound(fees1ToDonate, 1, amount1);

        deal(address(token0), address(borrower), fees0ToDonate);
        deal(address(token1), address(borrower), fees1ToDonate);

        SafeERC20.forceApprove(IERC20(token0), address(poolDonateRouter), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(poolDonateRouter), type(uint256).max);

        //donate some fees to the position
        poolDonateRouter.donate{value: poolKey.currency0.isAddressZero() ? fees0ToDonate : 0}(
            poolKey, fees0ToDonate, fees1ToDonate, ""
        );

        (uint256 expectedFees0, uint256 expectedFees1) =
            MockUniswapV4Wrapper(payable(address(wrapper))).pendingFees(tokenIdMinted);

        uint256 expectedFeesValue = oracle.getQuote(expectedFees0, token0, unitOfAccount)
            + oracle.getQuote(expectedFees1, token1, unitOfAccount);

        assertApproxEqAbs(wrapper.balanceOf(borrower), totalBalanceBefore + expectedFeesValue, 1);

        //now if a user does partial unwrap feesOwed should be deducted proportionally
        partialUnwrapAmount = bound(partialUnwrapAmount, 1, wrapper.FULL_AMOUNT());
        wrapper.unwrap(borrower, tokenIdMinted, borrower, partialUnwrapAmount, "");

        (uint256 currentFees0Owed, uint256 currentFees1Owed) =
            MockUniswapV4Wrapper(payable(address(wrapper))).tokensOwed(tokenIdMinted);

        assertEq(currentFees0Owed, expectedFees0 - (expectedFees0 * partialUnwrapAmount) / wrapper.FULL_AMOUNT());
        assertEq(currentFees1Owed, expectedFees1 - (expectedFees1 * partialUnwrapAmount) / wrapper.FULL_AMOUNT());

        assertEq(
            currency0.balanceOf(address(wrapper)),
            currentFees0Owed
        );
        assertEq(
            currency1.balanceOf(address(wrapper)),
            currentFees1Owed
        );

        //now if a user does full unwrap, feesOwed should be zero and the should have gone to the user itself
        wrapper.unwrap(borrower, tokenIdMinted, borrower);
        (currentFees0Owed, currentFees1Owed) = MockUniswapV4Wrapper(payable(address(wrapper))).tokensOwed(tokenIdMinted);
        assertEq(currentFees0Owed, 0);
        assertEq(currentFees1Owed, 0);
        assertEq(wrapper.underlying().ownerOf(tokenIdMinted), borrower);
    }

    function testFuzzTotalPositionValueV4(LiquidityParams memory params) public {
        uint256 amount0Spent;
        uint256 amount1Spent;

        (tokenId, amount0Spent, amount1Spent) = boundLiquidityParamsAndMint(params);

        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);

        (uint256 token0Principal, uint256 token1Principal) =
            MockUniswapV4Wrapper(payable(address(wrapper))).total(tokenId);

        //since no swap has been the principal amount should be the same as the amount0 and amount1
        assertApproxEqAbs(token0Principal, amount0Spent, 1 wei);
        assertApproxEqAbs(token1Principal, amount1Spent, 1 wei);
    }

    function testFuzzTransferV4(LiquidityParams memory params, uint256 swapAmount, uint256 transferAmount) public {
        (tokenId,,) = boundLiquidityParamsAndMint(params);

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        uint256 totalValueBefore = wrapper.balanceOf(borrower);

        vm.assume(totalValueBefore > 0);
        transferAmount = bound(transferAmount, 1 + (totalValueBefore / ALLOWED_PRECISION_IN_TESTS), totalValueBefore);

        uint256 erc6909TokensTransferred = wrapper.normalizedToFull(borrower, tokenId, transferAmount, totalValueBefore); // (transferAmount * wrapper.FULL_AMOUNT()) / totalValueBefore;

        assertTrue(wrapper.transfer(liquidator, transferAmount));

        assertEq(wrapper.balanceOf(liquidator, tokenId), erc6909TokensTransferred); //erc6909 check (rounding error)
        assertEq(wrapper.balanceOf(borrower, tokenId), wrapper.FULL_AMOUNT() - erc6909TokensTransferred);

        assertEq(wrapper.balanceOf(liquidator), 0); // because tokenId is not enabled as collateral
        assertApproxEqAbs(wrapper.balanceOf(borrower), totalValueBefore - transferAmount, ALLOWED_PRECISION_IN_TESTS);

        startHoax(liquidator);
        wrapper.enableTokenIdAsCollateral(tokenId);

        assertApproxEqAbs(wrapper.balanceOf(liquidator), transferAmount, ALLOWED_PRECISION_IN_TESTS);
        assertApproxEqAbs(totalValueBefore, wrapper.balanceOf(borrower) + wrapper.balanceOf(liquidator), 1);
    }

    function test_BasicBorrowV4() public {
        borrowTest();
    }

    function test_basicLiquidationV4() public {
        basicLiquidationTest();
    }
}
