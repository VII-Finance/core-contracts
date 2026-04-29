// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/**
 * @title IPartialERC20
 * @notice Interface expected by a Vault built with the Euler Vault Kit for interacting with other vaults.
 * @dev This interface defines the minimal ERC20 functionality required: `balanceOf` and `transfer`.
 *      Typically, other vaults are ERC4626-compliant and thus also implement the full ERC20 standard,
 *      making them compatible with this interface. In the case of VII Finance collateral-only vaults (ERC721WrapperBase),
 *      this interface will be implemented, but with different internal logic than simple reading of balances and transferring tokens.
 */
interface IPartialERC20 {
    /// @return {UoA} total position value for `owner` in unit-of-account terms (as implemented by ERC721WrapperBase)
    function balanceOf(address owner) external view returns (uint256);
    /// @param amount {UoA} vault-level share amount; internally redistributed as proportional ERC6909 tokens
    function transfer(address to, uint256 amount) external returns (bool);
}
