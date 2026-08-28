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
import {ISubscriber} from "lib/v4-periphery/src/interfaces/ISubscriber.sol";
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
import {UniswapBaseTestFork} from "test/uniswap/UniswapBase.t.sol";
import {UniswapBaseTestLocal} from "test/uniswap/setup/UniswapBaseLocal.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TestRouter, SwapParams} from "lib/v4-periphery/test/shared/TestRouter.sol";
import {PoolDonateTest} from "lib/v4-periphery/lib/v4-core/src/test/PoolDonateTest.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";

// ─── Shared test bodies ───────────────────────────────────────────────────────

abstract contract UniswapV4WrapperTestBase is UniswapBaseTest, ISubscriber {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    IPositionManager public positionManager;
    IPoolManager public poolManager;

    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;

    TestRouter public router;
    PoolDonateTest public poolDonateRouter;

    // ─── Helpers ──────────────────────────────────────────────────────────────

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

        assertEq(targetPoolKey.currency0.balanceOf(address(positionManager)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(positionManager)), 0);
        assertEq(targetPoolKey.currency0.balanceOf(address(mintPositionHelper)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(mintPositionHelper)), 0);

        amount0 = token0BalanceBefore - targetPoolKey.currency0.balanceOf(owner);
        amount1 = token1BalanceBefore - targetPoolKey.currency1.balanceOf(owner);
    }

    function swapExactInput(address swapper, address tokenIn, address tokenOut, uint256 inputAmount)
        internal
        virtual
        returns (uint256 outputAmount)
    {
        deal(tokenIn, swapper, inputAmount);
        bool zeroForOne = tokenIn < tokenOut;
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        BalanceDelta balanceDelta = router.swap{value: 0}(poolKey, swapParams, new bytes(0));
        outputAmount = zeroForOne ? uint256(int256(balanceDelta.amount1())) : uint256(int256(balanceDelta.amount0()));
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

        // Skip inputs where the tick range is so far out-of-range that liquidity rounds to zero amounts.
        vm.assume(estimatedAmount0Required > 0 || estimatedAmount1Required > 0);

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

    // ─── ISubscriber implementation ───────────────────────────────────────────

    function notifyUnsubscribe(uint256) external {
        wrapper.skim(address(this));
    }
    function notifySubscribe(uint256, bytes memory) external {}
    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}

    // ─── Shared tests ─────────────────────────────────────────────────────────

    function test_swapExactInputV4() public {
        uint256 inputAmount = 1e18;
        startHoax(borrower);
        uint256 outputAmount = swapExactInput(borrower, address(token0), address(token1), inputAmount);
        assertGt(outputAmount, 0);
    }

    function testSkim() public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: -19999
        });
        (tokenId,,) = boundLiquidityParamsAndMint(params);

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

        assertApproxEqAbs(
            wrapper.balanceOf(borrower), amount0InUnitOfAccount + amount1InUnitOfAccount, ALLOWED_PRECISION_IN_TESTS
        );

        uint256 amount0BalanceBefore = poolKey.currency0.balanceOf(borrower);
        uint256 amount1BalanceBefore = poolKey.currency1.balanceOf(borrower);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 previewUnwrapAmount0, uint256 previewUnwrapAmount1) =
            UniswapV4Wrapper(payable(address(wrapper))).previewUnwrap(tokenId, sqrtPriceX96, wrapper.FULL_AMOUNT());

        wrapper.unwrap(
            borrower, tokenId, borrower, wrapper.FULL_AMOUNT(), abi.encode(uint128(0), uint128(0), block.timestamp)
        );

        assertEq(poolKey.currency0.balanceOf(borrower), amount0BalanceBefore + previewUnwrapAmount0);
        assertEq(poolKey.currency1.balanceOf(borrower), amount1BalanceBefore + previewUnwrapAmount1);
        assertEq(wrapper.balanceOf(borrower, tokenId), 0);

        // Combined abs+rel tolerance: 0.5% for large amounts, 5-wei floor for tiny amounts (avoids 0 !~= 1 failures).
        uint256 expected0 = amount0BalanceBefore + amount0Spent;
        uint256 expected1 = amount1BalanceBefore + amount1Spent;
        assertApproxEqAbs(poolKey.currency0.balanceOf(borrower), expected0, expected0 * 5e15 / 1e18 + 5);
        assertApproxEqAbs(poolKey.currency1.balanceOf(borrower), expected1, expected1 * 5e15 / 1e18 + 5);
    }

    function testFuzzFeeMath(int256 liquidityDelta, uint256 swapAmount) public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: liquidityDelta
        });

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        (tokenId,,) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

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
            tickLower: TickMath.MIN_TICK + 1, tickUpper: TickMath.MAX_TICK - 1, liquidityDelta: liquidityDelta
        });

        (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenIdMinted);
        wrapper.wrap(tokenIdMinted, borrower);
        wrapper.enableTokenIdAsCollateral(tokenIdMinted);

        uint256 totalBalanceBefore = wrapper.calculateValueOfTokenId(tokenIdMinted, wrapper.totalSupply(tokenIdMinted));

        fees0ToDonate = bound(fees0ToDonate, 1, amount0);
        fees1ToDonate = bound(fees1ToDonate, 1, amount1);

        deal(address(token0), address(borrower), fees0ToDonate);
        deal(address(token1), address(borrower), fees1ToDonate);

        SafeERC20.forceApprove(IERC20(token0), address(poolDonateRouter), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(poolDonateRouter), type(uint256).max);

        poolDonateRouter.donate{value: poolKey.currency0.isAddressZero() ? fees0ToDonate : 0}(
            poolKey, fees0ToDonate, fees1ToDonate, ""
        );

        (uint256 expectedFees0, uint256 expectedFees1) =
            MockUniswapV4Wrapper(payable(address(wrapper))).pendingFees(tokenIdMinted);

        uint256 expectedFeesValue = oracle.getQuote(expectedFees0, token0, unitOfAccount)
            + oracle.getQuote(expectedFees1, token1, unitOfAccount);

        assertApproxEqAbs(
            wrapper.calculateValueOfTokenId(tokenIdMinted, wrapper.totalSupply(tokenIdMinted)),
            totalBalanceBefore + expectedFeesValue,
            1
        );

        partialUnwrapAmount = bound(partialUnwrapAmount, 1, wrapper.FULL_AMOUNT());
        uint256 totalSupplyOfTokenIdBefore = wrapper.totalSupply(tokenIdMinted);

        uint256 expectedValueAfter = MockUniswapV4Wrapper(payable(address(wrapper)))
            .calculateExactedValueOfTokenIdAfterUnwrap(tokenIdMinted, partialUnwrapAmount, wrapper.FULL_AMOUNT());
        wrapper.unwrap(borrower, tokenIdMinted, borrower, partialUnwrapAmount, "");

        assertEq(wrapper.balanceOf(borrower), expectedValueAfter);

        (uint256 currentFees0Owed, uint256 currentFees1Owed) =
            MockUniswapV4Wrapper(payable(address(wrapper))).tokensOwed(tokenIdMinted);

        assertEq(currentFees0Owed, expectedFees0 - (expectedFees0 * partialUnwrapAmount) / totalSupplyOfTokenIdBefore);
        assertEq(currentFees1Owed, expectedFees1 - (expectedFees1 * partialUnwrapAmount) / totalSupplyOfTokenIdBefore);

        assertEq(currency0.balanceOf(address(wrapper)), currentFees0Owed);
        assertEq(currency1.balanceOf(address(wrapper)), currentFees1Owed);

        vm.expectRevert();
        wrapper.unwrap(borrower, tokenIdMinted, borrower);
    }

    function testFuzzTotalPositionValueV4(LiquidityParams memory params) public {
        uint256 amount0Spent;
        uint256 amount1Spent;

        (tokenId, amount0Spent, amount1Spent) = boundLiquidityParamsAndMint(params);

        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);

        (uint256 token0Principal, uint256 token1Principal) =
            MockUniswapV4Wrapper(payable(address(wrapper))).total(tokenId);

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

        uint256 tokenIdBalance = wrapper.balanceOf(borrower, tokenId);
        uint256 erc6909TokensTransferred = wrapper.normalizedToFull(tokenIdBalance, transferAmount, totalValueBefore);

        assertTrue(wrapper.transfer(liquidator, transferAmount));

        assertEq(wrapper.balanceOf(liquidator, tokenId), erc6909TokensTransferred);
        assertEq(wrapper.balanceOf(borrower, tokenId), wrapper.FULL_AMOUNT() - erc6909TokensTransferred);

        assertEq(wrapper.balanceOf(liquidator), 0);
        assertApproxEqAbs(wrapper.balanceOf(borrower), totalValueBefore - transferAmount, ALLOWED_PRECISION_IN_TESTS);

        startHoax(liquidator);
        wrapper.enableTokenIdAsCollateral(tokenId);

        assertApproxEqAbs(wrapper.balanceOf(liquidator), transferAmount, ALLOWED_PRECISION_IN_TESTS);
        assertApproxEqAbs(
            totalValueBefore, wrapper.balanceOf(borrower) + wrapper.balanceOf(liquidator), ALLOWED_PRECISION_IN_TESTS
        );
    }

    function test_useSubUnSubScribeToSkimPlusWrap() public {
        positionManager.subscribe(tokenId, address(this), "");

        wrapper.underlying().approve(address(wrapper), tokenId);
        vm.expectRevert(ERC721WrapperBase.TokenIdIsAlreadyWrapped.selector);
        wrapper.wrap(tokenId, address(this));
    }
}

// ─── Fork test ────────────────────────────────────────────────────────────────

contract UniswapV4WrapperForkTest is UniswapV4WrapperTestBase, UniswapBaseTestFork {
    IPermit2 public permit2 = IPermit2(Addresses.PERMIT2);
    bool public constant TEST_NATIVE_ETH = true;

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        positionManager = IPositionManager(Addresses.POSITION_MANAGER);
        poolManager = IPoolManager(Addresses.POOL_MANAGER);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 10, tickSpacing: 1, hooks: IHooks(address(0))});

        if (TEST_NATIVE_ETH) {
            currency0 = Currency.wrap(address(0));
            currency1 = Currency.wrap(address(Addresses.USDC));
            token0 = Addresses.WETH;
            token1 = Addresses.USDC;
            poolKey = PoolKey({
                currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))
            });
        }

        poolId = poolKey.toId();

        ERC721WrapperBase w = new MockUniswapV4Wrapper{salt: bytes32(uint256(1))}(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, Addresses.WETH
        );
        mintPositionHelper = new UniswapMintPositionHelper(
            address(evc), Addresses.NON_FUNGIBLE_POSITION_MANAGER, address(positionManager)
        );
        return w;
    }

    function setUp() public override(UniswapBaseTest, UniswapBaseTestFork) {
        UniswapBaseTestFork.setUp();
        router = new TestRouter(poolManager);
        poolDonateRouter = new PoolDonateTest(poolManager);

        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(router), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(router), type(uint256).max);
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

    function swapExactInput(address swapper, address tokenIn, address tokenOut, uint256 inputAmount)
        internal
        override
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

    // ─── Fork-only tests ──────────────────────────────────────────────────────

    function testGetSqrtRatioX96() public view {
        sqrtPriceTest(2248266982, Addresses.WETH, Addresses.USDC);
        sqrtPriceTest(75678429218, Addresses.WBTC, Addresses.USDC);
        sqrtPriceTest(33660783978026242452, Addresses.WBTC, Addresses.WETH);
        sqrtPriceTest(2248663233, Addresses.WETH, Addresses.USDT);
        sqrtPriceTest(75691767356, Addresses.WBTC, Addresses.USDT);
    }

    function testWrapFailIfNotTheSamePoolId() public {
        for (uint256 i = 1; i < 20; i++) {
            (PoolKey memory poolKeyOfTokenId,) = positionManager.getPoolAndPositionInfo(i);

            startHoax(wrapper.underlying().ownerOf(i));
            wrapper.underlying().approve(address(wrapper), i);

            if (PoolId.unwrap(poolKeyOfTokenId.toId()) == PoolId.unwrap(poolId)) {
                wrapper.wrap(i, borrower);
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(UniswapV4Wrapper.InvalidPoolId.selector, poolKeyOfTokenId.toId(), poolId)
                );
                wrapper.wrap(i, borrower);
            }
        }
    }

    function testUnwrap_Unichain() public {
        string memory fork_url = vm.envString("UNICHAIN_RPC_URL");
        vm.createSelectFork(fork_url, 28206234);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x7b793B1388e14F03e19dc562470e7D25B2Ae9b97)),
            currency1: Currency.wrap(address(0x9C383Fa23Dd981b361F0495Ba53dDeB91c750064)),
            fee: 18,
            tickSpacing: 1,
            hooks: IHooks(0x777ef319C338C6ffE32A2283F603db603E8F2A80)
        });

        wrapper = new MockUniswapV4Wrapper{salt: bytes32(uint256(1))}(
            address(0x2A1176964F5D7caE5406B627Bf6166664FE83c60),
            address(0x4529A01c7A0410167c5740C487A8DE60232617bf),
            address(0x4267e3012799A804738A73A2Fa9eB4fD441ceEFF),
            0x0000000000000000000000000000000000000348,
            poolKey,
            Addresses.WETH
        );

        borrower = 0x69196bC5035cE85C28DAc0c57D0F27f50712A0B2;
        tokenId = 1428340;

        vm.startPrank(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.unwrap(borrower, tokenId, borrower, wrapper.FULL_AMOUNT(), "");
        vm.stopPrank();
    }

    function test_BasicBorrowV4() public {
        borrowTest();
    }

    function test_basicLiquidationV4() public {
        // The V4 ETH/USDC LP position is worth ~$224,900 at the fork block, far more than the
        // V3 USDC/USDT position used by basicLiquidationTest(). A 97.5% price drop isn't enough
        // to make 5 USDC of debt undercollateralised here. Use a much steeper drop instead.
        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.enableTokenIdAsCollateral(tokenId);
        wrapper.wrap(tokenId, borrower);

        evc.enableCollateral(borrower, address(wrapper));
        evc.enableController(borrower, address(eVault));

        eVault.borrow(5e6, borrower);

        vm.warp(block.timestamp + eVault.liquidationCoolOffTime());

        (uint256 maxRepay, uint256 yield) = eVault.checkLiquidation(liquidator, borrower, address(wrapper));
        assertEq(maxRepay, 0);
        assertEq(yield, 0);

        // Drop wrapper price to 1e10 (≈ 1e-8 of par): $224,900 LP → ~$0.00225 collateral < $5 debt
        _setWrapperUOAPrice(1e10);

        startHoax(liquidator);
        (maxRepay, yield) = eVault.checkLiquidation(liquidator, borrower, address(wrapper));
        assertGt(maxRepay, 0);

        evc.enableCollateral(liquidator, address(wrapper));
        evc.enableController(liquidator, address(eVault));
        wrapper.enableTokenIdAsCollateral(tokenId);
        eVault.liquidate(borrower, address(wrapper), type(uint256).max, 0);

        assertEq(wrapper.balanceOf(borrower), 0);
        assertEq(wrapper.balanceOf(liquidator, tokenId), wrapper.FULL_AMOUNT());
    }
}

// ─── Local test ───────────────────────────────────────────────────────────────

contract UniswapV4WrapperTest is UniswapV4WrapperTestBase, UniswapBaseTestLocal {
    function deployWrapper() internal override returns (ERC721WrapperBase) {
        positionManager = localPositionManager;
        poolManager = localPoolManager;

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        poolId = poolKey.toId();
        localPoolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        ERC721WrapperBase w = new MockUniswapV4Wrapper{salt: bytes32(uint256(1))}(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, address(localWeth)
        );
        mintPositionHelper = new UniswapMintPositionHelper(address(evc), address(localNFPM), address(positionManager));
        return w;
    }

    function setUp() public override(UniswapBaseTest, UniswapBaseTestLocal) {
        UniswapBaseTestLocal.setUp();
        router = new TestRouter(poolManager);
        poolDonateRouter = new PoolDonateTest(poolManager);

        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(router), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(router), type(uint256).max);
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
}
