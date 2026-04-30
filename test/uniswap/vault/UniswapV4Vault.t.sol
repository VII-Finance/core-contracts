// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVaultTest} from "test/uniswap/vault/BaseVault.t.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {MockUniswapV4Wrapper} from "test/helpers/MockUniswapV4Wrapper.sol";
import {UniswapV4Vault} from "src/uniswap/vault/UniswapV4Vault.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";

contract UniswapV4VaultTest is BaseVaultTest {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;
    IPoolManager poolManager = IPoolManager(Addresses.POOL_MANAGER);

    UniswapV4Vault v4Vault;

    function setUp() public override {
        initialAmount = 1e18; // 1 WETH
        BaseVaultTest.setUp();
        v4Vault = UniswapV4Vault(payable(address(vault)));
    }

    function deployVault() internal override returns (BaseVault) {
        return new UniswapV4Vault(wrapper, IERC20(Addresses.WETH), eVault, 2e18);
    }

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        currency0 = Currency.wrap(address(0)); // native ETH
        currency1 = Currency.wrap(address(Addresses.USDC));

        token0 = Addresses.WETH;
        token1 = Addresses.USDC;

        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        poolId = poolKey.toId();

        ERC721WrapperBase w = new MockUniswapV4Wrapper{salt: bytes32(uint256(1))}(
            address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey, Addresses.WETH
        );
        mintPositionHelper = new UniswapMintPositionHelper(
            address(evc), Addresses.NON_FUNGIBLE_POSITION_MANAGER, address(positionManager)
        );
        return w;
    }

    // ─── V4-specific: changeTicks ─────────────────────────────────────────────

    function test_changeTicks_basic() public {
        uint256 oldTokenId = vault.tokenId();
        assertGt(oldTokenId, 0);

        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 ts = 10; // tickSpacing for this pool
        int24 newLower = ((currentTick - 500) / ts) * ts;
        int24 newUpper = ((currentTick + 500) / ts) * ts;

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(vaultKeeper);
        vault.changeTicks(newLower, newUpper, address(0), address(0), "");

        assertGt(vault.tokenId(), 0, "tokenId still set after changeTicks");
        assertEq(vault.tickLower(), newLower);
        assertEq(vault.tickUpper(), newUpper);
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, totalAssetsBefore / 50, "assets preserved");
    }

    function test_changeTicks_invalidTicks() public {
        vm.prank(vaultKeeper);
        vm.expectRevert(BaseVault.InvalidTicks.selector);
        vault.changeTicks(0, 0, address(0), address(0), "");
    }

    function test_changeTicks_badAlignment() public {
        vm.prank(vaultKeeper);
        vm.expectRevert(BaseVault.InvalidTicks.selector);
        // tickSpacing=10, so tick=5 is misaligned
        vault.changeTicks(int24(-5), int24(5), address(0), address(0), "");
    }

    function test_depositAfterChangeTicks() public {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 ts = 10;
        int24 newLower = ((currentTick - 1000) / ts) * ts;
        int24 newUpper = ((currentTick + 1000) / ts) * ts;

        vm.prank(vaultKeeper);
        vault.changeTicks(newLower, newUpper, address(0), address(0), "");

        startHoax(depositor);
        deal(vault.asset(), depositor, initialAmount);
        IERC20(vault.asset()).forceApprove(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(initialAmount, depositor);
        vm.stopPrank();
        assertGt(shares, 0, "deposit works after changeTicks");
    }

    // ─── V4-specific: pool references ─────────────────────────────────────────

    function test_poolManagerStored() public view {
        assertEq(address(v4Vault.poolManager()), Addresses.POOL_MANAGER);
    }

    function test_wethStored() public view {
        assertEq(v4Vault.weth(), Addresses.WETH);
    }

    // ─── Leverage check ───────────────────────────────────────────────────────

    function test_leverageApprox2x() public view {
        uint256 collateral = wrapper.balanceOf(address(vault));
        uint256 debt = eVault.debtOf(address(vault));
        uint256 debtInUOA = oracle.getQuote(debt, vault.borrowToken(), vault.unitOfAccount());
        if (collateral == 0 || debtInUOA == 0) return;
        uint256 equity = collateral > debtInUOA ? collateral - debtInUOA : 0;
        if (equity == 0) return;
        uint256 leverage = collateral * 1e18 / equity;
        assertApproxEqAbs(leverage, 2e18, 2e18 * 5 / 100, "leverage ~2x after init");
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_getDebtAmount_nonzero(uint256 assets) public view {
        assets = bound(assets, 1e15, 10e18);
        (uint256 debtAmount, uint128 liquidity) = vault.getDebtAmount(assets);
        assertGt(debtAmount, 0);
        assertGt(liquidity, 0);
    }
}
