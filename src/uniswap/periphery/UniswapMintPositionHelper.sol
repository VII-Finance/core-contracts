// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC4626} from "lib/forge-std/src/interfaces/IERC4626.sol";

contract UniswapMintPositionHelper is EVCUtil {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IPositionManager public immutable positionManager;
    IWETH9 public immutable weth;

    constructor(address _evc, address _nonfungiblePositionManager, address _positionManager) EVCUtil(_evc) {
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        positionManager = IPositionManager(_positionManager);
        weth = IWETH9(INonfungiblePositionManager(_nonfungiblePositionManager).WETH9());
    }

    function depositIntoVaultUsingETH(IERC4626 vault, uint256 assets, address receiver)
        external
        payable
        returns (uint256 shares)
    {
        weth.deposit{value: msg.value}();
        weth.approve(address(vault), assets);
        shares = vault.deposit(assets, receiver);
    }

    function mintPosition(INonfungiblePositionManager.MintParams memory params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.amount0Desired != 0) {
            IERC20(params.token0).safeTransferFrom(_msgSender(), address(this), params.amount0Desired);
        }
        if (params.amount1Desired != 0) {
            IERC20(params.token1).safeTransferFrom(_msgSender(), address(this), params.amount1Desired);
        }

        params.amount0Desired = IERC20(params.token0).balanceOf(address(this));
        params.amount1Desired = IERC20(params.token1).balanceOf(address(this));

        IERC20(params.token0).forceApprove(address(nonfungiblePositionManager), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(nonfungiblePositionManager), params.amount1Desired);

        (tokenId, liquidity, amount0, amount1) = (nonfungiblePositionManager.mint{value: msg.value}(params));

        uint256 leftoverToken0Balance = IERC20(params.token0).balanceOf(address(this));
        uint256 leftoverToken1Balance = IERC20(params.token1).balanceOf(address(this));

        if (leftoverToken0Balance > 0) {
            IERC20(params.token0).safeTransfer(_msgSender(), leftoverToken0Balance);
        }
        if (leftoverToken1Balance > 0) {
            IERC20(params.token1).safeTransfer(_msgSender(), leftoverToken1Balance);
        }
        return (tokenId, liquidity, amount0, amount1);
    }

    function mintPosition(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) external payable returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId();

        if (amount0Max != 0) {
            if (!poolKey.currency0.isAddressZero()) {
                IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(_msgSender(), address(this), amount0Max);
            } else if (msg.value == 0) {
                //if currency0 is native eth and msg.value is 0 then we pull the WETH from the user and unwrap it
                weth.transferFrom(_msgSender(), address(this), amount0Max);
            }
        }
        if (amount1Max != 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(_msgSender(), address(this), amount1Max);
        }

        uint256 currentWETHBalance = weth.balanceOf(address(this));
        if (currentWETHBalance > 0) {
            weth.withdraw(currentWETHBalance); //unwrap WETH to ETH if any is available
        }

        amount0Max = SafeCast.toUint128(poolKey.currency0.balanceOf(address(this)));
        amount1Max = SafeCast.toUint128(poolKey.currency1.balanceOf(address(this)));

        if (!poolKey.currency0.isAddressZero()) {
            poolKey.currency0.transfer(address(positionManager), amount0Max);
        }
        poolKey.currency1.transfer(address(positionManager), amount1Max);

        bytes memory actions = new bytes(5);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE)); //necessary because we don't want funds to be pulled through permit2
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
        params[1] = abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false); //whatever is the open delta will be settled and the payer will be the position manager itself
        params[2] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);

        params[3] = abi.encode(poolKey.currency0, _msgSender()); //if there is remaining amount of currency0, it will be swept to the user
        params[4] = abi.encode(poolKey.currency1, _msgSender());

        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);
    }

    receive() external payable {}
}
