# Vault Spec

## Overview

The vault is an ERC4626 vault that accepts a single asset (e.g. WETH) and deploys it as a leveraged Uniswap liquidity position. The core loop:

1. User deposits ETH
2. Vault borrows USDC from an Euler lending market (using the LP position as collateral)
3. ETH + USDC are provided as Uniswap liquidity
4. The wrapped LP NFT (ERC6909) is posted as collateral in Euler to back the USDC debt

At 2x leverage: deposit 1 ETH → borrow 1 ETH worth of USDC → LP = 2 ETH worth → debt = 1 ETH worth → net = 1 ETH.

The system is general: leverage can be any N ≥ 1. At Nx: deposit A → collateral = N*A → debt = (N-1)*A.

## Architecture

```
User → BaseVault (ERC4626) → EVC batch
                               ├─ EVault.borrow (USDC debt)
                               ├─ UniswapV3/V4Wrapper (LP collateral)
                               └─ GenericRouter (aggregator swaps)
```

Key contracts:
- `BaseVault` — abstract ERC4626 + EVCUtil, holds all core logic
- `UniswapV3Vault` / `UniswapV4Vault` — concrete vaults, implement V3/V4 position management
- `GenericRouter` — immutable helper that holds approvals and executes aggregator swap calldata
- `UniswapV3Wrapper` / `UniswapV4Wrapper` — ERC6909 wrappers that let Euler accept LP NFTs as collateral

Storage that matters:
- `tokenId` — the single LP position owned by the vault (set in `initializeVault`)
- `tickLower` / `tickUpper` — current position range
- `TARGET_LEVERAGE` — target leverage ratio (18-decimal fixed-point, currently hardcoded 2e18)

## Leverage Model

### Current (2x only)

`getDebtAmount(assetAmount)` computes:
- Liquidity from the asset side using `getLiquidityForAmount0` or `getLiquidityForAmount1`
- Then the matching borrow side amount using `getAmountForLiquidity` on the other side

This is correct for 2x because at current price, equal dollar value of each token is needed to form the LP position. Depositing A ETH → borrow A*price USDC → LP collateral ≈ 2A ETH worth.

### Generalized to Nx

For arbitrary target leverage N, the approach depends on the ratio R of borrow-token dollar value to asset dollar value in the LP position at the current price and tick range.

For a full-range position R ≈ 1 (50/50 split), so "natural" leverage = 2x. For a narrow range near current price, R approaches 1. For a one-sided range (all asset, no borrow token), R = 0.

**To hit target leverage N:**

The total LP value must equal N * equity. Equity = asset deposited. So:

```
total_LP_value        = N * asset_value
borrow_token_in_LP    = total_LP_value * R / (1 + R)
asset_in_LP           = total_LP_value / (1 + R)
```

If `asset_in_LP > assetDeposited`: need to borrow extra and swap some borrow token → asset.
If `asset_in_LP < assetDeposited`: need to swap some asset → borrow token before providing liquidity.

For 2x with R=1: asset_in_LP = LP_value/2 = A, borrow_in_LP = A. Matches current behavior.

**Implementation plan for generalized leverage:**

1. Make `TARGET_LEVERAGE` a constructor parameter (still immutable for gas).
2. Extend `getDebtAmount` to accept `targetLeverage` and compute the correct borrow amount using the ratio R derived from the tick range and current price.
3. When N ≠ 2 (or more precisely when N ≠ 1+R), `_deposit` and `_withdraw` need a swap step:
   - If N > 2 (for full-range): borrow extra USDC, swap portion to ETH, then add liquidity
   - If N < 2: swap some ETH to USDC before borrowing, then add liquidity

For now the design prioritizes N=2 with full-range (or near full-range) ticks. Leverage generalization should be written to support N=2 first and extended later.

### Computing R (tick ratio)

```solidity
// given tickLower, tickUpper, currentSqrtPrice:
// get liquidity L for 1 unit of asset
// then compute how much borrow token that L requires
// R = borrow_amount_value / asset_amount_value = borrowAmount * borrowPrice / assetAmount * assetPrice
```

At R=1 (50/50), the existing `getDebtAmount` logic is exact. Keep it as-is for the 2x case.

## Core Functions

### `initializeVault(uint256 assetAmount)`

One-time setup. Mints the LP tokenId and locks minimum shares to address(1) to prevent inflation attacks.

Flow:
1. Pull asset from caller
2. `getDebtAmount(assetAmount)` → `debtAmount`, `liquidity`
3. EVC batch:
   - `borrowVault.borrow(debtAmount)`
   - `mintPosition(token0Amount, token1Amount, liquidity)` → sets `tokenId`

After the batch, `_mint(address(1), totalAssets())` locks permanent minimum shares.

### `_deposit(caller, receiver, assets, shares)`

Called by ERC4626 `deposit`/`mint` after shares are minted.

Flow:
1. `getDebtAmount(assets)` → `debtAmount`, `liquidity`
2. EVC batch:
   - `borrowVault.borrow(debtAmount, address(this))`
   - `wrapper.unwrap(address(this), tokenId, address(this))` (need raw NFT to add liquidity)
   - `increaseLiquidity(token0, token1, liquidity)` (re-wraps inside)

**Note**: Base ERC4626 `super._deposit` transfers assets from caller first, then we deploy them.

### `_withdraw(caller, receiver, owner, assets, shares)`

Flow:
1. `getDebtAmount(assets + 1)` → `debtAmount`, `liquidity` (slightly overestimate for rounding)
2. EVC batch:
   - `wrapper.unwrap(...)` — get raw NFT
   - `decreaseLiquidity(...)` — remove proportional liquidity, re-wraps
   - `borrowVault.repay(debtAmount)` — repay debt, borrow token comes from contract balance
3. `super._withdraw(...)` — transfers asset to receiver

### `reBalance(uint256 amountToSwap, address exchange, address spender, bytes calldata swapData)`

Adjusts the current leverage back toward `TARGET_LEVERAGE`. Called by a privileged keeper (access control needed).

**Current leverage** =  `(collateralValueInUOA * 1e18) / debtValueInUOA`

**Case: leverage > target** (over-leveraged, need to reduce debt):
1. EVC batch:
   a. `wrapper.unwrap(...)` — get raw NFT
   b. `decreaseLiquidity(...)` — remove liquidity proportional to `amountToSwap`
   c. `swapAssetToBorrowToken(amountToSwap, ...)` — swap asset → borrow token
   d. `repayContractBalance()` — repay all borrow token in contract

**Case: leverage < target** (under-leveraged, need to increase debt):
1. EVC batch:
   a. `borrowSwapBorrowIncreaseLiquidity(amountToSwap, ...)`:
      - Borrow `amountToSwap` borrow token
      - Swap borrow token → asset
      - Compute new `debtAmount` for received asset
      - Borrow that additional amount
      - Unwrap, increase liquidity, re-wrap

**Bug to fix in current code**: `batchItems` is allocated with size 4 but index [4] is accessed (off-by-one). The array should be size 5 or the index corrected.

**Slippage protection** (TODO in current code): After swap, check `borrowTokensReceived >= oracle.getQuote(amountToSwap, asset(), borrowToken) * (1 - slippageTolerance)`.

### `changeTicks(int24 newTickLower, int24 newTickUpper)`

Migrates the entire LP position to a new tick range. Access-controlled (keeper/owner only).

Flow:
1. Validate new ticks are valid and consistent with pool tick spacing
2. EVC batch:
   a. `wrapper.unwrap(...)` — get raw NFT
   b. Remove ALL liquidity: `_decreaseLiquidity(..., _getCurrentLiquidity())`
   c. Collect all tokens to vault
   d. Update `tickLower` and `tickUpper`
   e. Determine new amounts (may need a small swap if price has moved)
   f. Mint a new position (or reuse tokenId by calling `_mintPosition`)
   g. Re-wrap new position

**Edge case**: After removing all liquidity, there may be a slight asset or borrow token surplus/deficit due to price movement. Need to handle rounding and potentially leave dust in the contract.

**Not yet implemented.** This is a stub in the current code.

## `totalAssets()` 

Returns the total ETH-equivalent value the vault controls, net of debt:

```
LP_value_in_asset + free_asset_balance
  where LP_value_in_asset = asset_in_LP + (borrow_in_LP - debt) * price
```

Uses `previewUnwrap(tokenId, currentSqrtPrice, FULL_AMOUNT)` to get raw token amounts, then converts borrow-token net to asset using current spot price.

Returns 0 if `tokenId == 0` (before `initializeVault`).

## Share Accounting

Uses ERC4626 with virtual shares disabled:
- `_convertToShares = assets * totalSupply / totalAssets`
- `_convertToAssets = shares * totalAssets / totalSupply`

Virtual price is therefore `totalAssets / totalSupply`. Profits from LP fees accrue to share value automatically since `totalAssets` grows while `totalSupply` is unchanged.

Inflation attack protection: `MINIMUM_SHARES = 1000` locked to `address(1)` at init.

## Access Control

Currently missing. Need to add:
- `onlyOwner` or a `keeper` role for `reBalance` and `changeTicks`
- Consider using Euler's governance patterns (EVC operator permissions) or OpenZeppelin `Ownable`

## Invariants

These should hold at all times after `initializeVault`:

1. `tokenId != 0`
2. `IERC6909(wrapper).balanceOf(address(this), tokenId) == FULL_AMOUNT` unless liquidated
3. `totalAssets() > 0` (guaranteed by min shares at init)
4. Net leverage ≈ `TARGET_LEVERAGE` (within rebalance threshold)

The `NotAllowedIfLiquidated` check in `_deposit` enforces invariant 2 — deposits are blocked after a liquidation event.

## Open TODOs

- [ ] Generalize `TARGET_LEVERAGE` to constructor param
- [ ] Fix array index bug in `reBalance` (size 4, accessing [4])
- [ ] Implement `changeTicks` 
- [ ] Add oracle-based slippage checks in `swapAssetToBorrowToken` and `borrowSwapBorrowIncreaseLiquidity`
- [ ] Add access control to `reBalance` and `changeTicks`
- [ ] Handle dust (hanging asset/borrow token balances after operations)
- [ ] Remove `console.sol` import from `BaseVault`
- [ ] `name()` and `symbol()` return empty/static strings — construct from wrapper token names
- [ ] Verify `borrowVault.asset() == borrowToken` (commented TODO in constructor)
- [ ] Add `receive()` to `BaseVault` (currently only in `UniswapV4Vault`)
