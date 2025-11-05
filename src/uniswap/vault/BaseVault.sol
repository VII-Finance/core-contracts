// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";

abstract contract BaseVault is ERC4626 {
    using SafeERC20 for IERC20;
    IERC721WrapperBase public immutable wrapper;

    address public immutable borrowToken;
    IERC721 public immutable positionManager;

    int24 public tickLower;
    int24 public tickUpper;
    int24 public tickSpacing;

    error AssetNotAssociatedWithWrapper();

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset) ERC20("VII Vault", "VII") ERC4626(_asset) {
        wrapper = _wrapper;
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
    }

    function _getTokens(address _wrapper) public view virtual returns (address, address);

    // this function will take the tokens from the user and do everything needed but keep the shares.
    // the initial amount should be less than the minimum.
    // this is avoids the inflations attacks + during the normal deposits, we don't have to mint the tokenID
    // we just increase the liquidity as we already know tokenId has already been minted.
    function initializeVault() external {}

    function name() public view override(ERC20, IERC20Metadata) returns (string memory) {
        //construct this from the underlying tokens names + fee tier if possible
        return "";
    }

    function symbol() public view override(ERC20, IERC20Metadata) returns (string memory) {
        //construct this from the underlying tokens symbols + fee tier if possible
        return "VII";
    }
}
