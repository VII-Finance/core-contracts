// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {
    PositionManager,
    IAllowanceTransfer,
    IPositionDescriptor,
    IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {GenericFactory} from "lib/euler-vault-kit/src/GenericFactory/GenericFactory.sol";
import {EVault} from "lib/euler-vault-kit/src/EVault/EVault.sol";
import {BalanceForwarder} from "lib/euler-vault-kit/src/EVault/modules/BalanceForwarder.sol";
import {Borrowing} from "lib/euler-vault-kit/src/EVault/modules/Borrowing.sol";
import {Governance} from "lib/euler-vault-kit/src/EVault/modules/Governance.sol";
import {Initialize} from "lib/euler-vault-kit/src/EVault/modules/Initialize.sol";
import {Liquidation} from "lib/euler-vault-kit/src/EVault/modules/Liquidation.sol";
import {RiskManager} from "lib/euler-vault-kit/src/EVault/modules/RiskManager.sol";
import {Token} from "lib/euler-vault-kit/src/EVault/modules/Token.sol";
import {Vault} from "lib/euler-vault-kit/src/EVault/modules/Vault.sol";
import {Base} from "lib/euler-vault-kit/src/EVault/shared/Base.sol";
import {Dispatch} from "lib/euler-vault-kit/src/EVault/Dispatch.sol";
import {ProtocolConfig} from "lib/euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "lib/euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";
import {IEVault} from "lib/euler-vault-kit/src/EVault/IEVault.sol";

import {MockPriceOracle} from "lib/euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {MockBalanceTracker} from "lib/euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {TestERC20} from "lib/euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestDefault} from "lib/euler-vault-kit/test/mocks/IRMTestDefault.sol";

import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH} from "lib/euler-price-oracle/lib/solady/src/tokens/WETH.sol";

import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";

contract MockReturnsWETH9 {
    address public immutable weth;

    constructor(address _weth) {
        weth = (_weth);
    }

    function WETH9() external view returns (address) {
        return weth;
    }
}

contract BaseSetup is Test, Fuzzers {
    using StateLibrary for PoolManager;

    PoolManager public poolManager;
    PositionManager public positionManager;
    UniswapV4WrapperFactory public uniswapV4WrapperFactory;
    EthereumVaultConnector public evc;
    GenericFactory public genericFactory;
    EVault public eulerVaultImplementation;

    MockPriceOracle public oracle;
    address public unitOfAccount = address(1);

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    address public poolManagerOwner = makeAddr("poolManagerOwner");
    address public genericFactoryAdmin = makeAddr("genericFactoryAdmin");
    address public protocolAdmin = makeAddr("protocolAdmin");
    address public protocolFeeReceiver = makeAddr("protocolFeeReceiver");
    address public eVaultAFeeReceiver = makeAddr("eVaultAFeeReceiver");
    address public eVaultBFeeReceiver = makeAddr("eVaultBFeeReceiver");

    TestERC20 public tokenA;
    TestERC20 public tokenB;

    IEVault public eTokenAVault;
    IEVault public eTokenBVault;

    PoolKey public poolKey;
    PoolId public poolId;
    MockUniswapV4Wrapper public uniswapV4Wrapper;
    UniswapMintPositionHelper public mintPositionHelper;

    uint24 fee = 3000;
    int24 tickSpacing = 60;

    IERC20 token0;
    IERC20 token1;

    WETH public weth;

    struct LiquidityParams {
        int256 liquidityDelta;
        int24 tickLower;
        int24 tickUpper;
    }

    function setUp() public virtual {
        weth = new WETH();
        poolManager = new PoolManager(poolManagerOwner);
        positionManager = new PositionManager(
            poolManager, IAllowanceTransfer(address(0)), 0, IPositionDescriptor(address(0)), IWETH9(address(weth))
        );

        evc = new EthereumVaultConnector();

        uniswapV4WrapperFactory = new UniswapV4WrapperFactory(address(evc), address(positionManager), address(weth));

        genericFactory = new GenericFactory(genericFactoryAdmin);

        oracle = new MockPriceOracle();

        integrations = Base.Integrations({
            evc: address(evc),
            protocolConfig: address(new ProtocolConfig(protocolAdmin, protocolFeeReceiver)),
            sequenceRegistry: address(new SequenceRegistry()),
            balanceTracker: address(new MockBalanceTracker()),
            permit2: address(0) // Placeholder, can be set later
        });

        modules = Dispatch.DeployedModules({
            initialize: address(new Initialize(integrations)),
            token: address(new Token(integrations)),
            vault: address(new Vault(integrations)),
            borrowing: address(new Borrowing(integrations)),
            liquidation: address(new Liquidation(integrations)),
            riskManager: address(new RiskManager(integrations)),
            balanceForwarder: address(new BalanceForwarder(integrations)),
            governance: address(new Governance(integrations))
        });

        eulerVaultImplementation = new EVault(integrations, modules);

        vm.prank(genericFactoryAdmin);
        genericFactory.setImplementation(address(eulerVaultImplementation));

        tokenA = new TestERC20("Token A", "TKA", 18, false);
        tokenB = new TestERC20("Token B", "TKB", 18, false);

        eTokenAVault = IEVault(
            genericFactory.createProxy(
                address(0), true, abi.encodePacked(address(tokenA), address(oracle), unitOfAccount)
            )
        );
        eTokenBVault = IEVault(
            genericFactory.createProxy(
                address(0), true, abi.encodePacked(address(tokenB), address(oracle), unitOfAccount)
            )
        );

        eTokenAVault.setHookConfig(address(0), 0);
        eTokenAVault.setInterestRateModel(address(new IRMTestDefault()));
        eTokenAVault.setMaxLiquidationDiscount(0.2e4);
        eTokenAVault.setFeeReceiver(eVaultAFeeReceiver);

        eTokenBVault.setHookConfig(address(0), 0);
        eTokenBVault.setInterestRateModel(address(new IRMTestDefault()));
        eTokenBVault.setMaxLiquidationDiscount(0.2e4);
        eTokenBVault.setFeeReceiver(eVaultBFeeReceiver);

        (token0, token1) = address(tokenA) < address(tokenB)
            ? (IERC20(address(tokenA)), IERC20(address(tokenB)))
            : (IERC20(address(tokenB)), IERC20(address(tokenA)));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        uniswapV4Wrapper = new MockUniswapV4Wrapper(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, address(weth)
        );

        address uniswapV4WrapperAddress = address(uniswapV4Wrapper);

        oracle.setPrice(uniswapV4WrapperAddress, unitOfAccount, 1e18); // Set initial price to 1:1
        oracle.setPrice(address(tokenA), unitOfAccount, 1e18); // Set initial price to 1:1
        oracle.setPrice(address(tokenB), unitOfAccount, 1e18); // Set initial price to 1:1

        //accept the uniswapV4Wrapper a collateral in both eTokenAVault and eTokenBVault
        eTokenAVault.setLTV(uniswapV4WrapperAddress, 0.9e4, 0.9e4, 0); // 90% LTV
        eTokenBVault.setLTV(uniswapV4WrapperAddress, 0.9e4, 0.9e4, 0); // 90% LTV

        mintPositionHelper = new UniswapMintPositionHelper(
            address(evc), address(new MockReturnsWETH9(address(weth))), address(positionManager)
        );
    }

    function createFuzzyLiquidityParams(LiquidityParams memory params, int24 tickSpacing_, uint160 sqrtPriceX96)
        internal
        view
        returns (LiquidityParams memory)
    {
        (params.tickLower, params.tickUpper) = boundTicks(params.tickLower, params.tickUpper, tickSpacing_);
        int256 liquidityDeltaFromAmounts =
            getLiquidityDeltaFromAmounts(params.tickLower, params.tickUpper, sqrtPriceX96);

        int256 liquidityMaxPerTick = int256(uint256(Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing_)));

        int256 liquidityMax =
            liquidityDeltaFromAmounts > liquidityMaxPerTick ? liquidityMaxPerTick : liquidityDeltaFromAmounts;

        //We read the current liquidity for the tickLower and tickUpper and make sure the resulting liquidity does not exceed the max liquidity per tick

        (uint128 liquidityGrossTickLower,,,) = poolManager.getTickInfo(poolId, params.tickLower);
        (uint128 liquidityGrossTickUpper,,,) = poolManager.getTickInfo(poolId, params.tickUpper);

        uint128 liquidityGrossTickLowerAfter = liquidityGrossTickLower + uint128(uint256(liquidityMax));

        if (liquidityGrossTickLowerAfter > uint128(uint256(liquidityMaxPerTick))) {
            liquidityMax = int256(uint256(liquidityMaxPerTick) - uint256(liquidityGrossTickLower));
        }
        uint128 liquidityGrossTickUpperAfter = liquidityGrossTickUpper + uint128(uint256(liquidityMax));

        if (liquidityGrossTickUpperAfter > uint128(uint256(liquidityMaxPerTick))) {
            liquidityMax = int256(uint256(liquidityMaxPerTick) - uint256(liquidityGrossTickUpper));
        }

        _vm.assume(liquidityMax != 0);
        params.liquidityDelta = bound(liquidityDeltaFromAmounts, 1, liquidityMax);

        return params;
    }

    //mint a new position
    function getCurrencyAddress(Currency currency) internal pure returns (address) {
        return currency.isAddressZero() ? address(0) : address(uint160(currency.toId()));
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
        deal(getCurrencyAddress(targetPoolKey.currency0), owner, amount0Desired * 2 + 1);
        deal(getCurrencyAddress(targetPoolKey.currency1), owner, amount1Desired * 2 + 1);

        startHoax(owner);
        token0.approve(address(mintPositionHelper), amount0Desired * 2 + 1);
        token1.approve(address(mintPositionHelper), amount1Desired * 2 + 1);

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

        //ensure any unused tokens are returned to the borrower and position manager balance is zero
        assertEq(targetPoolKey.currency0.balanceOf(address(positionManager)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(positionManager)), 0);

        assertEq(targetPoolKey.currency0.balanceOf(address(mintPositionHelper)), 0);
        assertEq(targetPoolKey.currency1.balanceOf(address(mintPositionHelper)), 0);

        amount0 = token0BalanceBefore - targetPoolKey.currency0.balanceOf(owner);
        amount1 = token1BalanceBefore - targetPoolKey.currency1.balanceOf(owner);
    }

    function boundLiquidityParamsAndMint(address actor, LiquidityParams memory params)
        internal
        returns (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent)
    {
        params.liquidityDelta = bound(params.liquidityDelta, 1, 10_000e18);
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);
        params = createFuzzyLiquidityParams(params, poolKey.tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        startHoax(actor);

        (tokenIdMinted, amount0Spent, amount1Spent) = mintPosition(
            poolKey,
            params.tickLower,
            params.tickUpper,
            estimatedAmount0Required,
            estimatedAmount1Required,
            uint256(params.liquidityDelta),
            actor
        );
    }
}
