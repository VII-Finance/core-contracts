// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {IWETH9} from "lib/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract UniswapV4Vault is BaseVault {
    using StateLibrary for IPoolManager;
    address public immutable weth;
    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;
    PoolKey public poolKey;

    using StateLibrary for IPoolManager;

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault)
        BaseVault(_wrapper, _asset, _borrowVault)
    {
        UniswapV4Wrapper v4Wrapper = UniswapV4Wrapper(payable(address(_wrapper)));
        weth = v4Wrapper.weth();
        poolManager = v4Wrapper.poolManager();
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = v4Wrapper.poolKey();
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
        poolId = poolKey.toId();
    }

    //this gets called in the constructor of BaseVault so it shouldn't be using immutables
    function _getTokens(address _wrapper) public view virtual override returns (address, address) {
        UniswapV4Wrapper v4wrapper = UniswapV4Wrapper(payable(_wrapper));
        Currency currency0 = v4wrapper.currency0();
        return (
            Currency.unwrap(currency0.isAddressZero() ? Currency.wrap(v4wrapper.weth()) : currency0),
            Currency.unwrap(v4wrapper.currency1())
        );
    }

    function isTokenBeingBorrowedToken0() internal view override returns (bool) {
        if (asset() == weth) {
            return false;
        } else if (borrowToken == weth) {
            return true;
        } else {
            return borrowToken < asset();
        }
    }

    function getCurrentSqrtPriceX96() public view override returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
    }

    // TODO: gas can be saved here by directly sending the tokens to the position manager
    function _mintPosition(uint256 token0Amount, uint256 token1Amount, uint128 liquidity)
        internal
        override
        returns (uint256 tokenId)
    {
        tokenId = IPositionManager(address(positionManager)).nextTokenId();

        bytes memory actionData = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, token0Amount + 1, token1Amount + 1, address(wrapper), ""
        );

        _callModifyLiquidity(uint8(Actions.MINT_POSITION), actionData, token0Amount, token1Amount);
    }

    function _increaseLiquidity(uint256 token0Amount, uint256 token1Amount, uint128 liquidity) internal override {
        bytes memory actionData = abi.encode(tokenId, liquidity, token0Amount + 1, token1Amount + 1, "");
        _callModifyLiquidity(uint8(Actions.INCREASE_LIQUIDITY), actionData, token0Amount, token1Amount);
    }

    function _callModifyLiquidity(
        uint8 actionType, // either Actions.MINT_POSITION or Actions.INCREASE_LIQUIDITY
        bytes memory actionData, // encoded params for first action
        uint256 token0Amount,
        uint256 token1Amount
    ) internal {
        bytes memory actions = new bytes(5);
        actions[0] = bytes1(actionType);
        actions[1] = bytes1(uint8(Actions.SETTLE));
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](5);
        params[0] = actionData;
        params[1] = abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);
        params[3] = abi.encode(poolKey.currency0, _msgSender());
        params[4] = abi.encode(poolKey.currency1, _msgSender());

        if (poolKey.currency0.isAddressZero()) {
            IWETH9(weth).withdraw(token0Amount);
        } else {
            poolKey.currency0.transfer(address(positionManager), token0Amount);
        }
        poolKey.currency1.transfer(address(positionManager), token1Amount);

        IPositionManager(address(positionManager)).modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, params), block.timestamp
        );
    }

    function _decreaseLiquidity(uint256 token0Amount, uint256 token1Amount, uint128 liquidity) internal override {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        //TODO: figure out why token0Amount - 1 and token1Amount - 1 as minimum amounts is not working here
        //  params[0] = abi.encode(tokenId, liquidity, token0Amount - 1, token1Amount - 1, "");
        params[0] = abi.encode(tokenId, liquidity, 0, 0, "");
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);

        IPositionManager(address(positionManager)).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        if (poolKey.currency0.isAddressZero()) {
            IWETH9(weth).deposit{value: address(this).balance}();
        }
    }

    receive() external payable {}
}
