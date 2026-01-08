// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// This contract can set approval to any address. This contract is not meant to hold funds
contract GenericRouter {
    using SafeERC20 for IERC20;

    error ExchangeCallFailed();
    error OnlyVaultAllowed();

    address public immutable vault;

    constructor() {
        vault = msg.sender;
    }

    function executeSwap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        address exchange,
        address approvalSpender,
        bytes calldata exchangeData
    ) external {
        if (msg.sender != vault) {
            revert OnlyVaultAllowed();
        }

        // ask the exchange to use all the available balance
        (bool success,) = exchange.call(exchangeData);
        if (!success) {
            // it might because of lack of approval
            // we use this trick to avoid having to approve the same contract everytime
            tokenIn.forceApprove(approvalSpender, type(uint256).max);

            (bool successWithApproval,) = exchange.call(exchangeData);
            if (!successWithApproval) {
                revert ExchangeCallFailed();
            }
        }

        uint256 tokenOutBalance = tokenOut.balanceOf(address(this));
        // it is ok if the exchange directly transfers the tokenOut to vault
        if (tokenOutBalance > 0) {
            tokenOut.safeTransfer(msg.sender, tokenOutBalance);
        }
    }
}
