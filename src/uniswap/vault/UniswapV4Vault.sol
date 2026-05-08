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
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";

contract UniswapV4Vault is BaseVault {
    using StateLibrary for IPoolManager;

    address public immutable weth;
    IPoolManager public immutable poolManager;
    PoolId internal immutable poolId;
    PoolKey internal poolKey;

    constructor(IERC721WrapperBase _wrapper, IERC20 _asset, IEVault _borrowVault, uint256 _targetLeverage)
        BaseVault(_wrapper, _asset, _borrowVault, _targetLeverage)
    {
        UniswapV4Wrapper v4Wrapper = UniswapV4Wrapper(payable(address(_wrapper)));
        weth = v4Wrapper.weth();
        poolManager = v4Wrapper.poolManager();
        (Currency currency0, Currency currency1, uint24 fee, int24 _tickSpacing, IHooks hooks) = v4Wrapper.poolKey();
        poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: _tickSpacing, hooks: hooks});
        poolId = poolKey.toId();
        tickSpacing = _tickSpacing;
    }

    function _getTokens(address _wrapper) internal view virtual override returns (address, address) {
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
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    function _mintPosition(uint256 token0Amount, uint256 token1Amount, uint128 liquidity)
        internal
        override
        returns (uint256 newTokenId)
    {
        newTokenId = IPositionManager(address(positionManager)).nextTokenId();

        bytes memory actionData = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, token0Amount + 1, token1Amount + 1, address(wrapper), ""
        );

        _callModifyLiquidity(uint8(Actions.MINT_POSITION), actionData, token0Amount, token1Amount);
    }

    function _increaseLiquidity(uint256 token0Amount, uint256 token1Amount, uint128 liquidity) internal override {
        bytes memory actionData = abi.encode(tokenId, liquidity, token0Amount + 1, token1Amount + 1, "");
        _callModifyLiquidity(uint8(Actions.INCREASE_LIQUIDITY), actionData, token0Amount, token1Amount);
    }

    function _callModifyLiquidity(uint8 actionType, bytes memory actionData, uint256 token0Amount, uint256 token1Amount)
        internal
    {
        bytes memory actions = new bytes(5);
        actions[0] = bytes1(actionType);
        actions[1] = bytes1(uint8(Actions.SETTLE));
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        Currency c0 = poolKey.currency0;
        Currency c1 = poolKey.currency1;
        address sender = _msgSender();

        bytes[] memory params = new bytes[](5);
        params[0] = actionData;
        params[1] = abi.encode(c0, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(c1, ActionConstants.OPEN_DELTA, false);
        params[3] = abi.encode(c0, sender);
        params[4] = abi.encode(c1, sender);

        // V4 pool settle rounds up by 1 in the two-sided case (getLiquidityForAmounts
        // → getAmountsForLiquidity roundtrip).  Provide up to +2 extra for each
        // currency, capped at the vault's actual balance so normal single-sided
        // operations (where we only hold the exact required amount) are unaffected.
        if (c0.isAddressZero()) {
            uint256 wethBal = IERC20(weth).balanceOf(address(this));
            IWETH9(weth).withdraw(wethBal < token0Amount + 2 ? wethBal : token0Amount + 2);
        } else {
            address c0Addr = Currency.unwrap(c0);
            uint256 c0Bal = IERC20(c0Addr).balanceOf(address(this));
            c0.transfer(address(positionManager), c0Bal < token0Amount + 2 ? c0Bal : token0Amount + 2);
        }
        address c1Addr = Currency.unwrap(c1);
        uint256 c1Bal = IERC20(c1Addr).balanceOf(address(this));
        c1.transfer(address(positionManager), c1Bal < token1Amount + 2 ? c1Bal : token1Amount + 2);

        IPositionManager(address(positionManager)).modifyLiquidities{value: address(this).balance}(
            abi.encode(actions, params), block.timestamp
        );

        // Wrap any ETH swept back by the SWEEP action so it stays as WETH collateral.
        _wrapETHBalance();
    }

    function _wrapETHBalance() private {
        uint256 bal = address(this).balance;
        if (bal > 0) IWETH9(weth).deposit{value: bal}();
    }

    function _decreaseLiquidity(uint256, uint256, uint128 liquidity) internal override {
        _v4DecreaseAndTake(liquidity);
    }

    /// @dev In V4, TAKE_PAIR inside _decreaseLiquidity already collects everything.
    ///      Only attempt a fees-only collect when there is still liquidity remaining
    ///      (calling DECREASE_LIQUIDITY on an empty position reverts).
    function _collectAll() internal override {
        if (_getCurrentLiquidity() == 0) return;
        _v4DecreaseAndTake(uint128(0));
    }

    function _v4DecreaseAndTake(uint128 liquidity) private {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        Currency c0 = poolKey.currency0;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, 0, 0, "");
        params[1] = abi.encode(c0, poolKey.currency1, ActionConstants.MSG_SENDER);

        IPositionManager(address(positionManager)).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        if (c0.isAddressZero()) _wrapETHBalance();
    }

    function _getCurrentLiquidity() internal view override returns (uint128 liquidity) {
        PositionInfo position = IPositionManager(address(positionManager)).positionInfo(tokenId);
        (liquidity,,) = poolManager.getPositionInfo(
            poolId, address(positionManager), position.tickLower(), position.tickUpper(), bytes32(tokenId)
        );
    }
}
