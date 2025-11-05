// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";

contract UniswapV4Vault is BaseVault {
    constructor(IERC721WrapperBase _wrapper, IERC20 _asset) BaseVault(_wrapper, _asset) {}

    function _getTokens(address _wrapper) public view virtual override returns (address, address) {
        UniswapV4Wrapper v4wrapper = UniswapV4Wrapper(payable(_wrapper));
        Currency currency0 = v4wrapper.currency0();
        return (
            Currency.unwrap(currency0.isAddressZero() ? Currency.wrap(v4wrapper.weth()) : currency0),
            Currency.unwrap(v4wrapper.currency1())
        );
    }
}
