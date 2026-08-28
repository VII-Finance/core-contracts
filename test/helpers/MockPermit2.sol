// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal Permit2 stub for local (non-fork) test environments.
///      The vault constructor calls approve() to register allowances, and the
///      EVault calls transferFrom() when pulling repayment tokens.  We forward
///      transferFrom() as a plain ERC20 call — this works because the vault
///      already ran forceApprove(permit2, max) for the borrow token, so Permit2
///      is a valid ERC20 spender for the vault's borrow token.
contract MockPermit2 {
    function approve(address, address, uint160, uint48) external {}

    function transferFrom(address from, address to, uint160 amount, address token) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}
