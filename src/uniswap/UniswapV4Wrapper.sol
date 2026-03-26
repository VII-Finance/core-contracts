// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";

/// @title EVC aware collateral only vault for Uniswap V4 liquidity positions
/// @author VII Finance
/// @notice This contract allows EVK vaults to accept Uniswap V4 liquidity positions as collateral
/// @dev This wrapper is intended exclusively for vanilla Uniswap V4 pools.
/// @dev This wrapper is compatible with the pools with yield harvesting hook (https://github.com/VII-Finance/yield-harvesting-hook)
///      Expected behaviour: For pools with yield harvesting hook, the pending yield that is not yet harvested will not be considered in the collateral value.
/// @dev Before using this for pools with other custom hooks, ensure that the custom hook does not alter how a liquidity position is priced.
contract UniswapV4Wrapper is ERC721WrapperBase {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    address public immutable weth;

    PoolId public immutable poolId;
    IPoolManager public immutable poolManager;
    uint256 public immutable unit0; // {unit} = 10**decimals0; one canonical unit of currency0
    uint256 public immutable unit1; // {unit} = 10**decimals1; one canonical unit of currency1

    Currency public immutable currency0;
    Currency public immutable currency1;

    PoolKey public poolKey;
    mapping(uint256 tokenId => TokensOwed) public tokensOwed;

    /// @notice Tracks the amount of fees owed to tokenId holders for both tokens.
    /// @dev In Uniswap V3, when liquidity is modified, the pool does not immediately send fees accrued to the user.
    ///      Instead, it increases the position's `tokensOwed` balance in an internal mapping, and the user must call `collect` to receive the tokens.
    ///      In Uniswap V4, the PoolManager expects fees to be settled (sent to the user) immediately when liquidity is modified.
    ///      However, since ERC6909 token IDs can have multiple holders, we only know about the share of the owner who is unwrapping their portion.
    ///      Therefore, we must keep track of `feesOwed` here to ensure each holder receives the correct amount, rather than settling all fees at once.
    ///      This state is maintained to accurately account for and distribute fees to each partial owner when they interact with their position.
    ///      For this reason, this contract is expected to hold some currency0 and currency1 tokens till all of the tokenId holders have unwrapped.
    struct TokensOwed {
        uint256 fees0Owed; // {tok0} cumulative token0 fees held by this contract on behalf of remaining tokenId holders
        uint256 fees1Owed; // {tok1} cumulative token1 fees held by this contract on behalf of remaining tokenId holders
    }

    struct PositionState {
        PositionInfo position;
        uint128 liquidity; // {liq} position liquidity
        uint256 feeGrowthInside0LastX128; // QX128{tok0/liq} last-recorded fee growth inside range for token0
        uint256 feeGrowthInside1LastX128; // QX128{tok1/liq} last-recorded fee growth inside range for token1
        uint160 sqrtRatioX96; // QX96{sqrt(tok1/tok0)} sqrt price at time of state snapshot
    }

    error InvalidPoolId(PoolId actualPoolId, PoolId expectedPoolId);
    error InvalidWETHAddress();

    constructor(
        address _evc,
        address _positionManager,
        address _oracle,
        address _unitOfAccount,
        PoolKey memory _poolKey,
        address _weth
    ) ERC721WrapperBase(_evc, _positionManager, _oracle, _unitOfAccount) {
        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;

        poolKey = _poolKey;
        poolId = _poolKey.toId();
        poolManager = IPositionManager(address(_positionManager)).poolManager();

        if (_poolKey.currency0.isAddressZero()) {
            if (_weth == address(0)) revert InvalidWETHAddress();
            weth = _weth;
        }

        unit0 = 10 ** _getDecimals(_getCurrencyAddress(_poolKey.currency0));
        unit1 = 10 ** _getDecimals(_getCurrencyAddress(_poolKey.currency1));
    }

    /// @notice Validates that the position belongs to the pool that this wrapper is associated with
    /// @param tokenId The token ID to validate
    function validatePosition(uint256 tokenId) public view override {
        (PoolKey memory poolKeyOfTokenId,) = IPositionManager(address(underlying)).getPoolAndPositionInfo(tokenId);
        PoolId poolIdOfTokenId = poolKeyOfTokenId.toId();

        if (PoolId.unwrap(poolIdOfTokenId) != PoolId.unwrap(poolId)) {
            revert InvalidPoolId(poolIdOfTokenId, poolId);
        }
    }

    /// @notice Unwraps a position by removing proportional liquidity and send the resulting tokens and proportional fees to the recipient
    /// @param to The recipient address
    /// @param tokenId The position token ID
    /// @param totalSupplyOfTokenId {share} D36 total ERC6909 supply for tokenId
    /// @param amount {share} D36 ERC6909 share amount being unwrapped
    /// @param extraData Additional parameters for the unwrap operation (uint128 amount0Min, uint128 amount1Min, uint256 deadline encoded)
    function _unwrap(
        address to,
        uint256 tokenId,
        uint256 totalSupplyOfTokenId,
        uint256 amount,
        bytes calldata extraData
    ) internal override {
        uint256 amount0; // {tok0} principal token0 corresponding to liquidityToRemove
        uint256 amount1; // {tok1} principal token1 corresponding to liquidityToRemove

        TokensOwed memory feesOwed = tokensOwed[tokenId];

        {
            // Here we are using the pool's spot price to calculate how much the liquidity is worth in underlying tokens
            (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId); // QX96{sqrt(tok1/tok0)}
            PositionState memory positionState = _getPositionState(tokenId, sqrtRatioX96);
            // {liq} = {liq} * {share} / {share}
            uint128 liquidityToRemove = // {liq} proportional liquidity to remove for this unwrap amount
                proportionalShare(positionState.liquidity, amount, totalSupplyOfTokenId).toUint128();
            (amount0, amount1) = _principal(positionState, liquidityToRemove);

            (uint256 amount0Received, uint256 amount1Received) =
                _decreaseLiquidity(tokenId, liquidityToRemove, ActionConstants.MSG_SENDER, extraData);
            // amount0Received: {tok0}, amount1Received: {tok1}

            // excess over principal = fees collected; accumulate for remaining holders
            feesOwed.fees0Owed += amount0Received - amount0; // {tok0}
            feesOwed.fees1Owed += amount1Received - amount1; // {tok1}
        }

        // {tok0} = {tok0} * {share} / {share}
        uint256 fees0ToSend = proportionalShare(feesOwed.fees0Owed, amount, totalSupplyOfTokenId);
        // {tok1} = {tok1} * {share} / {share}
        uint256 fees1ToSend = proportionalShare(feesOwed.fees1Owed, amount, totalSupplyOfTokenId);

        feesOwed.fees0Owed -= fees0ToSend; // {tok0} remainder stays for other holders
        feesOwed.fees1Owed -= fees1ToSend; // {tok1} remainder stays for other holders

        tokensOwed[tokenId] = feesOwed;

        uint256 currency1AmountToTransfer = amount1 + fees1ToSend; // {tok1}
        uint256 currency0AmountToTransfer = amount0 + fees0ToSend; // {tok0}

        if (currency1AmountToTransfer > 0) currency1.transfer(to, amount1 + fees1ToSend);
        // currency0 can be native ETH, where we know for sure that reentrancy is possible.
        // We keep this transfer at the very end of the action to minimize risk.
        if (currency0AmountToTransfer > 0) currency0.transfer(to, amount0 + fees0ToSend);
    }

    function _settleFullUnwrap(uint256 tokenId, address to) internal override {
        uint256 fees0ToSend = tokensOwed[tokenId].fees0Owed; // {tok0}
        uint256 fees1ToSend = tokensOwed[tokenId].fees1Owed; // {tok1}
        delete tokensOwed[tokenId];
        if (fees1ToSend > 0) currency1.transfer(to, fees1ToSend);

        // currency0 can be native ETH, where we know for sure that reentrancy is possible.
        // We keep this transfer at the very end of the action to minimize risk.
        if (fees0ToSend > 0) currency0.transfer(to, fees0ToSend);
    }

    /// @notice Calculates the proportional value of a position in unit of account terms
    /// @dev This calculation disregards the current pool spot price and instead uses the oracle price
    ///      to determine how much the liquidity position is worth
    /// @param tokenId The ID of the position token to evaluate
    /// @param amount {share} D36 ERC6909 share balance being valued
    /// @return {UoA} proportional value of the specified position in unit-of-account terms
    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view override returns (uint256) {
        uint160 sqrtRatioX96 =
            getSqrtRatioX96(_getCurrencyAddress(currency0), _getCurrencyAddress(currency1), unit0, unit1); // QX96{sqrt(tok1/tok0)}

        (uint256 amount0, uint256 amount1) = previewUnwrap(tokenId, sqrtRatioX96, amount);
        // amount0: {tok0}, amount1: {tok1}

        uint256 amount0InUnitOfAccount = getQuote(amount0, _getCurrencyAddress(currency0)); // {UoA}
        uint256 amount1InUnitOfAccount = getQuote(amount1, _getCurrencyAddress(currency1)); // {UoA}

        return amount0InUnitOfAccount + amount1InUnitOfAccount; // {UoA}
    }

    /// @param sqrtRatioX96  QX96{sqrt(tok1/tok0)} oracle-derived sqrt price for valuation
    /// @param unwrapAmount  {share} D36 share amount being previewed
    /// @return amount0      {tok0} estimated token0 to be received (principal + proportional fees)
    /// @return amount1      {tok1} estimated token1 to be received (principal + proportional fees)
    function previewUnwrap(uint256 tokenId, uint160 sqrtRatioX96, uint256 unwrapAmount)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PositionState memory positionState = _getPositionState(tokenId, sqrtRatioX96);

        uint256 totalSupplyOfTokenId = totalSupply(tokenId); // {share} D36

        // {liq} = {liq} * {share} / {share}
        uint128 liquidityToRemove = // {liq} proportional liquidity corresponding to unwrapAmount shares
            proportionalShare(positionState.liquidity, unwrapAmount, totalSupplyOfTokenId).toUint128();
        (amount0, amount1) = _principal(positionState, liquidityToRemove);
        // amount0: {tok0}, amount1: {tok1}

        (uint256 pendingFees0, uint256 pendingFees1) = _pendingFees(positionState);
        // pendingFees0: {tok0}, pendingFees1: {tok1}

        // {tok0} += ({tok0} + {tok0}) * {share} / {share}
        amount0 += proportionalShare(pendingFees0 + tokensOwed[tokenId].fees0Owed, unwrapAmount, totalSupplyOfTokenId);
        // {tok1} += ({tok1} + {tok1}) * {share} / {share}
        amount1 += proportionalShare(pendingFees1 + tokensOwed[tokenId].fees1Owed, unwrapAmount, totalSupplyOfTokenId);
    }

    /// @notice Gets the token ID that was just minted
    /// @dev It returns the last tokenId that was minted on the positionManager,
    ///      not necessarily the last tokenId that was sent to this contract.
    /// @dev This is used so that user can directly send the freshly minted token to this wrapper and skim it
    /// @dev It helps with batching mint and wrap operations efficiently
    /// @return The latest token ID
    function getTokenIdToSkim() public view override returns (uint256) {
        return IPositionManager(address(underlying)).nextTokenId() - 1;
    }

    /// @notice Gets the current state of a position
    /// @param tokenId The position token ID
    /// @param sqrtRatioX96 QX96{sqrt(tok1/tok0)} the sqrt price ratio to use for calculations
    /// @return positionState The complete position state
    function _getPositionState(uint256 tokenId, uint160 sqrtRatioX96)
        internal
        view
        returns (PositionState memory positionState)
    {
        PositionInfo position = IPositionManager(address(underlying)).positionInfo(tokenId);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            poolId, address(underlying), position.tickLower(), position.tickUpper(), bytes32(tokenId)
        );
        // liquidity: {liq} position liquidity from pool
        // feeGrowthInside0LastX128: QX128{tok0/liq} last-recorded fee growth inside range for token0
        // feeGrowthInside1LastX128: QX128{tok1/liq} last-recorded fee growth inside range for token1

        positionState = PositionState({
            position: position,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            sqrtRatioX96: sqrtRatioX96
        });
    }

    /// @notice Calculates pending fees for a position
    /// @dev For pools with the yield harvesting hook, this will under-calculate the pending fees because it does not account for interest fees that are pending and yet to be harvested.
    /// @dev We expect this miscalculation to be minimal, as a healthy swap frequency should ensure that the amount of unharvested pending interest remains low.
    /// @param positionState The position state
    /// @return feesOwed0 {tok0} pending fees for token0 not yet reflected in tokensOwed
    /// @return feesOwed1 {tok1} pending fees for token1 not yet reflected in tokensOwed
    function _pendingFees(PositionState memory positionState)
        internal
        view
        returns (uint256 feesOwed0, uint256 feesOwed1)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = poolManager.getFeeGrowthInside(
            poolId, positionState.position.tickLower(), positionState.position.tickUpper()
        );
        // feeGrowthInside0X128: QX128{tok0/liq}, feeGrowthInside1X128: QX128{tok1/liq}
        (feesOwed0, feesOwed1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            positionState.feeGrowthInside0LastX128,
            positionState.feeGrowthInside1LastX128,
            positionState.liquidity
        );
    }

    /// @notice Calculates principal amounts for a specific liquidity amount
    /// @param liquidity        {liq} liquidity to convert to token amounts
    /// @return principalAmount0 {tok0} token0 principal
    /// @return principalAmount1 {tok1} token1 principal
    function _principal(PositionState memory positionState, uint128 liquidity)
        internal
        pure
        returns (uint256 principalAmount0, uint256 principalAmount1)
    {
        (principalAmount0, principalAmount1) = UniswapPositionValueHelper.principal(
            positionState.sqrtRatioX96,
            positionState.position.tickLower(),
            positionState.position.tickUpper(),
            liquidity
        );
    }

    /// @param liquidity      {liq} proportional liquidity to remove
    /// @return amount0Received {tok0} token0 actually received (principal + fees)
    /// @return amount1Received {tok1} token1 actually received (principal + fees)
    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, address recipient, bytes calldata extraData)
        internal
        returns (uint256 amount0Received, uint256 amount1Received)
    {
        uint256 currency0BalanceBefore = currency0.balanceOfSelf(); // {tok0}
        uint256 currency1BalanceBefore = currency1.balanceOfSelf(); // {tok1}

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        (uint128 amount0Min, uint128 amount1Min, uint256 deadline) = _decodeExtraData(extraData);
        // amount0Min: {tok0}, amount1Min: {tok1}, deadline: {s}

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(currency0, currency1, recipient);

        IPositionManager(address(underlying)).modifyLiquidities(abi.encode(actions, params), deadline);

        amount0Received = currency0.balanceOfSelf() - currency0BalanceBefore; // {tok0}
        amount1Received = currency1.balanceOfSelf() - currency1BalanceBefore; // {tok1}
    }

    /// @return amount0Min {tok0} minimum token0 to receive (slippage protection)
    /// @return amount1Min {tok1} minimum token1 to receive (slippage protection)
    /// @return deadline   {s} Unix timestamp after which the transaction reverts
    function _decodeExtraData(bytes calldata extraData)
        internal
        view
        returns (uint128 amount0Min, uint128 amount1Min, uint256 deadline)
    {
        if (extraData.length == 96) {
            (amount0Min, amount1Min, deadline) = abi.decode(extraData, (uint128, uint128, uint256));
        } else {
            (amount0Min, amount1Min, deadline) = (0, 0, block.timestamp);
        }
    }

    function _getCurrencyAddress(Currency currency) internal view returns (address) {
        return currency.isAddressZero() ? weth : Currency.unwrap(currency);
    }

    /// @notice Allows the contract to receive ETH when `currency0` is the native ETH (address(0))
    receive() external payable {}
}
