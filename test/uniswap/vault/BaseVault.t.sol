// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "lib/forge-std/src/console.sol";

abstract contract BaseVaultTest is UniswapBaseTest {
    using SafeERC20 for IERC20;
    //we assume everything is setup already in the parent contract
    BaseVault public vault;

    address initializer = makeAddr("initializer");
    address depositor = makeAddr("depositor");
    uint256 initialAmount;

    function setUp() public virtual override {
        UniswapBaseTest.setUp();
        vault = deployVault();
    }

    function deployVault() internal virtual returns (BaseVault);

    function test_basic_setup() public {}

    function test_initiate_vault() public {
        startHoax(initializer);
        deal(vault.asset(), initializer, initialAmount);
        IERC20(vault.asset()).forceApprove(address(vault), type(uint256).max);
        vault.initializeVault(initialAmount);
    }

    function test_totalAssets() public {
        test_initiate_vault();
        console.log("total assets after init", vault.totalAssets());
    }

    function test_deposit() public {
        test_initiate_vault();

        startHoax(depositor);
        deal(vault.asset(), depositor, initialAmount);
        IERC20(vault.asset()).forceApprove(address(vault), type(uint256).max);
        vault.deposit(initialAmount, depositor);
    }
}
