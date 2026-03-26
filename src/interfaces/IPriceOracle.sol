// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IPriceOracle {
    function name() external view returns (string memory);

    /// @param inAmount   {tok} D{tokenDecimals} amount of `base` token to convert
    /// @return outAmount {UoA} D{unitOfAccountDecimals} equivalent value in `quote` terms
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256 outAmount);

    /// @param inAmount      {tok} D{tokenDecimals} amount of `base` token to convert
    /// @return bidOutAmount {UoA} bid (lower) price — used when valuing collateral for liquidation
    /// @return askOutAmount {UoA} ask (upper) price — used for mid-point valuation
    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        returns (uint256 bidOutAmount, uint256 askOutAmount);
}
