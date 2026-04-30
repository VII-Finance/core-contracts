// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseVault} from "src/uniswap/vault/BaseVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Stateful handler for vault invariant testing.
///      Tracks ghost variables that invariants assert against.
contract VaultHandler is Test {
    using SafeERC20 for IERC20;

    BaseVault public immutable vault;
    IERC20 public immutable asset;

    address[] public actors;
    mapping(address => uint256) public deposited; // total assets deposited by actor
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(BaseVault _vault, address[] memory _actors) {
        vault = _vault;
        asset = IERC20(_vault.asset());
        actors = _actors;
    }

    // ─── Actions ──────────────────────────────────────────────────────────────

    function deposit(uint256 actorIdx, uint256 assets) external {
        actorIdx = bound(actorIdx, 0, actors.length - 1);
        address actor = actors[actorIdx];

        uint256 maxDeposit = vault.maxDeposit(actor);
        if (maxDeposit == 0) return;

        // Cap to 1000 tokens to stay well within borrow capacity and prevent
        // uint256 overflow in ERC20 share arithmetic when maxDeposit == type(uint256).max.
        uint256 cap = maxDeposit < 1000e18 ? maxDeposit : 1000e18;
        assets = bound(assets, 1, cap);
        deal(address(asset), actor, assets);

        vm.startPrank(actor);
        asset.forceApprove(address(vault), assets);
        try vault.deposit(assets, actor) {
            deposited[actor] += assets;
            totalDeposited += assets;
        } catch {}
        vm.stopPrank();
    }

    function redeem(uint256 actorIdx, uint256 shareFraction) external {
        actorIdx = bound(actorIdx, 0, actors.length - 1);
        address actor = actors[actorIdx];

        uint256 shares = vault.balanceOf(actor);
        if (shares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 toRedeem = shares * shareFraction / 100;
        if (toRedeem == 0) return;

        uint256 assetsBefore = asset.balanceOf(actor);
        vm.prank(actor);
        try vault.redeem(toRedeem, actor, actor) {
            uint256 received = asset.balanceOf(actor) - assetsBefore;
            totalWithdrawn += received;
        } catch {}
    }

    function withdraw(uint256 actorIdx, uint256 assetFraction) external {
        actorIdx = bound(actorIdx, 0, actors.length - 1);
        address actor = actors[actorIdx];

        uint256 maxWithdraw = vault.maxWithdraw(actor);
        if (maxWithdraw == 0) return;

        assetFraction = bound(assetFraction, 1, 100);
        uint256 assets = maxWithdraw * assetFraction / 100;
        if (assets == 0) return;

        uint256 assetsBefore = asset.balanceOf(actor);
        vm.prank(actor);
        try vault.withdraw(assets, actor, actor) {
            uint256 received = asset.balanceOf(actor) - assetsBefore;
            totalWithdrawn += received;
        } catch {}
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
