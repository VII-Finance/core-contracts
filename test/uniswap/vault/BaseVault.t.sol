// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";

abstract contract BaseVaultTest is UniswapBaseTest {
    //we assume everything is setup already in the parent contract
    BaseVault public vault;

    function setUp() public override {
        UniswapBaseTest.setUp();
        vault = deployVault();
    }

    function deployVault() internal virtual returns (BaseVault);

    function test_basic_setup() public {}
}
