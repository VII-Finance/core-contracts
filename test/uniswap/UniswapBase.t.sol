// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
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
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {Addresses} from "test/helpers/Addresses.sol";

contract UniswapBaseTest is Test, Fuzzers {
    uint256 constant INTERNAL_DEBT_PRECISION_SHIFT = 31;

    // Allow a small margin of error due to rounding when converting token amounts to unit of account.
    // The maximum error is 1 wei in the raw token amounts, which translates to 10 ** (18 - (token0.decimals()) + 10 ** (18- token1.decimals()) in the unit of account.
    // This is assuming that token0 and token1 are worth almost 1 dollar
    uint256 constant ALLOWED_PRECISION_IN_TESTS = 2 * 1e13;

    IEVC evc;
    IEVault eVault; //an evk vault

    IERC20 asset;

    IPriceOracle oracle;
    address unitOfAccount;

    ERC721WrapperBase wrapper;

    uint8 constant MAX_NFT_ALLOWANCE = 2;

    address token0;
    address token1;

    uint256 unit0;
    uint256 unit1;

    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");
    UniswapMintPositionHelper public mintPositionHelper;

    uint256 tokenId;

    function deployWrapper() internal virtual returns (ERC721WrapperBase) {}

    function setUp() public virtual {
        string memory fork_url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(fork_url, 22473612);

        evc = IEVC(Addresses.EVC);
        eVault = IEVault(Addresses.EULER_USDC_VAULT); //euler prime USDC
        asset = IERC20(eVault.asset());

        unitOfAccount = eVault.unitOfAccount();
        oracle = IPriceOracle(eVault.oracle());

        address tokenA = eVault.asset(); //USDC
        address tokenB = Addresses.USDT;

        (token0, token1) = (tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        wrapper = deployWrapper();

        unit0 = 10 ** IERC20Metadata(token0).decimals();
        unit1 = 10 ** IERC20Metadata(token1).decimals();

        deal(token0, borrower, 100 * unit0);
        deal(token1, borrower, 100 * unit1);

        FixedRateOracle fixedRateOracle = new FixedRateOracle(
            address(wrapper),
            unitOfAccount,
            1e18 // 1:1 price, This is because we know unitOfAccount is usd and it's decimals are 18
        );

        address oracleGovernor = IEulerRouter(address(oracle)).governor();
        startHoax(oracleGovernor);
        IEulerRouter(address(oracle)).govSetConfig(address(wrapper), unitOfAccount, address(fixedRateOracle));

        address governorAdmin = eVault.governorAdmin();
        startHoax(governorAdmin);
        eVault.setLTV(address(wrapper), 0.9e4, 0.9e4, 0);
        vm.stopPrank();
    }

    struct LiquidityParams {
        int256 liquidityDelta;
        int24 tickLower;
        int24 tickUpper;
    }

    function createFuzzyLiquidityParams(LiquidityParams memory params, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        pure
        returns (LiquidityParams memory)
    {
        (params.tickLower, params.tickUpper) = boundTicks(params.tickLower, params.tickUpper, tickSpacing);
        int256 liquidityDeltaFromAmounts =
            getLiquidityDeltaFromAmounts(params.tickLower, params.tickUpper, sqrtPriceX96);

        int256 liquidityMaxPerTick = int256(uint256(Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)));

        int256 liquidityMax =
            liquidityDeltaFromAmounts > liquidityMaxPerTick ? liquidityMaxPerTick : liquidityDeltaFromAmounts;
        _vm.assume(liquidityMax != 0);
        params.liquidityDelta = bound(liquidityDeltaFromAmounts, 1, liquidityMax);

        return params;
    }

    function borrowTest() internal {
        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.enableTokenIdAsCollateral(tokenId);
        wrapper.wrap(tokenId, borrower);

        uint256 assetBalanceBefore = asset.balanceOf(borrower);
        uint256 totalBorrowsBefore = eVault.totalBorrows();
        uint256 totalBorrowsExactBefore = eVault.totalBorrowsExact();

        vm.expectRevert(IEVault.E_ControllerDisabled.selector);
        eVault.borrow(5e6, borrower);

        evc.enableController(borrower, address(eVault));

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        eVault.borrow(5e6, borrower);

        // still no borrow hence possible to disable controller
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), true);
        eVault.disableController();
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), false);
        evc.enableController(borrower, address(eVault));
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), true);

        evc.enableCollateral(borrower, address(wrapper));

        eVault.borrow(5e6, borrower);
        assertEq(asset.balanceOf(borrower) - assetBalanceBefore, 5e6);
        assertEq(eVault.debtOf(borrower), 5e6);
        assertEq(eVault.debtOfExact(borrower), 5e6 << INTERNAL_DEBT_PRECISION_SHIFT);

        assertEq(eVault.totalBorrows() - totalBorrowsBefore, 5e6);
        assertEq(eVault.totalBorrowsExact() - totalBorrowsExactBefore, 5e6 << INTERNAL_DEBT_PRECISION_SHIFT);

        // no longer possible to disable controller
        vm.expectRevert(IEVault.E_OutstandingDebt.selector);
        eVault.disableController();

        // Should be able to borrow up to 9, so this should fail:

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        eVault.borrow(180e6, borrower);

        // Disable collateral should fail

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        evc.disableCollateral(borrower, address(wrapper));

        //no longer possible to disable the tokenId as collateral if it makes the account undercollateralized
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        wrapper.disableTokenIdAsCollateral(tokenId);

        //no longer possible to transfer the ERC6909 tokens
        uint256 tokensToTransfer = wrapper.FULL_AMOUNT();
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        wrapper.transfer(address(1), tokenId, tokensToTransfer);

        //no longer possible to transferFrom the ERC6909 tokens either
        wrapper.approve(address(1), tokenId, tokensToTransfer);
        startHoax(address(1));
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        wrapper.transferFrom(borrower, address(1), tokenId, tokensToTransfer);

        startHoax(borrower);

        //unwrap should fail
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        wrapper.unwrap(borrower, tokenId, borrower);

        // Repay

        asset.approve(address(eVault), type(uint256).max);
        eVault.repay(type(uint256).max, borrower);

        evc.disableCollateral(borrower, address(wrapper));
        assertEq(evc.getCollaterals(borrower).length, 0);

        eVault.disableController();
        assertEq(evc.getControllers(borrower).length, 0);
    }

    function basicLiquidationTest() public {
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

        startHoax(IEulerRouter(address(oracle)).governor());
        IEulerRouter(address(oracle))
            .govSetConfig(
                address(wrapper),
                unitOfAccount,
                address(
                    new FixedRateOracle(
                        address(wrapper),
                        unitOfAccount,
                        0.25e17 //in the actual conditions this price will always be the fixed 1:1, the balanceOf(user) will change as the price of the underlying tokens change and the position becomes liquidatable
                    )
                )
            );

        startHoax(liquidator);
        (maxRepay, yield) = eVault.checkLiquidation(liquidator, borrower, address(wrapper));

        evc.enableCollateral(liquidator, address(wrapper));
        evc.enableController(liquidator, address(eVault));
        wrapper.enableTokenIdAsCollateral(tokenId);
        eVault.liquidate(borrower, address(wrapper), type(uint256).max, 0);

        //we know this a full liquidation so the current balanceOf of the borrower should be 0
        assertEq(wrapper.balanceOf(borrower), 0);
        //liquidator must have gotten all of the shares
        assertEq(wrapper.balanceOf(liquidator, tokenId), wrapper.FULL_AMOUNT());
    }
}
