# HIGHWATER

**Managers don’t get paid for managing. They get paid for beating the LP they replaced.**

Uniswap v4 hook for **UHI11 — Active Management & Curation**. Depositors hold ERC-20 vault shares (`HWTR`) while a curator sets the active tick range. When an epoch ends, `settleEpoch` marks the live book against a HODL snapshot of the inventory at the last capital change (using the pool’s `sqrtPriceX96`). The curator earns fee shares only if that mark shows alpha **and** NAV per share clears a high-water mark. Capital entering or leaving mid-epoch is never counted as alpha.

[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4%20hook-FF007A.svg?logo=uniswap)](https://docs.uniswap.org/contracts/v4/overview)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-363636.svg?logo=solidity)](https://soliditylang.org/)
[![Tests](https://img.shields.io/badge/tests-83%20passing-3FB950.svg)](#run-the-proofs)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Badge check (this repo):** hook is `BaseHook` + v4 `PoolManager`; tooling is Foundry; `foundry.toml` pins `solc_version = "0.8.30"`; `forge test --match-contract 'Highwater|PriorArt|DemoScoreboard'` reports **83** passes (full `forge test`: **89**); `LICENSE` is MIT.

**Evidence box:** `backtest/` ships a real Unichain swap tape and an offline re-pricing suite. On the committed ~83-minute tape the fixed curated range does **not** beat random ranges (0.00 vs 2.15 WAD, z = −0.98); the negative result is published in [`backtest/report.txt`](backtest/report.txt). A 7-day archive tape is still needed before claiming skill.

**Honesty box:** unaudited research MVP. All scoreboards below are local Foundry against a test `PoolManager` (plus pure math). `HighwaterForkSmoke` — if you set `BASE_RPC_URL` — only asserts Base’s published `PoolManager` address has bytecode. It does not deploy HIGHWATER on a fork, and nothing here is a live testnet receipt or mainnet PnL claim.

---

## Idea

Most managed LP products take a cut of assets under management whether the manager beat a do-nothing LP or not.

HIGHWATER’s pay rule is different:

| Step               | What happens in code                                                          |
| ------------------ | ----------------------------------------------------------------------------- |
| Deposit / withdraw | Users move tokens through the hook; shares mint/burn (`deposit` / `withdraw`) |
| Curate             | `rebalance` moves the single hook-owned range (`onlyCurator`)                 |
| Clock              | After `epochDuration`, anyone may call `settleEpoch`                          |
| Verdict            | `strategyNav` vs `benchmarkNav` (rolling HODL snapshot) at live pool price   |
| Pay                | Mint curator shares only on billable alpha above the high-water mark          |

```text
deposit → curator rebalance → time passes → settleEpoch()
                                    │
              strategyNav  ?  HODL(bench amounts @ live sqrtPrice)
                                    │
                   lose or flat or below HWM  →  fee = 0
                   win + new HWM              →  mint HWTR to curator
```

---

## How the pieces connect

```text
Users ── deposit / withdraw ──► HighwaterHook (ERC-20 "HWTR")
                                     │
                                     │ one liquidity position (POSITION_SALT)
                                     ▼
                              Uniswap v4 PoolManager
                                     ▲
Curator ── rebalance ────────────────┤  (modifier: onlyCurator)
Keeper  ── keeperRebalance ──────────┤  (only when tick is out of range)
Owner   ── migrateStrategy / setCurator / setKeeper / transferOwnership
Anyone  ── settleEpoch ──────────────┘  (after epochDuration)
```

Hook flags used: `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`. External `modifyLiquidity` reverts unless `sender == address(this)`.

| Module              | Job                                    | Who holds tokens?                                  | What we actually tested        |
| ------------------- | -------------------------------------- | -------------------------------------------------- | ------------------------------ |
| `HighwaterHook`     | custody path + shares + range + settle | Hook pulls/pushes via `unlock` + `CurrencySettler` | Integration suites on local PM |
| `HighwaterKeeper`   | auto-rebalance when tick leaves range  | n/a                                                | 12 keeper tests                |
| `HighwaterLib`      | fee + HWM + share math (pure)          | n/a                                                | Unit + 1024-run fuzz           |
| `NavLib`            | mark inventory to WAD numéraire        | n/a                                                | Unit + used by hook views      |
| `PriorArtFeeModels` | toy AUM / HWM-only fees for comparison | n/a                                                | `PriorArtComparison` tape      |

---

## UHI11 fit

| Track ask               | This codebase                                                                                   |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| Vault / gated liquidity | Hook-owned range; add/remove gated to the hook; depositors get `HWTR`                           |
| Curated LP              | `curator` alone calls `rebalance`                                                               |
| Auto-rebalancing        | `HighwaterKeeper` triggers `keeperRebalance` when the pool tick drifts outside the active range |
| Performance             | Ex-post fee in `settleEpoch` + `HighwaterLib.settleFee`                                         |

---

## Vault behavior (what the hook does)

- One shared concentrated position (`POSITION_SALT`). First deposit also mints `DEAD_SHARES` (1000) to `0xdead`.
- `strategyNav` = position token amounts + fee-growth owed + **internally tracked idle** (`idleBalances()`), valued with `NavLib` from pool `sqrtPriceX96`. Raw ERC-20/ETH balances are deliberately not used: unsolicited transfers cannot move share price or create fake alpha.
- `benchmarkNav` = `(benchAmount0, benchAmount1)` snapshotted at the last deposit/withdrawal/settlement, valued the same way at the **current** price.
- On `modifyLiquidity`, the unlock path splits `callerDelta` into principal vs `feesAccrued` (per the v4 `IPoolManager` reference): fees go to tracked idle; principal is what the user pays or receives.
- `poke()` is permissionless: a zero-delta `modifyLiquidity` realises uncollected fees into tracked idle without settling an epoch.
- `sweepUnexpected(token, to)` (owner-only) recovers tokens sent to the hook outside the unlock path; shareholder idle is never sweepable.
- Withdraw: pro-rata liquidity + idle; will not empty the book while other shares remain; reverts if remaining supply would mark to zero NAV.

Source: [`src/HighwaterHook.sol`](src/HighwaterHook.sol).

---

## Settlement math (what earns the curator)

**Settlement price is oracle-anchored.** v4 has no built-in oracle, so `setPriceOracle` wires an `IHighwaterOracle` adapter (production: a two-source feed, e.g. Chainlink-compatible price verified by a deep v3 TWAP). `settleEpoch` values the position and the HODL benchmark at the **reference price**, and checks spot against it; if the oracle is absent, reverts, returns zero, or deviates beyond `priceDeviationBps` (default 5%, cap 20%), the epoch settles with **fee = 0** — fail closed. `previewSettle()` remains spot-based and does not include the poke.

On `settleEpoch` (when liquidity > 0 the hook first pokes with `liquidityDelta = 0` to realize fees into idle):

1. `alpha = strategyNav - benchmarkNav` (0 if strategy ≤ bench).
2. Billable = `min(alpha, strategyNav - HWM·shares)` when NAV/share is above the mark; else fee = 0.
3. `fee = billable * performanceFeeBps / 10_000` (constructor cap `MAX_FEE_BPS = 5000`).
4. If `fee` floors to 0, the high-water mark does **not** move.
5. Otherwise mint `curatorSharesForFee` to `curator`, set HWM to post-dilution NAV/share, bump `epochId`, refresh the HODL snapshot.

Pure implementation: [`src/libraries/HighwaterLib.sol`](src/libraries/HighwaterLib.sol).

### Comparison tape (toy models, same inputs)

[`PriorArtFeeModels`](src/comparators/PriorArtFeeModels.sol) is **not** a port of another protocol. It is a tiny AUM skim and a share-price-HWM-only formula so we can put three numbers on one row.

| Tape                    | AUM skim (2% of NAV) | HWM-only (20% of gain) | HIGHWATER (20% of billable) |
| ----------------------- | -------------------- | ---------------------- | --------------------------- |
| Under HODL bench        | charges              | 0 (if nps ≤ mark)      | **0**                       |
| Flat vs bench           | charges              | 0                      | **0**                       |
| Beat bench + new HWM    | charges              | charges                | **charges, ≤ alpha**        |
| nps up but matched HODL | charges              | charges                | **0**                       |

Reproduce: `forge test --match-contract PriorArtComparison -vv` · notes in [`docs/PRIOR_ART.md`](docs/PRIOR_ART.md).

---

## Functions you call

```solidity
// Shares
deposit(amount0Max, amount1Max, minShares)  → (shares, amount0, amount1)
withdraw(shares, minAmount0, minAmount1)    → (amount0, amount1)

// Curator-only
rebalance(newLower, newUpper)

// Keeper-only (when tick is outside active range)
keeperRebalance(newLower, newUpper)

// Owner-only
migrateStrategy(newCurator, newLower, newUpper, doRebalance)
setCurator(newCurator)
setKeeper(newKeeper)          // pass address(0) to disable
transferOwnership(newOwner)

// Anyone after epochDuration
settleEpoch() → (feeWad, curatorShares)
previewSettle() → (strategyNav, benchmarkNav, alpha, fee, curatorShares)  // view; does not poke

// Views
strategyNav() / benchmarkNav() / idleBalances() / poolKey() / highWaterMark / epochId / keeper / …
```

Constructor: `PoolManager`, `owner`, `curator`, `epochDuration` (>0), `performanceFeeBps` (≤5000), `numeraireIsToken1`.

**HighwaterKeeper** (separate contract, `src/HighwaterKeeper.sol`):

```solidity
// Deploy
keeper = new HighwaterKeeper(hook, halfWidthSpacings);
hook.setKeeper(address(keeper));  // owner registers it on the hook

// Anyone calls when shouldRebalance() == true
keeper.triggerRebalance()

// Views
keeper.shouldRebalance() → bool
keeper.computeNewRange()  → (int24 newLower, int24 newUpper)

// Owner-only config
keeper.updateHalfWidth(newHalfWidthSpacings)
```

---

## Run the proofs

```bash
forge install
forge build
forge test --match-contract 'Highwater|PriorArt|DemoScoreboard'   # expect 83 passes (full suite: 89)
```

Useful slices:

```bash
forge test --match-contract PriorArtComparison -vv
forge test --match-contract DemoScoreboard -vv
forge test --match-contract HighwaterAudit -vv
forge test --match-contract HighwaterKeeper -vv
forge test --match-contract HighwaterSwapAlpha -vv
forge test --match-contract HighwaterThreatPoCs -vv
forge test --match-contract HighwaterSecurity -vv
forge test --match-contract HighwaterInvariant -vv

# offline evidence suite over a committed real Unichain swap tape (see backtest/README.md)
python3 backtest/compare.py

# full fork cycle against canonical Unichain Sepolia PoolManager (skips without RPC)
UNICHAIN_SEPOLIA_RPC_URL=<rpc> forge test --match-path 'test/fork/*' -vv

# heavier invariant/fuzz profile from foundry.toml
forge test --profile intense --match-contract Highwater -vv

# optional: Base PoolManager code-length check only
BASE_RPC_URL=<rpc> forge test --match-contract HighwaterForkSmoke -vv
```

| File                                             | Asserts in this repo                                                                                                 |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| `HighwaterLib.t.sol` / `HighwaterLib.fuzz.t.sol` | Fee bounds, HWM monotone, post-dilution mark, dust fee does not ratchet (fuzz runs = 1024 default)                   |
| `PriorArtComparison.t.sol`                       | Same-input fee tape above                                                                                            |
| `Highwater.t.sol`                                | Deposit, withdraw, rebalance auth, migrate, settle 0 / settle > 0                                                    |
| `HighwaterKeeper.t.sol`                          | shouldRebalance, computeNewRange, triggerRebalance, guards, disabled keeper, admin                                   |
| `HighwaterAudit.t.sol`                           | S2 benchmark refresh after migrateStrategy, S3 keeper range covers tick, S5 withdraw EVM revert, S6 curator recovery |
| `HighwaterAudit.t.sol` (B-series)                | B1 Bunni-class rounding conservation (1024-run fuzz), B2 DAI vault zero-liquidity idle drain not applicable          |
| `HighwaterSwapAlpha.t.sol`                       | Swaps create alpha vs HODL; settle mints curator shares                                                              |
| `HighwaterSecurity.t.sol`                        | Double-settle, HWM gate, fee/principal idle split, post-dilution HWM on-chain                                        |
| `HighwaterThreatPoCs.t.sol`                      | Out-of-range path settles with fee 0; two-LP withdraw conservation soft check                                        |
| `DemoScoreboard.t.sol`                           | Scripted deposit → rebalance → settle 0 → inject alpha → settle → migrate                                            |
| `invariant/HighwaterInvariant.t.sol`             | Default **64 runs × 32 depth**; intense profile **256 × 64**                                                         |

More notes: [`docs/demos/local-scoreboard.md`](docs/demos/local-scoreboard.md) · [`docs/THREAT_MAP.md`](docs/THREAT_MAP.md) · [`DEPLOYMENTS.md`](DEPLOYMENTS.md).

---

## Deploy (local)

```bash
anvil
forge script script/00_DeployHighwater.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <KEY> \
  --broadcast
```

Script mines CREATE2 for the three permission flags and deploys `HighwaterHook`. Env overrides: `CURATOR`, `EPOCH_DURATION`, `PERFORMANCE_FEE_BPS`, `NUMERAIRE_IS_TOKEN1`, `PRICE_ORACLE` (address of an `IHighwaterOracle` adapter; without it, settlement fees are fail-closed at zero).

No addresses under `deployments/` are published in this repo yet.

---

## Risk notes (code-backed, not an audit)

See [`docs/THREAT_MAP.md`](docs/THREAT_MAP.md).

- Unaudited — do not put real funds in.
- 83 judge-filtered Foundry tests (89 full suite) as listed above; invariants cover HWM, fee ≤ alpha (preview), dead shares, live shares ⇒ NAV > 0.
- Fee math caps billable alpha; HWM only rises on a nonzero fee and uses post-dilution NAV/share.
- Accrued swap fees are not paid entirely to the withdrawing user; they enter idle and are shared.
- Performance pay is share minting to `curator`, not a `donate` to in-range LPs.
- Only the hook may change the curated liquidity; `rebalance` is curator-gated; `keeperRebalance` is keeper-gated (only fires when tick is outside the active range); migration is owner-gated.
- Settlement reads an `IHighwaterOracle` reference price when configured and fails closed (fee 0) when it is missing, reverting, zero, or spot-deviant beyond `priceDeviationBps`; `previewSettle` remains spot-based.
- Owner/curator can still choose a harmful range or migrate curation; LPs’ recourse is withdraw.
- Keeper can only call `keeperRebalance` when the tick is out of range, and the new range must contain the current tick (enforced on-chain) — a compromised keeper cannot move the position to a tick-free zone.
- `migrateStrategy` with `doRebalance=true` refreshes the HODL benchmark to the post-migration inventory, preventing spurious alpha from a forced range change. (S2 fix.)

---

## Five-minute walkthrough

```bash
forge test --match-contract DemoScoreboard -vv
```

1. Deposit → shares + HODL snapshot.
2. Curator `rebalance`.
3. Warp past epoch → `settleEpoch` → fee **0** when flat.
4. Add idle inventory (simulated alpha) → settle → curator receives shares.
5. Owner `migrateStrategy`.

---

## Limits we state upfront

- HODL bench ignores “what a static full-range LP would have earned in fees.” That is intentional simplicity.
- Short `epochDuration` values are noisy.
- Swap-alpha tests show fees _can_ beat HODL; they do not prove every rebalance is skill.
- No Sepolia/Base vault deployment receipts in-tree yet.

---

## Layout

| Path                                                                             | Role                                              |
| -------------------------------------------------------------------------------- | ------------------------------------------------- |
| [`src/HighwaterHook.sol`](src/HighwaterHook.sol)                                 | Hook + vault + settle                             |
| [`src/HighwaterKeeper.sol`](src/HighwaterKeeper.sol)                             | Auto-rebalance keeper                             |
| [`src/libraries/NavLib.sol`](src/libraries/NavLib.sol)                           | Price mark helpers                                |
| [`src/libraries/HighwaterLib.sol`](src/libraries/HighwaterLib.sol)               | Fee / HWM / shares                                |
| [`src/comparators/PriorArtFeeModels.sol`](src/comparators/PriorArtFeeModels.sol) | Comparison toys                                   |
| [`FEEDBACK.md`](FEEDBACK.md)                                                     | v4 builder notes from this build                  |
| [`DEPLOYMENTS.md`](DEPLOYMENTS.md)                                               | Version history, all security findings, open gaps |

## License

MIT
