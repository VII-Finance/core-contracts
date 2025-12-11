// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC721WrapperBase, UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

///@dev all of the testing uses spot price and not the oracle price
///In reality, the oracle price is used instead of the pool spot price to calculate how much a liquidity position is worth
///This contract should follow IMockUniswapWrapper interface to make sure invariant tests work correctly
contract MockUniswapV4Wrapper is UniswapV4Wrapper {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    constructor(
        address _evc,
        address _positionManager,
        address _oracle,
        address _unitOfAccount,
        PoolKey memory _poolKey,
        address _weth
    ) UniswapV4Wrapper(_evc, _positionManager, _oracle, _unitOfAccount, _poolKey, _weth) {}

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, address recipient) internal {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        IPositionManager(address(underlying)).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _decreaseLiquidityAndRecordChange(uint256 tokenId, uint128 liquidity, address recipient)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 balance0 = poolKey.currency0.balanceOf(address(this));
        uint256 balance1 = poolKey.currency1.balanceOf(address(this));

        _decreaseLiquidity(tokenId, liquidity, recipient);

        (amount0, amount1) =
        (poolKey.currency0.balanceOf(address(this)) - balance0, poolKey.currency1.balanceOf(address(this)) - balance1);
    }

    function syncFeesOwned(uint256 tokenId) external returns (uint256 actualFees0, uint256 actualFees1) {
        //decrease 0 liquidity to get the actual fees that this contract gets
        (actualFees0, actualFees1) = _decreaseLiquidityAndRecordChange(tokenId, 0, ActionConstants.MSG_SENDER);

        tokensOwed[tokenId].fees0Owed += actualFees0;
        tokensOwed[tokenId].fees1Owed += actualFees1;
    }

    function pendingFees(uint256 tokenId) external view returns (uint256 fees0Owed, uint256 fees1Owed) {
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());
        PositionState memory positionState = _getPositionState(tokenId, sqrtRatioX96);
        return _pendingFees(positionState);
    }

    function total(uint256 tokenId) external view returns (uint256 amount0Total, uint256 amount1Total) {
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());
        PositionState memory positionState = _getPositionState(tokenId, sqrtRatioX96);
        return _total(positionState, tokenId);
    }

    struct Local {
        uint160 sqrtRatioX96;
        uint256 pendingFees0;
        uint256 pendingFees1;
        uint256 feesOwed0;
        uint256 feesOwed1;
        uint256 totalSupplyOfTokenId;
        uint256 amount0;
        uint256 amount1;
    }

    function calculateExactedValueOfTokenIdAfterUnwrap(
        uint256 tokenId,
        uint256 unwrapAmount,
        uint256 balanceBeforeUnwrap
    ) public view returns (uint256) {
        // if unwrap amount is equal to current total supply, then value after unwrap is 0
        if (totalSupply(tokenId) == unwrapAmount) {
            return 0;
        }

        Local memory local;

        // we first simulate what happens to the fees when partial unwrap is done
        // we update the feesOwed so that after the unwrap we simply assume the pending fees are zero

        (local.sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());
        PositionState memory positionState = _getPositionState(tokenId, local.sqrtRatioX96);

        (local.pendingFees0, local.pendingFees1) = _pendingFees(positionState);

        local.feesOwed0 = tokensOwed[tokenId].fees0Owed;
        local.feesOwed1 = tokensOwed[tokenId].fees1Owed;

        local.feesOwed0 = (local.feesOwed0 + local.pendingFees0)
            - proportionalShare(local.pendingFees0 + local.feesOwed0, unwrapAmount, totalSupply(tokenId));
        local.feesOwed1 = (local.feesOwed1 + local.pendingFees1)
            - proportionalShare(local.pendingFees1 + local.feesOwed1, unwrapAmount, totalSupply(tokenId));

        // now we calculate the principal after the unwrap
        positionState.liquidity -= proportionalShare(
                uint256(positionState.liquidity), unwrapAmount, totalSupply(tokenId)
            ).toUint128();

        local.totalSupplyOfTokenId = totalSupply(tokenId) - unwrapAmount;

        (local.amount0, local.amount1) = _principal(
            positionState,
            proportionalShare(
                    uint256(positionState.liquidity), balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId
                ).toUint128()
        );

        local.amount0 += proportionalShare(
            local.feesOwed0, balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId
        );
        local.amount1 += proportionalShare(
            local.feesOwed1, balanceBeforeUnwrap - unwrapAmount, local.totalSupplyOfTokenId
        );

        return getQuote(local.amount0, _getCurrencyAddress(currency0))
            + getQuote(local.amount1, _getCurrencyAddress(currency1));
    }

    //All of tests uses the spot price from the pool instead of the oracle
    function getSqrtRatioX96(address, address, uint256, uint256) public view override returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96,,,) = poolManager.getSlot0(poolKey.toId());
    }

    function getSqrtRatioX96FromOracle(address token0, address token1, uint256 unit0, uint256 unit1)
        public
        view
        returns (uint160 sqrtRatioX96)
    {
        return super.getSqrtRatioX96(token0, token1, unit0, unit1);
    }
}
