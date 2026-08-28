// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {
    INonfungiblePositionManager,
    IERC721Enumerable
} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";

/// @title EVC aware collateral only vault for Uniswap V3 liquidity positions
/// @author VII Finance
/// @notice This contract allows EVK vaults to accept Uniswap V3 liquidity positions as collateral
contract UniswapV3Wrapper is ERC721WrapperBase {
    IUniswapV3Pool public immutable pool;
    IUniswapV3Factory public immutable factory;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee; // {bps} pool fee tier (e.g. 3000 = 0.3%)
    uint256 public immutable unit0; // {unit} = 10**decimals0; one canonical unit of token0
    uint256 public immutable unit1; // {unit} = 10**decimals1; one canonical unit of token1

    error InvalidPoolAddress();
    error NothingToCollect();

    using SafeCast for uint256;

    constructor(
        address _evc,
        address _nonFungiblePositionManager,
        address _oracle,
        address _unitOfAccount,
        address _poolAddress
    ) ERC721WrapperBase(_evc, _nonFungiblePositionManager, _oracle, _unitOfAccount) {
        pool = IUniswapV3Pool(_poolAddress);
        fee = pool.fee();
        address token0_ = pool.token0();
        address token1_ = pool.token1();

        token0 = token0_;
        token1 = token1_;

        unit0 = 10 ** _getDecimals(token0_);
        unit1 = 10 ** _getDecimals(token1_);

        factory = IUniswapV3Factory(INonfungiblePositionManager(address(underlying)).factory());
    }

    /// @notice Validates that the position belongs to the pool that this wrapper is associated with
    /// @param tokenId The token ID to validate
    function validatePosition(uint256 tokenId) public view override {
        (,, address token0OfTokenId, address token1OfTokenId, uint24 feeOfTokenId,,,,,,,) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        // feeOfTokenId: {bps} pool fee tier of the queried position
        address poolOfTokenId = factory.getPool(token0OfTokenId, token1OfTokenId, feeOfTokenId);
        if (poolOfTokenId != address(pool)) revert InvalidPoolAddress();
    }

    /// @notice Unwraps a position by removing proportional liquidity and sending the corresponding principal + fees to the recipient
    /// @param to The recipient address
    /// @param tokenId The position token ID
    /// @param totalSupplyOfTokenId {share} D36 total ERC6909 supply for tokenId
    /// @param amount {share} D36 ERC6909 share amount being unwrapped
    /// @param extraData Additional parameters for the unwrap operation (uint256 amount0Min, uint256 amount1Min, uint256 deadline encoded)
    function _unwrap(
        address to,
        uint256 tokenId,
        uint256 totalSupplyOfTokenId,
        uint256 amount,
        bytes calldata extraData
    ) internal override {
        uint256 amount0ToCollect; // {tok0} total token0 to collect (principal + fees)
        uint256 amount1ToCollect; // {tok1} total token1 to collect (principal + fees)

        bool isDecreaseLiquidityCalled;
        {
            (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(address(underlying)).positions(tokenId);
            // liquidity: {liq} current total liquidity of the position

            // Compute proportional liquidity to remove based on shares being unwrapped
            (isDecreaseLiquidityCalled, amount0ToCollect, amount1ToCollect) = _decreaseLiquidity(
                tokenId, proportionalShare(uint256(liquidity), amount, totalSupplyOfTokenId).toUint128(), extraData
            );
            // amount0ToCollect / amount1ToCollect now include principal withdrawn from liquidity (if decreaseLiquidity was called)
        }

        {
            (
                ,,,,,,,,,,
                uint256 tokensOwed0,
                uint256 tokensOwed1
                // tokensOwed0 / tokensOwed1: total claimable amounts
                // Includes withdrawn principal (if any) + fees already checkpointed
            ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

            if (!isDecreaseLiquidityCalled) {
                // If liquidity was not decreased, pending fees are not included in tokensOwed yet.
                // We must manually compute pending fees and include them.

                PositionInfo memory position;
                (
                    ,,,,,
                    position.tickLower,
                    position.tickUpper,
                    position.liquidity,
                    position.feeGrowthInside0LastX128,
                    position.feeGrowthInside1LastX128,,
                ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

                // Get current fee growth inside the position range
                (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                    _getFeeGrowthInside(position.tickLower, position.tickUpper);

                // Compute uncollected fees since last checkpoint
                (uint256 pendingFees0, uint256 pendingFees1) = UniswapPositionValueHelper.feesOwed(
                    feeGrowthInside0X128,
                    feeGrowthInside1X128,
                    position.feeGrowthInside0LastX128,
                    position.feeGrowthInside1LastX128,
                    position.liquidity
                );

                tokensOwed0 += pendingFees0;
                tokensOwed1 += pendingFees1;
            }

            // tokensOwed includes:
            // - principal withdrawn (if decreaseLiquidity was called)
            // - all accumulated fees

            // Extract the fee portion by removing principal, then take proportional share of fees
            amount0ToCollect =
                amount0ToCollect + proportionalShare((tokensOwed0 - amount0ToCollect), amount, totalSupplyOfTokenId);

            amount1ToCollect =
                amount1ToCollect + proportionalShare((tokensOwed1 - amount1ToCollect), amount, totalSupplyOfTokenId);
        }

        // Revert when nothing would be collected and this is not a user-full-unwrap.
        // A user-full-unwrap (burning FULL_AMOUNT, leaving only MINIMUM_AMOUNT dust) is allowed
        // to proceed with zero amounts — it's cleaning up a tiny/out-of-range position.
        // A partial unwrap that yields nothing must revert to prevent burning shares for nothing.
        bool isUserFullUnwrap = totalSupplyOfTokenId - amount <= MINIMUM_AMOUNT;
        if (!isUserFullUnwrap && amount0ToCollect == 0 && amount1ToCollect == 0) {
            revert NothingToCollect();
        }

        // Collect the computed proportional principal + fees to the recipient.
        if (amount0ToCollect > 0 || amount1ToCollect > 0) {
            INonfungiblePositionManager(address(underlying))
                .collect(
                    INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: to,
                    amount0Max: amount0ToCollect.toUint128(), // {tok0} total to transfer
                    amount1Max: amount1ToCollect.toUint128() // {tok1} total to transfer
                })
                );
        }
    }

    function _settleFullUnwrap(uint256 tokenId, address to) internal override {}

    /// @param liquidity {liq} proportional liquidity to remove
    ///@return isDecreaseLiquidityCalled
    /// @return amount0  {tok0} token0 principal returned from the pool
    /// @return amount1  {tok1} token1 principal returned from the pool

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, bytes calldata extraData)
        internal
        returns (bool isDecreaseLiquidityCalled, uint256 amount0, uint256 amount1)
    {
        if (liquidity != 0) {
            isDecreaseLiquidityCalled = true;
            (
                uint256 amount0Min,
                uint256 amount1Min,
                uint256 deadline
                // amount0Min: {tok0}, amount1Min: {tok1}, deadline: {s}
            ) = extraData.length == 96 ? abi.decode(extraData, (uint256, uint256, uint256)) : (0, 0, block.timestamp);

            (amount0, amount1) = INonfungiblePositionManager(address(underlying))
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                })
                );
        }
    }

    /// @dev Returns the last tokenId owned by this contract from the NonFungiblePositionManager,
    ///      which implements ERC721Enumerable.
    /// @notice This function assumes that a user mints an NFT, sends it to this contract,
    ///         and then calls skim in the same tx. If any unwrap occurs in between, this logic may not work as expected.
    function getTokenIdToSkim() public view override returns (uint256) {
        uint256 totalTokensOwnedByThis = IERC721Enumerable(address(underlying)).balanceOf(address(this)); // dimensionless NFT count
        return IERC721Enumerable(address(underlying)).tokenOfOwnerByIndex(address(this), totalTokensOwnedByThis - 1);
    }

    /// @param amount  {share} D36 ERC6909 share balance of the caller for this tokenId
    /// @return        {UoA} proportional value of the position in unit-of-account terms
    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view override returns (uint256) {
        uint160 sqrtRatioX96 = getSqrtRatioX96(token0, token1, unit0, unit1); // QX96{sqrt(tok1/tok0)}

        (uint256 amount0, uint256 amount1) = previewUnwrap(tokenId, sqrtRatioX96, amount);
        // amount0: {tok0}, amount1: {tok1}

        uint256 amount0InUnitOfAccount = getQuote(amount0, token0); // {UoA}
        uint256 amount1InUnitOfAccount = getQuote(amount1, token1); // {UoA}

        return amount0InUnitOfAccount + amount1InUnitOfAccount; // {UoA}
    }

    struct PositionInfo {
        int24 tickLower; // {tick} lower tick of the position range
        int24 tickUpper; // {tick} upper tick of the position range
        uint128 liquidity; // {liq} position liquidity
        uint256 feeGrowthInside0LastX128; // QX128{tok0/liq} last-recorded fee growth inside range for token0
        uint256 feeGrowthInside1LastX128; // QX128{tok1/liq} last-recorded fee growth inside range for token1
        uint128 tokensOwed0; // {tok0} accrued token0 fees owed (already checkpointed)
        uint128 tokensOwed1; // {tok1} accrued token1 fees owed (already checkpointed)
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
        PositionInfo memory position;
        (
            ,,,,,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

        uint256 totalSupplyOfTokenId = totalSupply(tokenId); // {share} D36

        // principal amount but only corresponding to the unwrap amount
        // {liq} = {liq} * {share} / {share}
        (amount0, amount1) = UniswapPositionValueHelper.principal(
            sqrtRatioX96,
            position.tickLower,
            position.tickUpper,
            proportionalShare(uint256(position.liquidity), unwrapAmount, totalSupplyOfTokenId).toUint128()
        );
        // amount0: {tok0}, amount1: {tok1}

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            _getFeeGrowthInside(position.tickLower, position.tickUpper);
        // feeGrowthInside0X128: QX128{tok0/liq}, feeGrowthInside1X128: QX128{tok1/liq}
        // fees that are not accounted for yet for the entire tokenId
        (uint256 pendingFees0, uint256 pendingFees1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.liquidity
        );
        // pendingFees0: {tok0}, pendingFees1: {tok1}

        // we take the proportional share of the pending fees and the tokens owed + principal
        // {tok0} += ({tok0} + {tok0}) * {share} / {share}
        amount0 += proportionalShare(pendingFees0 + position.tokensOwed0, unwrapAmount, totalSupplyOfTokenId);
        // {tok1} += ({tok1} + {tok1}) * {share} / {share}
        amount1 += proportionalShare(pendingFees1 + position.tokensOwed1, unwrapAmount, totalSupplyOfTokenId);
    }

    /// @param tickLower {tick} lower tick of the position range
    /// @param tickUpper {tick} upper tick of the position range
    /// @return feeGrowthInside0X128 QX128{tok0/liq} current cumulative fee growth inside range for token0
    /// @return feeGrowthInside1X128 QX128{tok1/liq} current cumulative fee growth inside range for token1
    function _getFeeGrowthInside(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,,,,) = pool.slot0(); // tickCurrent: {tick}
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        // lowerFeeGrowthOutside0X128: QX128{tok0/liq}, lowerFeeGrowthOutside1X128: QX128{tok1/liq}
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);
        // upperFeeGrowthOutside0X128: QX128{tok0/liq}, upperFeeGrowthOutside1X128: QX128{tok1/liq}

        // calculate fee growth inside. the calculation relied on unchecked arithmetic
        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128(); // QX128{tok0/liq}
                uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128(); // QX128{tok1/liq}
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }
}
