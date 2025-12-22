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
import {console} from "lib/forge-std/src/console.sol";

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

    uint256 public constant TARGET_LEVERAGE = 2e18; // 2x leverage with 18 decimals

    IERC721WrapperBase public immutable wrapper;

    // fetched from the wrapper but stored as immutable for gas savings
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

    error AssetNotAssociatedWithWrapper();
    error NotSelfCallingThroughEVC();
    error VaultAlreadyInitialized();
    error NotAllowedIfLiquidated();
    error InsufficientInitialShares();

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault)
        ERC20("VII Vault", "VII")
        ERC4626(_asset)
        EVCUtil(IEVCUtil(address(_wrapper)).EVC())
    {
        wrapper = _wrapper;
        borrowVault = _borrowVault;
        //TODO: make sure borrowVault.asset() is the same as the borrowToken
        (address token0, address token1) = _getTokens(address(_wrapper));

        if (token0 != address(_asset) && token1 != address(_asset)) {
            revert AssetNotAssociatedWithWrapper();
        }
        borrowToken = token0 == address(_asset) ? token1 : token0;
        IERC721 positionManager_ = _wrapper.underlying();

        //for v4 we need to check if using permit2 saves gas or just transferring the amount directly to the position manager
        // to mint position. In either case we don't need to approve to position manager here
        // this needs to be specific to uniswap v3 vault where the approval happens in the constructor there
        IERC20(token0).forceApprove(address(positionManager_), type(uint256).max);
        IERC20(token1).forceApprove(address(positionManager_), type(uint256).max);

        // approve the permit2 contract. Euler vault will pull funds using that
        // we can also approve the vault directly but the problem is that euler vault will first try to pull using permit2 anyway
        // it fails and then it will try the normal transferFrom. It wastes gas so let's just approve the permit2
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

    function _getTokens(address _wrapper) public view virtual returns (address, address);

    // this function will take the tokens from the user and do everything needed but keep the shares.
    // the initial amount should be less than the minimum.
    // this is avoids the inflations attacks + during the normal deposits, we don't have to mint the tokenID
    // we just increase the liquidity as we already know tokenId has already been minted.
    function initializeVault(uint256 assetAmount) external {
        if (tokenId != 0) {
            revert VaultAlreadyInitialized();
        }

        IERC20(asset()).safeTransferFrom(_msgSender(), address(this), assetAmount);

        bool isTokenBeingBorrowedToken0_ = isTokenBeingBorrowedToken0();
        //calculate the debt to borrow. should be the same in USD value as the assetAmount
        //we can enforce this by getting the current price in USD from the wrapper and make sure
        //it is within respectable bounds
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assetAmount);

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        batchItems[0] = IEVC.BatchItem({
            targetContract: address(borrowVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, debtAmount, address(this))
        });

        uint256 token0Amount = isTokenBeingBorrowedToken0_ ? debtAmount : assetAmount;
        uint256 token1Amount = isTokenBeingBorrowedToken0_ ? assetAmount : debtAmount;

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(this.mintPosition.selector, token0Amount, token1Amount, liquidity)
        });

        evc.batch(batchItems);

        //we need to mint some initial tokens to zero address
        uint256 sharesToMint = totalAssets();

        if (sharesToMint < MINIMUM_SHARES) {
            revert InsufficientInitialShares();
        }

        _mint(address(1), sharesToMint);
    }

    // totalAssets, we need to get the total eth that the underlying position holds and get stablecoin amount as well
    // convert the stablecoing amount - debt into eth amount using the current price. Then add the eth amount to get totalAssets
    // how do we use the sqrtPriceX96 to convert amounts?
    function totalAssets() public view override returns (uint256) {
        if (tokenId == 0) return 0;

        //we need to get how much amount0 and amount1 the underlying token is worth.
        //The plan is to do the calculations here in this contract instead of doing an external call
        uint256 currentPrice = getCurrentSqrtPriceX96();
        (uint256 amount0, uint256 amount1) = IPreviewUnwrap(address(wrapper))
            .previewUnwrap(tokenId, uint160(currentPrice), IERC6909(address(wrapper)).balanceOf(address(this), tokenId));

        int256 priceIn18Decimals = (int256(currentPrice) * int256(currentPrice) * 1e18) >> (96 * 2);

        uint256 borrowedAmount = borrowVault.debtOf(address(this));

        int256 effectiveBorrowTokenAmount = int256(isTokenBeingBorrowedToken0() ? amount0 : amount1)
            + int256(IERC20(borrowToken).balanceOf(address(this))) - int256(borrowedAmount);

        // we need to convert borrow amount to asset amount using current price
        int256 effectiveBorrowAmountInAsset = isTokenBeingBorrowedToken0()
            ? ((effectiveBorrowTokenAmount) * 1e18) / priceIn18Decimals
            : ((effectiveBorrowTokenAmount) * priceIn18Decimals) / 1e18;

        return (uint256(
                isTokenBeingBorrowedToken0()
                    ? int256(amount1) + effectiveBorrowAmountInAsset
                    : int256(amount0) + effectiveBorrowAmountInAsset
            )) + IERC20(asset()).balanceOf(address(this));
    }

    function getDebtAmount(uint256 assets) public view returns (uint256 debtAmount, uint128 liquidity) {
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        liquidity = isTokenBeingBorrowedToken0()
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtRatioLowerX96, getCurrentSqrtPriceX96(), uint128(assets))
            : LiquidityAmounts.getLiquidityForAmount0(getCurrentSqrtPriceX96(), sqrtRatioUpperX96, uint128(assets));

        debtAmount = isTokenBeingBorrowedToken0()
            ? LiquidityAmounts.getAmount0ForLiquidity(getCurrentSqrtPriceX96(), sqrtRatioUpperX96, liquidity)
            : LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioLowerX96, getCurrentSqrtPriceX96(), liquidity);

        debtAmount += 1; //add 1 to account for rounding errors
    }

    function isTokenBeingBorrowedToken0() internal view virtual returns (bool);

    modifier onlySelfCallFromEVC() {
        if (msg.sender != address(evc) || _msgSender() != address(this)) {
            revert NotSelfCallingThroughEVC();
        }
        _;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);

        if (IERC6909(address(wrapper)).balanceOf(address(this), tokenId) != FULL_AMOUNT) {
            revert NotAllowedIfLiquidated();
        }

        bool isTokenBeingBorrowedToken0_ = isTokenBeingBorrowedToken0();
        //calculate the debt to borrow. should be the same in USD value as the assetAmount
        //we can enforce this by getting the current price in USD from the wrapper and make sure
        //it is within respectable bounds
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assets);

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](3);

        batchItems[0] = IEVC.BatchItem({
            targetContract: address(borrowVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, debtAmount, address(this))
        });

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(wrapper),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IPreviewUnwrap.unwrap.selector, address(this), tokenId, address(this))
        });

        uint256 token0Amount = isTokenBeingBorrowedToken0_ ? debtAmount : assets;
        uint256 token1Amount = isTokenBeingBorrowedToken0_ ? assets : debtAmount;

        //the act of wrapping the tokenId back should happen in the increaseLiquidity function
        batchItems[2] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(this.increaseLiquidity.selector, token0Amount, token1Amount, liquidity)
        });

        evc.batch(batchItems);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assets + 1);
        debtAmount -= 2;

        bool isTokenBeingBorrowedToken0_ = isTokenBeingBorrowedToken0();

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](3);

        batchItems[0] = IEVC.BatchItem({
            targetContract: address(wrapper),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IPreviewUnwrap.unwrap.selector, address(this), tokenId, address(this))
        });

        uint256 token0Amount = isTokenBeingBorrowedToken0_ ? debtAmount : assets + 1;
        uint256 token1Amount = isTokenBeingBorrowedToken0_ ? assets + 1 : debtAmount;

        //the act of wrapping the tokenId back should happen in the decreaseLiquidity function
        batchItems[1] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(this.decreaseLiquidity.selector, token0Amount, token1Amount, liquidity)
        });

        batchItems[2] = IEVC.BatchItem({
            targetContract: address(borrowVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.repay.selector, debtAmount, address(this))
        });

        evc.batch(batchItems);

        // in a batch we unwrap, decrease liquidity and wrap + repay

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // we need to have a function that takes the existing hanging ETH and borrows to open more positions
    // and takes the hanging USDC balance and repay the debt
    // hanging eth are ok to stay in the vault but handing USDC are not good

    // this vault itself can use subAccounts to open positions in multiple markets

    // we should maybe exact the amount that vault should swap from the rebalancer and also the calladata for where to swap as well
    // based on the amount provided by the rebalancer, we can decide how much liquidity to remove
    function reBalance(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData) external {
        // what we are going to do is find out wheather the leverage is less or greater than target leverage

        // we need to get the total assets and total debt
        // the assumption

        // bool isTokenBeingBorrowedToken0_ = isTokenBeingBorrowedToken0();

        uint256 totalCollateralInUOA = wrapper.balanceOf(address(this));

        // and then we simply get the debt
        // convert it in unit of account as well
        uint256 borrowedAmount = borrowVault.debtOf(address(this));
        uint256 borrowAmountInUOA = oracle.getQuote(borrowedAmount, borrowToken, unitOfAccount);

        // we get the current leverage this way
        // after that we figure out what swap needs to be done

        uint256 currentLeverage = (totalCollateralInUOA * 1e18) / borrowAmountInUOA;

        if (currentLeverage > TARGET_LEVERAGE) {
            // this what should be used off chain to determing how much to eth we need to swap to USDC

            // now in a batch we unwrap, decrease liquidity, convert eth into USDC and then repay the debt using the current balance of the contract
            // do we even know the debt amount we will be repaying here?

            // based off of that we need to get the liquidity that we need to reduce
            // we get the current liquidity and take a proportion of that
            // uint256 collateralAmountToReduceInUOA = (currentLeverage
            //         * borrowAmountInUOA
            //         - (totalCollateralInUOA * 1e18)) / currentLeverage - TARGET_LEVERAGE;

            // uint128 liquidityToRemove =
            //     _getCurrentLiquidity() * uint128(collateralAmountToReduceInUOA) / uint128(totalCollateralInUOA);

            // and then based on the liquidityToRemove we know how much ETH we need to swap

            // we know how much liquidity we need to remove
            IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](4);

            // this is effectively same as withdraw but the result ETH is then swapped to further repay the loan
            // so maybe the logic can be reused

            batchItems[0] = IEVC.BatchItem({
                targetContract: address(wrapper),
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeWithSelector(IPreviewUnwrap.unwrap.selector, address(this), tokenId, address(this))
            });

            {
                (uint256 debtAmount, uint128 liquidity) = getDebtAmount(amountToSwap);
                batchItems[1] = IEVC.BatchItem({
                    targetContract: address(this),
                    onBehalfOfAccount: address(this),
                    value: 0,
                    data: abi.encodeWithSelector(
                        this.decreaseLiquidity.selector,
                        isTokenBeingBorrowedToken0() ? debtAmount : amountToSwap + 1,
                        isTokenBeingBorrowedToken0() ? amountToSwap + 1 : debtAmount,
                        liquidity
                    )
                });
            }
            batchItems[3] = IEVC.BatchItem({
                targetContract: address(this),
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeWithSelector(
                    this.swapAssetToBorrowToken.selector, amountToSwap, exchange, spender, swapData
                )
            });

            batchItems[4] = IEVC.BatchItem({
                targetContract: address(this),
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeWithSelector(this.repayContractBalance.selector)
            });

            evc.batch(batchItems);
        } else {
            // if the leverage is less than the target leverage then we need to borrow more USDC and convert some of it into ETH and unwrap and increase liquidity

            // How much? it's given by the same equation when leverage is higher but with negation

            // uint256 collateralAmountToReduceInUOA = (totalCollateralInUOA * 1e18)
            //         - (currentLeverage * borrowAmountInUOA)) / TARGET_LEVERAGE - current leverage;

            // on top of borrowing some USDC and convert it to ETH this is the same as deposit

            IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](1);

            batchItems[0] = IEVC.BatchItem({
                targetContract: address(this),
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeWithSelector(
                    this.borrowSwapBorrowIncreaseLiquidity.selector, amountToSwap, exchange, spender, swapData
                )
            });

            evc.batch(batchItems);
        }
    }

    function changeTicks(int24 newTickLower, int24 newTickUpper) external {
        // how do we handle the the fact that there might be some hanging USDC or ETH in the contract?
        // unwrap, decrease all of the liquidity (do not wrap again when decreasing liquidity), change the ticks and then increase liquidity and wrap again

        }

    function increaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        _increaseLiquidity(token0, token1, liquidity);
        wrapper.wrap(tokenId, address(this));
    }

    function decreaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) public onlySelfCallFromEVC {
        _decreaseLiquidity(token0, token1, liquidity);
        wrapper.wrap(tokenId, address(this));
    }

    function mintPosition(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        //mint the position using the wrapper
        tokenId = _mintPosition(token0, token1, liquidity);

        wrapper.skim(address(this));
        wrapper.enableTokenIdAsCollateral(tokenId);
    }

    function swapAssetToBorrowToken(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData)
        external
        onlySelfCallFromEVC
    {
        // the assumption is that the data will be from an aggregator like 0x where knowing in advance the input amount is not required

        // we develop a generic Handler that does the swap for us. The generic handler doesn't have to be trusted
        // we simply transfer the amount to that address and it will send us the borrow token back
        // we make sure that the borrow token received more or less matches the oracle price

        IERC20(asset()).safeTransfer(address(genericRouter), amountToSwap);

        uint256 borrowTokenBalanceBefore = IERC20(borrowToken).balanceOf(address(this));
        genericRouter.executeSwap(IERC20(asset()), IERC20(borrowToken), exchange, spender, swapData);

        uint256 borrowTokensReceived = IERC20(borrowToken).balanceOf(address(this)) - borrowTokenBalanceBefore;

        //add a check to make sure borrowToken Received is appropriate based on the oracle price
    }

    function repayContractBalance() external onlySelfCallFromEVC {
        borrowVault.repay(IERC20(borrowToken).balanceOf(address(this)), address(this));
    }

    function borrowSwapBorrowIncreaseLiquidity(
        uint256 amountToSwap,
        address exchange,
        address spender,
        bytes calldata swapData
    ) external onlySelfCallFromEVC {
        borrowVault.borrow(amountToSwap, address(this));

        uint256 assetBalanceBefore = IERC20(asset()).balanceOf(address(this));
        genericRouter.executeSwap(IERC20(borrowToken), IERC20(asset()), exchange, spender, swapData);

        uint256 assetsReceived = IERC20(asset()).balanceOf(address(this)) - assetBalanceBefore;

        // add a check to make sure assetsReceived is appropriate based on the oracle price

        (uint256 debtAmount, uint128 liquidity) = getDebtAmount(assetsReceived);

        borrowVault.borrow(debtAmount, address(this));

        // unwrap and increase liquidity
        wrapper.unwrap(address(this), tokenId, address(this));
        _increaseLiquidity(
            isTokenBeingBorrowedToken0() ? debtAmount : assetsReceived,
            isTokenBeingBorrowedToken0() ? assetsReceived : debtAmount,
            liquidity
        );
        wrapper.wrap(tokenId, address(this));
    }
    //mintPosition return the tokenId and send that tokenId to the wrapper contract to be skimmed
    function _mintPosition(uint256 token0, uint256 token1, uint128 liquidity) internal virtual returns (uint256);

    function _increaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) internal virtual;

    function _decreaseLiquidity(uint256 token0, uint256 token1, uint128 liquidity) internal virtual;

    function _getCurrentLiquidity() internal view virtual returns (uint128);

    // we have one type of rebalance the same as other liquidity manager. Where a priviledged address is allowed to change ticks
    // another is where we adjust the debt of the protocol

    function getCurrentSqrtPriceX96() public view virtual returns (uint160);

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        //construct this from the underlying tokens names + fee tier if possible
        return "";
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        //construct this from the underlying tokens symbols + fee tier if possible
        return "VII";
    }

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    //no need for virtual deposits. When initializing the vault, we are minting some shares to the zero address
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply(), totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets(), totalSupply(), rounding);
    }
}
