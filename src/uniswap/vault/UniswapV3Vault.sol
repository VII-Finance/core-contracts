// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC721WrapperBase} from "src/interfaces/IERC721WrapperBase.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";

contract UniswapV3Vault is BaseVault {
    constructor(IERC721WrapperBase _wrapper, IERC20 _asset) BaseVault(_wrapper, _asset) {}

    function _getTokens(address _wrapper) public view virtual override returns (address, address) {
        return (UniswapV3Wrapper(_wrapper).token0(), UniswapV3Wrapper(_wrapper).token1());
    }
}
