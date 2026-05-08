// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EVCUtil} from "lib/ethereum-vault-connector/src/utils/EVCUtil.sol";
import {IEVCUtil} from "src/interfaces/IEVCUtil.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC6909} from "lib/openzeppelin-contracts/contracts/interfaces/IERC6909.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {GenericRouter} from "src/uniswap/vault/GenericRouter.sol";

interface IPreviewUnwrap {
    function previewUnwrap(uint256 tokenId, uint160 sqrtRatioX96, uint256 unwrapAmount)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function unwrap(address from, uint256 tokenId, address to) external;
}

abstract contract BaseVault is ERC4626, EVCUtil {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant FULL_AMOUNT = 1e36;
    uint256 public constant MINIMUM_SHARES = 1000;

    // Slippage tolerance for oracle-price checks on swaps: 2% (18-decimal fixed-point)
    uint256 public constant SWAP_SLIPPAGE_TOLERANCE = 0.02e18;

    uint256 public immutable TARGET_LEVERAGE; // e.g. 2e18 = 2x

    IERC721WrapperBase public immutable wrapper;

    IPriceOracle public immutable oracle;
    address public immutable unitOfAccount;

    uint256 public immutable unitOfAsset;
    uint256 public immutable unitOfBorrowToken;

    address public immutable borrowToken;
    IERC721 public immutable positionManager;
    IEVault public immutable borrowVault;
    GenericRouter public immutable genericRouter;

    int24 public tickLower;
    int24 public tickUpper;
    int24 public tickSpacing;

    uint256 public tokenId;

    address public keeper;

    error AssetNotAssociatedWithWrapper();
    error NotSelfCallingThroughEVC();
    error VaultAlreadyInitialized();
    error NotAllowedIfLiquidated();
    error InsufficientInitialShares();
    error NotKeeper();
    error InvalidTicks();
    error SwapOutputTooLow();
    error VaultNotInitialized();
    error InvalidLeverage();

    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault, uint256 _targetLeverage)
        ERC20(
            string.concat("VII ", IERC20Metadata(address(_asset)).symbol(), " Vault"),
            string.concat("vii", IERC20Metadata(address(_asset)).symbol())
        )
        ERC4626(_asset)
        EVCUtil(IEVCUtil(address(_wrapper)).EVC())
    {
        if (_targetLeverage <= 1e18) revert InvalidLeverage();
        wrapper = _wrapper;
        borrowVault = _borrowVault;
        TARGET_LEVERAGE = _targetLeverage;

        (address token0, address token1) = _getTokens(address(_wrapper));

        if (token0 != address(_asset) && token1 != address(_asset)) {
            revert AssetNotAssociatedWithWrapper();
        }
        borrowToken = token0 == address(_asset) ? token1 : token0;
        IERC721 positionManager_ = _wrapper.underlying();

        IERC20(token0).forceApprove(address(positionManager_), type(uint256).max);
        IERC20(token1).forceApprove(address(positionManager_), type(uint256).max);

        IPermit2 permit2 = IPermit2(borrowVault.permit2Address());
        IERC20(borrowToken).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(address(borrowToken), address(_borrowVault), type(uint160).max, type(uint48).max);

        positionManager = positionManager_;

        evc.enableController(address(this), address(_borrowVault));
        evc.enableCollateral(address(this), address(_wrapper));

        tickLower = TickMath.minUsableTick(10);
        tickUpper = TickMath.maxUsableTick(10);

        positionManager.setApprovalForAll(address(wrapper), true);

        oracle = _wrapper.oracle();
        unitOfAccount = _wrapper.unitOfAccount();

        unitOfAsset = 10 ** ERC20(address(_asset)).decimals();
        unitOfBorrowToken = 10 ** ERC20(borrowToken).decimals();

        genericRouter = new GenericRouter();
    }

    function _getTokens(address _wrapper) internal view virtual returns (address, address);

    // ─── Keeper ──────────────────────────────────────────────────────────────

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    function setKeeper(address _keeper) external onlyKeeper {
        emit KeeperSet(keeper, _keeper);
        keeper = _keeper;
    }

    // ─── Initialisation ──────────────────────────────────────────────────────

    function initializeVault(uint256 assetAmount) external {
        if (tokenId != 0) revert VaultAlreadyInitialized();

        IERC20(asset()).safeTransferFrom(_msgSender(), address(this), assetAmount);

        bool isToken0Borrowed = isTokenBeingBorrowedToken0();
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assetAmount);

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        batchItems[0] = _buildBorrowItem(debtAmount);

        uint256 token0Amount = isToken0Borrowed ? debtAmount : assetAmount;
        uint256 token1Amount = isToken0Borrowed ? assetAmount : debtAmount;

        batchItems[1] =
            _buildSelfItem(abi.encodeWithSelector(this.mintPosition.selector, token0Amount, token1Amount, liquidity));

        evc.batch(batchItems);

        uint256 sharesToMint = totalAssets();
        if (sharesToMint < MINIMUM_SHARES) revert InsufficientInitialShares();
        _mint(address(1), sharesToMint);
    }

    // ─── ERC-4626 overrides ───────────────────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        if (tokenId == 0) return 0;

        uint160 currentPrice = getCurrentSqrtPriceX96();
        (uint256 amount0, uint256 amount1) = IPreviewUnwrap(address(wrapper))
            .previewUnwrap(tokenId, currentPrice, IERC6909(address(wrapper)).balanceOf(address(this), tokenId));

        // price of token1 in terms of token0: (sqrtP)^2 / 2^192
        int256 priceIn18Decimals = (int256(uint256(currentPrice)) * int256(uint256(currentPrice)) * 1e18) >> (96 * 2);

        uint256 borrowedAmount = borrowVault.debtOf(address(this));
        bool isBorrowed0 = isTokenBeingBorrowedToken0();

        // net borrow-token position (LP holding + free balance - debt)
        int256 effectiveBorrowTokenAmount = int256(isBorrowed0 ? amount0 : amount1)
            + int256(IERC20(borrowToken).balanceOf(address(this))) - int256(borrowedAmount);

        // convert net borrow-token to asset units
        int256 effectiveBorrowAmountInAsset = isBorrowed0
            ? (effectiveBorrowTokenAmount * 1e18) / priceIn18Decimals
            : (effectiveBorrowTokenAmount * priceIn18Decimals) / 1e18;

        return uint256(
            isBorrowed0
                ? int256(amount1) + effectiveBorrowAmountInAsset
                : int256(amount0) + effectiveBorrowAmountInAsset
        ) + IERC20(asset()).balanceOf(address(this));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);

        if (IERC6909(address(wrapper)).balanceOf(address(this), tokenId) != wrapper.FULL_AMOUNT()) {
            revert NotAllowedIfLiquidated();
        }

        bool isToken0Borrowed = isTokenBeingBorrowedToken0();
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assets);

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](3);

        batchItems[0] = _buildBorrowItem(debtAmount);
        batchItems[1] = _buildUnwrapItem();

        uint256 token0Amount = isToken0Borrowed ? debtAmount : assets;
        uint256 token1Amount = isToken0Borrowed ? assets : debtAmount;

        batchItems[2] = _buildSelfItem(
            abi.encodeWithSelector(this.increaseLiquidity.selector, token0Amount, token1Amount, liquidity)
        );

        evc.batch(batchItems);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // compute the borrow/liquidity to remove proportional to `assets` being withdrawn
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assets + 1);
        debtAmount -= 2; // slight underestimate to avoid rounding revert

        bool isToken0Borrowed = isTokenBeingBorrowedToken0();

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](3);

        batchItems[0] = _buildUnwrapItem();

        uint256 token0Amount = isToken0Borrowed ? debtAmount : assets + 1;
        uint256 token1Amount = isToken0Borrowed ? assets + 1 : debtAmount;

        batchItems[1] = _buildSelfItem(
            abi.encodeWithSelector(this.decreaseLiquidity.selector, token0Amount, token1Amount, liquidity)
        );

        batchItems[2] = IEVC.BatchItem({
            targetContract: address(borrowVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.repay.selector, debtAmount, address(this))
        });

        evc.batch(batchItems);

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ─── Debt helpers ─────────────────────────────────────────────────────────

    /// @notice Returns the borrow amount and liquidity for a given asset deposit
    ///         at the natural LP ratio determined by current ticks and price.
    ///         This is used for both deposit (to determine what to borrow) and
    ///         withdraw (to determine how much liquidity/debt to unwind).
    function getDebtAmount(uint256 assets) public view returns (uint256 debtAmount, uint128 liquidity) {
        uint160 sqrtPriceCurrent = getCurrentSqrtPriceX96();
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (isTokenBeingBorrowedToken0()) {
            // asset is token1, borrow is token0
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioLowerX96, sqrtPriceCurrent, uint128(assets));
            debtAmount = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceCurrent, sqrtRatioUpperX96, liquidity);
        } else {
            // asset is token0, borrow is token1
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceCurrent, sqrtRatioUpperX96, uint128(assets));
            debtAmount = LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioLowerX96, sqrtPriceCurrent, liquidity);
        }

        debtAmount += 1; // account for rounding
    }

    /// @notice Compute total borrow needed to reach TARGET_LEVERAGE for `assets` deposited.
    ///         totalBorrow = (TARGET_LEVERAGE - 1) * assets converted to borrow-token via oracle.
    function getTargetBorrowAmount(uint256 assets) public view returns (uint256) {
        uint256 debtInAsset = (TARGET_LEVERAGE - 1e18) * assets / 1e18;
        return oracle.getQuote(debtInAsset, asset(), borrowToken);
    }

    // ─── Rebalance ─────────────────────────────────────────────────────────────

    function _buildUnwrapItem() internal view returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({
            targetContract: address(wrapper),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IPreviewUnwrap.unwrap.selector, address(this), tokenId, address(this))
        });
    }

    function _buildBorrowItem(uint256 debtAmount) internal view returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({
            targetContract: address(borrowVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, debtAmount, address(this))
        });
    }

    function _buildSelfItem(bytes memory data) internal view returns (IEVC.BatchItem memory) {
        return IEVC.BatchItem({targetContract: address(this), onBehalfOfAccount: address(this), value: 0, data: data});
    }

    function _batchSingleSelf(bytes memory data) internal {
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = _buildSelfItem(data);
        evc.batch(items);
    }

    function _buildDecreaseLiquidityItem(uint256 amountToSwap) internal view returns (IEVC.BatchItem memory) {
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(amountToSwap);
        bool b = isTokenBeingBorrowedToken0();
        bytes memory d = abi.encodeWithSelector(
            this.decreaseLiquidity.selector,
            b ? debtAmount : amountToSwap + 1,
            b ? amountToSwap + 1 : debtAmount,
            liquidity
        );
        return _buildSelfItem(d);
    }

    /// @notice Adjusts leverage toward TARGET_LEVERAGE.
    ///         Called by keeper. `amountToSwap` is in asset units when over-leveraged
    ///         (asset → borrow), or in borrow units when under-leveraged (borrow → asset).
    function reBalance(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData)
        external
        onlyKeeper
    {
        uint256 totalCollateralInUOA = wrapper.balanceOf(address(this));
        uint256 borrowedAmount = borrowVault.debtOf(address(this));
        uint256 borrowAmountInUOA = oracle.getQuote(borrowedAmount, borrowToken, unitOfAccount);

        if (borrowAmountInUOA == 0) return; // nothing to rebalance

        // leverage = collateral / equity  (correct for arbitrary N)
        uint256 equityInUOA = totalCollateralInUOA > borrowAmountInUOA ? totalCollateralInUOA - borrowAmountInUOA : 0;
        if (equityInUOA == 0) return;

        uint256 currentLeverage = (totalCollateralInUOA * 1e18) / equityInUOA;

        if (currentLeverage > TARGET_LEVERAGE) {
            // Over-leveraged: remove liquidity, swap asset → borrow, repay debt
            // decreaseLiquidity re-wraps the position internally, so no extra wrap step needed
            IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](4);

            batchItems[0] = _buildUnwrapItem();
            batchItems[1] = _buildDecreaseLiquidityItem(amountToSwap);

            batchItems[2] = _buildSelfItem(
                abi.encodeWithSelector(this.swapAssetToBorrowToken.selector, amountToSwap, exchange, spender, swapData)
            );
            batchItems[3] = _buildSelfItem(abi.encodeWithSelector(this.repayContractBalance.selector));

            evc.batch(batchItems);
        } else if (currentLeverage < TARGET_LEVERAGE) {
            // Under-leveraged: borrow more, swap borrow → asset, add liquidity
            _batchSingleSelf(
                abi.encodeWithSelector(
                    this.borrowSwapBorrowIncreaseLiquidity.selector, amountToSwap, exchange, spender, swapData
                )
            );
        }
    }

    // ─── Tick change ───────────────────────────────────────────────────────────

    /// @notice Migrates the entire position to new ticks.
    ///         Runs inside an EVC batch so health checks are deferred until the
    ///         new position is posted as collateral.  tokenId will change.
    function changeTicks(
        int24 newTickLower,
        int24 newTickUpper,
        address exchange,
        address spender,
        bytes calldata swapData
    ) external onlyKeeper {
        if (newTickLower >= newTickUpper) revert InvalidTicks();
        if (newTickLower % tickSpacing != 0 || newTickUpper % tickSpacing != 0) revert InvalidTicks();
        if (tokenId == 0) revert VaultNotInitialized();

        _batchSingleSelf(
            abi.encodeWithSelector(
                this.executeChangeTicks.selector, newTickLower, newTickUpper, exchange, spender, swapData
            )
        );
    }

    /// @dev Inner body of changeTicks, executed via EVC batch so health checks are deferred.
    function executeChangeTicks(
        int24 newTickLower,
        int24 newTickUpper,
        address exchange,
        address spender,
        bytes calldata swapData
    ) external onlySelfCallFromEVC {
        // Unwrap the current position
        wrapper.unwrap(address(this), tokenId, address(this));

        // Remove ALL liquidity.  Pass 0 min-amounts: this is a keeper-only
        // migration so slippage protection is not needed here.
        uint128 currentLiquidity = _getCurrentLiquidity();
        if (currentLiquidity > 0) {
            _decreaseLiquidity(0, 0, currentLiquidity);
        }
        _collectAll();

        // Update ticks
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        // Optionally swap to improve ratio for new tick range
        if (swapData.length > 0) {
            _executeSwap(exchange, spender, swapData);
        }

        // Determine amounts to provide
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        uint256 borrowBalance = IERC20(borrowToken).balanceOf(address(this));

        bool isToken0Borrowed = isTokenBeingBorrowedToken0();
        uint256 token0Amount = isToken0Borrowed ? borrowBalance : assetBalance;
        uint256 token1Amount = isToken0Borrowed ? assetBalance : borrowBalance;

        // Compute liquidity for available amounts at new ticks
        uint160 sqrtP = getCurrentSqrtPriceX96();
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(newTickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(newTickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, token0Amount, token1Amount);

        if (liquidity > 0) {
            (uint256 t0Needed, uint256 t1Needed) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liquidity);
            _mintAndRegisterPosition(t0Needed, t1Needed, liquidity);
        }
    }

    // ─── Self-call helpers (EVC-gated) ────────────────────────────────────────

    modifier onlySelfCallFromEVC() {
        if (msg.sender != address(evc) || _msgSender() != address(this)) {
            revert NotSelfCallingThroughEVC();
        }
        _;
    }

    function increaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        _increaseLiquidity(token0, token1, liquidity);
        wrapper.wrap(tokenId, address(this));
    }

    function decreaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        _decreaseLiquidity(token0, token1, liquidity);
        wrapper.wrap(tokenId, address(this));
    }

    function mintPosition(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        _mintAndRegisterPosition(token0, token1, liquidity);
    }

    function _mintAndRegisterPosition(uint256 token0, uint256 token1, uint128 liquidity) internal {
        tokenId = _mintPosition(token0, token1, liquidity);
        wrapper.skim(address(this));
        wrapper.enableTokenIdAsCollateral(tokenId);
    }

    function swapAssetToBorrowToken(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData)
        external
        onlySelfCallFromEVC
    {
        _executeValidatedSwap(IERC20(asset()), IERC20(borrowToken), amountToSwap, exchange, spender, swapData);
    }

    function swapBorrowToAsset(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData)
        external
        onlySelfCallFromEVC
    {
        _executeValidatedSwap(IERC20(borrowToken), IERC20(asset()), amountToSwap, exchange, spender, swapData);
    }

    function _executeValidatedSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountToSwap,
        address exchange,
        address spender,
        bytes calldata swapData
    ) internal returns (uint256 received) {
        tokenIn.safeTransfer(address(genericRouter), amountToSwap);
        uint256 balanceBefore = tokenOut.balanceOf(address(this));
        genericRouter.executeSwap(tokenIn, tokenOut, exchange, spender, swapData);
        received = tokenOut.balanceOf(address(this)) - balanceBefore;
        uint256 expectedMin = oracle.getQuote(amountToSwap, address(tokenIn), address(tokenOut))
            * (1e18 - SWAP_SLIPPAGE_TOLERANCE) / 1e18;
        if (received < expectedMin) revert SwapOutputTooLow();
    }

    function repayContractBalance() external onlySelfCallFromEVC {
        uint256 balance = IERC20(borrowToken).balanceOf(address(this));
        if (balance > 0) {
            borrowVault.repay(balance, address(this));
        }
    }

    function borrowSwapBorrowIncreaseLiquidity(
        uint256 amountToSwap,
        address exchange,
        address spender,
        bytes calldata swapData
    ) external onlySelfCallFromEVC {
        // Step 1: borrow `amountToSwap` borrow token
        borrowVault.borrow(amountToSwap, address(this));

        // Step 2: swap borrow → asset
        uint256 assetsReceived =
            _executeValidatedSwap(IERC20(borrowToken), IERC20(asset()), amountToSwap, exchange, spender, swapData);

        // Step 3: compute additional borrow needed to LP the newly received asset
        (uint256 additionalDebt, uint128 liquidity) = getDebtAmount(assetsReceived);
        borrowVault.borrow(additionalDebt, address(this));

        // Step 4: increase liquidity
        bool isToken0Borrowed = isTokenBeingBorrowedToken0();
        wrapper.unwrap(address(this), tokenId, address(this));
        _increaseLiquidity(
            isToken0Borrowed ? additionalDebt : assetsReceived,
            isToken0Borrowed ? assetsReceived : additionalDebt,
            liquidity
        );
        wrapper.wrap(tokenId, address(this));
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    /// @dev Executes a swap without the onlySelfCallFromEVC guard (used in changeTicks).
    function _executeSwap(address exchange, address spender, bytes calldata swapData) internal {
        // Determine which direction to swap based on token balances vs. natural ratio
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        uint256 borrowBalance = IERC20(borrowToken).balanceOf(address(this));

        // Try asset → borrow first; if that fails try borrow → asset
        if (assetBalance > 0) {
            // Caller-supplied swapData tells us how much to swap; just execute
            IERC20(asset()).safeTransfer(address(genericRouter), assetBalance);
            genericRouter.executeSwap(IERC20(asset()), IERC20(borrowToken), exchange, spender, swapData);
        } else if (borrowBalance > 0) {
            IERC20(borrowToken).safeTransfer(address(genericRouter), borrowBalance);
            genericRouter.executeSwap(IERC20(borrowToken), IERC20(asset()), exchange, spender, swapData);
        }
    }

    /// @dev Collects all owed tokens from the position. Implemented by concrete vaults.
    function _collectAll() internal virtual;

    // ─── Virtual interface ────────────────────────────────────────────────────

    function _mintPosition(uint256 token0, uint256 token1, uint128 liquidity) internal virtual returns (uint256);
    function _increaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) internal virtual;
    function _decreaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) internal virtual;
    function _getCurrentLiquidity() internal view virtual returns (uint128);
    function getCurrentSqrtPriceX96() public view virtual returns (uint160);
    function isTokenBeingBorrowedToken0() internal view virtual returns (bool);

    // ─── ERC-4626 share math ──────────────────────────────────────────────────

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply(), totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets(), totalSupply(), rounding);
    }

    // ─── Misc ─────────────────────────────────────────────────────────────────

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return ERC20.name();
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        return ERC20.symbol();
    }

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    receive() external payable {}
}
