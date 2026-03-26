// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IPartialERC20} from "src/interfaces/IPartialERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

interface IERC721WrapperBase is IPartialERC20 {
    function FULL_AMOUNT() external pure returns (uint256); // D36{share} freely-transferable share supply per tokenId
    function MINIMUM_AMOUNT() external pure returns (uint256); // D36{share} permanently locked to address(1)
    function MAX_TOKENIDS_ALLOWED() external pure returns (uint256);
    function underlying() external view returns (IERC721);
    function oracle() external view returns (IPriceOracle);
    function unitOfAccount() external view returns (address);

    function wrap(uint256 tokenId, address to) external;
    function unwrap(address from, uint256 tokenId, address to) external;
    /// @param amount {share} D36 ERC6909 share amount to burn and redeem proportionally
    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData) external;
    function enableTokenIdAsCollateral(uint256 tokenId) external returns (bool enabled);
    function disableTokenIdAsCollateral(uint256 tokenId) external returns (bool disabled);
    function getEnabledTokenIds(address owner) external view returns (uint256[] memory);
    function totalTokenIdsEnabledBy(address owner) external view returns (uint256);
    function tokenIdOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    /// @param inAmount  {tok} amount of `base` token to price
    /// @return outAmount {UoA} value in unit-of-account terms
    function getQuote(uint256 inAmount, address base) external view returns (uint256 outAmount);
    function skim(address to) external;
    function enableCurrentSkimCandidateAsCollateral() external returns (bool);
    function validatePosition(uint256 tokenId) external view;
    function getTokenIdToSkim() external view returns (uint256);
    /// @param amount  {share} D36 ERC6909 share balance being valued
    /// @return        {UoA} proportional value in unit-of-account terms
    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) external view returns (uint256);
    /// @param amount              quantity to scale (any token dimension)
    /// @param part                {share} D36 caller's share balance
    /// @param totalSupplyOfTokenId {share} D36 total supply for the tokenId
    /// @return                    same dimension as `amount`
    function proportionalShare(uint256 amount, uint256 part, uint256 totalSupplyOfTokenId)
        external
        pure
        returns (uint256);
}
