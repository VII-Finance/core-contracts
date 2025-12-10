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
import {console} from "lib/forge-std/src/console.sol";

interface IPreviewUnwrap{
    function previewUnwrap(uint256 tokenId, uint160 sqrtRatioX96, uint256 unwrapAmount)
        external
        view
        returns (uint256 amount0, uint256 amount1);
}

abstract contract BaseVault is ERC4626, EVCUtil {
    using SafeERC20 for IERC20;
    using Math for uint256;
    IERC721WrapperBase public immutable wrapper;

    address public immutable borrowToken;
    IERC721 public immutable positionManager;
    IEVault public immutable borrowVault;

    int24 public tickLower;
    int24 public tickUpper;
    int24 public tickSpacing;

    uint256 public tokenId;

    error AssetNotAssociatedWithWrapper();
    error NotSelfCallingThroughEVC();
    error VaultAlreadyInitialized();

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

        positionManager = positionManager_;

        evc.enableController(address(this), address(_borrowVault));
        evc.enableCollateral(address(this), address(_wrapper));

        tickLower = TickMath.minUsableTick(10);
        tickUpper = TickMath.maxUsableTick(10);
    }

    function _getTokens(address _wrapper) public view virtual returns (address, address);

    function assetsReceiver() internal view virtual returns (address);

    // this function will take the tokens from the user and do everything needed but keep the shares.
    // the initial amount should be less than the minimum.
    // this is avoids the inflations attacks + during the normal deposits, we don't have to mint the tokenID
    // we just increase the liquidity as we already know tokenId has already been minted.
    function initializeVault(uint256 assetAmount) external {
        if (tokenId != 0) {
            revert VaultAlreadyInitialized();
        }

        IERC20(asset()).safeTransferFrom(_msgSender(), assetsReceiver(), assetAmount);

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
            data: abi.encodeWithSelector(IEVault.borrow.selector, debtAmount, assetsReceiver())
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
    }

    function calculateAmounts(uint256 tokenId) public view virtual returns (uint256, uint256);

    // totalAssets, we need to get the total eth that the underlying position holds and get stablecoin amount as well
    // convert the stablecoing amount - debt into eth amount using the current price. Then add the eth amount to get totalAssets
    // how do we use the sqrtPriceX96 to convert amounts?
    function totalAssets() public view override returns (uint256) {
        if (tokenId == 0) return 0;

        //we need to get how much amount0 and amount1 the underlying token is worth.
        //The plan is to do the calculations here in this contract instead of doing an external call
        uint256 currentPrice = getCurrentSqrtPriceX96();
        (uint256 amount0, uint256 amount1) = IPreviewUnwrap(address(wrapper)).previewUnwrap(tokenId, uint160(currentPrice), IERC6909(address(wrapper)).balanceOf( address(this), tokenId));
        
        int256 priceIn18Decimals = (int256(currentPrice) * int256(currentPrice) * 1e18) >> (96 * 2);

        uint256 borrowedAmount = borrowVault.debtOf(address(this));

        int256 effectiveBorrowTokenAmount =
            int256(isTokenBeingBorrowedToken0() ? amount0 : amount1) - int256(borrowedAmount);
        
        // we need to convert borrow amount to asset amount using current price
        int256 effectiveBorrowAmountInAsset = isTokenBeingBorrowedToken0()
            ? ((effectiveBorrowTokenAmount) * 1e18) / priceIn18Decimals
            : ((effectiveBorrowTokenAmount) * priceIn18Decimals) / 1e18;
        
        return uint256(isTokenBeingBorrowedToken0()
            ? int256(amount1) + effectiveBorrowAmountInAsset
            : int256(amount0) + effectiveBorrowAmountInAsset);
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

    function mintPosition(uint256 token0, uint256 token1, uint128 liquidity) external onlySelfCallFromEVC {
        //mint the position using the wrapper
        tokenId = _mintPosition(token0, token1, liquidity);

        wrapper.skim(address(this));
        wrapper.enableTokenIdAsCollateral(tokenId);
    }

    //mintPosition return the tokenId and send that tokenId to the wrapper contract to be skimmed
    function _mintPosition(uint256 token0, uint256 token1, uint128 liquidity) internal virtual returns (uint256);

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
