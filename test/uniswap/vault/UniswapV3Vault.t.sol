// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVaultTest} from "test/uniswap/vault/BaseVault.t.sol";
import {UniswapBaseTestFork} from "test/uniswap/UniswapBase.t.sol";
import {UniswapBaseTestLocal} from "test/uniswap/setup/UniswapBaseLocal.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "lib/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Vault} from "src/uniswap/vault/UniswapV3Vault.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {MockUniswapV3Wrapper} from "test/helpers/MockUniswapV3Wrapper.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";

// ─── Shared V3 vault test body ────────────────────────────────────────────────

abstract contract UniswapV3VaultTestBase is BaseVaultTest {
    using SafeERC20 for IERC20;

    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;
    IUniswapV3Pool pool;
    IUniswapV3Factory factory;
    int24 v3TickSpacing;

    UniswapV3Vault v3Vault;

    // ─── V3-specific: changeTicks ─────────────────────────────────────────────

    function test_changeTicks_basic() public {
        uint256 oldTokenId = vault.tokenId();
        assertGt(oldTokenId, 0);

        (uint160 sqrtP,,,,,,) = pool.slot0();
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 ts = int24(v3TickSpacing);
        int24 newLower = ((currentTick - 100) / ts) * ts;
        int24 newUpper = ((currentTick + 100) / ts) * ts;

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(vaultKeeper);
        vault.changeTicks(newLower, newUpper, address(0), address(0), "");

        assertGt(vault.tokenId(), 0, "tokenId still set");
        assertEq(vault.tickLower(), newLower, "tickLower updated");
        assertEq(vault.tickUpper(), newUpper, "tickUpper updated");
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, totalAssetsBefore / 50, "assets preserved");
    }

    function test_changeTicks_invalidTicks() public {
        vm.prank(vaultKeeper);
        vm.expectRevert(BaseVault.InvalidTicks.selector);
        vault.changeTicks(100, 100, address(0), address(0), ""); // lower == upper
    }

    function test_changeTicks_invertedTicks() public {
        vm.prank(vaultKeeper);
        vm.expectRevert(BaseVault.InvalidTicks.selector);
        vault.changeTicks(100, -100, address(0), address(0), ""); // upper < lower
    }

    function test_changeTicks_badAlignment() public {
        if (v3TickSpacing > 1) {
            vm.prank(vaultKeeper);
            vm.expectRevert(BaseVault.InvalidTicks.selector);
            vault.changeTicks(1, v3TickSpacing + 1, address(0), address(0), "");
        }
    }

    // ─── V3-specific: deposit after changeTicks ───────────────────────────────

    function test_depositAfterChangeTicks() public {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 ts = int24(v3TickSpacing);
        int24 newLower = ((currentTick - 200) / ts) * ts;
        int24 newUpper = ((currentTick + 200) / ts) * ts;

        vm.prank(vaultKeeper);
        vault.changeTicks(newLower, newUpper, address(0), address(0), "");

        startHoax(depositor);
        deal(vault.asset(), depositor, initialAmount);
        IERC20(vault.asset()).forceApprove(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(initialAmount, depositor);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // ─── V3-specific: pool references ─────────────────────────────────────────

    function test_poolAndFee() public view {
        assertEq(address(v3Vault.pool()), address(pool));
        assertEq(v3Vault.fee(), fee);
    }

    // ─── Invariant: leverage stays bounded ───────────────────────────────────

    function test_leverageApprox2x() public view {
        uint256 collateral = wrapper.balanceOf(address(vault));
        uint256 debt = eVault.debtOf(address(vault));
        uint256 debtInUOA = oracle.getQuote(debt, vault.borrowToken(), vault.unitOfAccount());

        if (collateral == 0 || debtInUOA == 0) return;
        uint256 equity = collateral > debtInUOA ? collateral - debtInUOA : 0;
        if (equity == 0) return;

        uint256 leverage = collateral * 1e18 / equity;
        assertApproxEqAbs(leverage, 2e18, 2e18 * 5 / 100, "leverage ~2x");
    }

    // ─── Fuzz: getDebtAmount consistency ─────────────────────────────────────

    function testFuzz_getDebtAmount_nonzero(uint256 assets) public view {
        assets = bound(assets, initialAmount / 1000, initialAmount * 10);
        (uint256 debtAmount, uint128 liquidity) = vault.getDebtAmount(assets);
        assertGt(debtAmount, 0, "debt > 0");
        assertGt(liquidity, 0, "liquidity > 0");
    }

    function testFuzz_getDebtAmount_monotone(uint256 small, uint256 large) public view {
        small = bound(small, initialAmount / 1000, initialAmount * 10);
        large = bound(large, small + initialAmount / 1000, initialAmount * 100);
        (uint256 debt1,) = vault.getDebtAmount(small);
        (uint256 debt2,) = vault.getDebtAmount(large);
        assertLe(debt1, debt2, "debt monotonically non-decreasing");
    }
}

// ─── Fork test ────────────────────────────────────────────────────────────────

contract UniswapV3VaultForkTest is UniswapV3VaultTestBase, UniswapBaseTestFork {
    function setUp() public override(BaseVaultTest, UniswapBaseTestFork) {
        initialAmount = 1e6; // 1 USDT (6 decimals)
        UniswapBaseTestFork.setUp();
        _setUpVault();
        v3Vault = UniswapV3Vault(payable(address(vault)));
    }

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(Addresses.NON_FUNGIBLE_POSITION_MANAGER);
        fee = 100; // 0.01% fee
        factory = IUniswapV3Factory(nonFungiblePositionManager.factory());
        v3TickSpacing = factory.feeAmountTickSpacing(fee);
        pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        ERC721WrapperBase w = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(pool)
        );
        mintPositionHelper =
            new UniswapMintPositionHelper(address(evc), address(nonFungiblePositionManager), address(0));
        return w;
    }

    function deployVault() internal override returns (BaseVault) {
        return new UniswapV3Vault(wrapper, IERC20(Addresses.USDT), eVault, 2e18);
    }
}

// ─── Local test ───────────────────────────────────────────────────────────────

contract UniswapV3VaultTest is UniswapV3VaultTestBase, UniswapBaseTestLocal {
    function setUp() public override(BaseVaultTest, UniswapBaseTestLocal) {
        initialAmount = 1e18;
        UniswapBaseTestLocal.setUp();
        _setUpVault();
        v3Vault = UniswapV3Vault(payable(address(vault)));
    }

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        // fee=500, tickSpacing=10 matches the default ticks set in BaseVault constructor
        fee = 500;
        factory = IUniswapV3Factory(address(localV3Factory));
        v3TickSpacing = factory.feeAmountTickSpacing(fee);

        address poolAddr = localV3Factory.createPool(token0, token1, fee);
        pool = IUniswapV3Pool(poolAddr);
        pool.initialize(Constants.SQRT_PRICE_1_1);

        ERC721WrapperBase w =
            new MockUniswapV3Wrapper(address(evc), address(localNFPM), address(oracle), unitOfAccount, address(pool));
        mintPositionHelper = new UniswapMintPositionHelper(address(evc), address(localNFPM), address(0));
        return w;
    }

    function deployVault() internal override returns (BaseVault) {
        // asset = token0; borrowToken = token1 = eVault.asset() in local setup
        return new UniswapV3Vault(wrapper, IERC20(token0), eVault, 2e18);
    }
}
