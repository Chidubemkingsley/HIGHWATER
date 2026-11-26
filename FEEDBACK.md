# Uniswap v4 developer feedback

Required by several UF tracks; also signals polish.

## What worked

- `BaseHook` + CREATE2 flag mining via `deployCodeTo` / `HookMiner` made permissioned hook deploys reproducible in Foundry.
- `CurrencySettler` + `unlockCallback` is the right custody pattern for hook-owned liquidity.
- `StateLibrary.getFeeGrowthInside` + position feeGrowthLast makes oracle-free NAV (including uncollected fees) practical.

## Friction

- Hook-owned concentrated positions need careful inventory accounting: principal amounts from `LiquidityAmounts` alone understate NAV if fee growth is omitted — easy to get wrong in vault hooks.
- `beforeAddLiquidity` gating is clear; documenting that routers/PositionManager paths will revert helps integrators.
- No first-party “managed vault” reference hook — teams reinvent Arrakis-shaped patterns each cohort.

## Ask

- A canonical “hook-owned ERC4626-style LP vault” example in v4-periphery or OZ uniswap-hooks would cut a large class of UHI bugs (NAV, fee growth, share inflation).
