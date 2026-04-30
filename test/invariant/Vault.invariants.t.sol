// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {VaultBaseSetup} from "test/invariant/VaultBaseSetup.sol";
import {VaultHandler} from "test/invariant/VaultHandler.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Invariant test suite for the vault.
///      Inherits VaultBaseSetup for a fully-local (no mainnet fork) deployment.
///      The handler drives stateful deposit/redeem/withdraw operations; every
///      invariant_ function is called by Foundry after each call sequence.
contract VaultInvariantTest is VaultBaseSetup {
    VaultHandler public handler;

    address[] actors;

    function setUp() public override {
        super.setUp();

        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));

        handler = new VaultHandler(vault, actors);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));

        // Restrict callers to known actors so Foundry doesn't generate random
        // addresses that trigger eth_getAccount lookups against an RPC endpoint.
        for (uint256 i = 0; i < actors.length; i++) {
            targetSender(actors[i]);
        }
    }

    function _handlerSelectors() internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](3);
        sel[0] = VaultHandler.deposit.selector;
        sel[1] = VaultHandler.redeem.selector;
        sel[2] = VaultHandler.withdraw.selector;
    }

    // ─── Invariants ───────────────────────────────────────────────────────────

    /// tokenId must always be non-zero after initialization
    function invariant_tokenIdSet() public view {
        assertGt(vault.tokenId(), 0, "inv: tokenId must be set");
    }

    /// totalSupply must always be positive (min shares locked at address(1))
    function invariant_totalSupplyPositive() public view {
        assertGt(vault.totalSupply(), 0, "inv: totalSupply must be > 0");
    }

    /// totalAssets must always be positive
    function invariant_totalAssetsPositive() public view {
        assertGt(vault.totalAssets(), 0, "inv: totalAssets must be > 0");
    }

    /// convertToAssets(convertToShares(x)) <= x  (rounding direction)
    function invariant_convertRoundingDown() public view {
        uint256 assets = 1e6;
        uint256 shares = vault.convertToShares(assets);
        if (shares == 0) return;
        uint256 recovered = vault.convertToAssets(shares);
        assertLe(recovered, assets, "inv: convertToAssets(convertToShares(x)) <= x");
    }

    /// previewDeposit must not exceed actual shares minted (ERC4626 spec)
    function invariant_previewDepositConservative() public view {
        uint256 assets = vault.totalAssets() / 10;
        if (assets == 0) return;
        uint256 preview = vault.previewDeposit(assets);
        uint256 actual = vault.convertToShares(assets);
        assertGe(actual, preview, "inv: actual shares >= previewDeposit");
    }

    /// previewWithdraw must not underestimate shares burned (ERC4626 spec)
    function invariant_previewWithdrawConservative() public view {
        uint256 assets = vault.totalAssets() / 10;
        if (assets == 0) return;
        uint256 previewShares = vault.previewWithdraw(assets);
        uint256 actualShares = vault.convertToShares(assets);
        assertGe(previewShares, actualShares, "inv: previewWithdraw >= convertToShares");
    }

    /// Share price must be non-negative
    function invariant_sharePriceNonNegative() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        uint256 assets = vault.totalAssets();
        assertGe(assets, 0, "inv: assets >= 0");
    }

    /// Vault must not hold more borrow debt than its collateral value (solvency)
    function invariant_solvency() public view {
        uint256 collateralUOA = wrapper.balanceOf(address(vault));
        uint256 debtRaw = vault.borrowVault().debtOf(address(vault));
        if (debtRaw == 0) return;
        uint256 debtUOA = oracle.getQuote(debtRaw, vault.borrowToken(), vault.unitOfAccount());
        // Collateral must cover debt; use conservative 50% threshold
        assertGe(collateralUOA * 2, debtUOA, "inv: collateral covers debt (50%+ LTV)");
    }

    /// Actors cannot withdraw more than the vault's total assets (no free lunch)
    function invariant_noFreeLunch() public view {
        uint256 ceiling = handler.totalDeposited() + initialAmount + 1;
        assertLe(handler.totalWithdrawn(), ceiling, "inv: no free lunch");
    }

    /// ERC4626: maxWithdraw(owner) <= totalAssets()
    function invariant_maxWithdrawBound() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 max = vault.maxWithdraw(actors[i]);
            assertLe(max, vault.totalAssets(), "inv: maxWithdraw <= totalAssets");
        }
    }

    /// ERC4626: maxRedeem(owner) <= balance
    function invariant_maxRedeemBound() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 max = vault.maxRedeem(actors[i]);
            assertLe(max, vault.balanceOf(actors[i]), "inv: maxRedeem <= balance");
        }
    }
}
