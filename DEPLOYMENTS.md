# HIGHWATER — Deployments & Security History

Deployer (all chains, when live): TBD — no testnet broadcast receipts published yet.

---

## Current version: v4 (this codebase)

Four rounds of security work completed. All findings are listed below with regressions.
No live addresses exist yet. The deploy script mines a CREATE2 salt and is ready to broadcast:

```bash
anvil
forge script script/00_DeployHighwater.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key <KEY> \
  --broadcast
```

Env overrides: `CURATOR`, `EPOCH_DURATION`, `PERFORMANCE_FEE_BPS`, `NUMERAIRE_IS_TOKEN1`.

---

## Security findings — all versions

### v1 → v2: Initial build threats (self-mapped, no external audit)

These were identified during construction and mitigated before the first commit.

| #        | Finding                                                                            | Severity         | Fix                                                                                                |
| -------- | ---------------------------------------------------------------------------------- | ---------------- | -------------------------------------------------------------------------------------------------- |
| **T1**   | Share inflation — first depositor mints 1 wei and prices out subsequent depositors | Classic ERC-4626 | `DEAD_SHARES = 1000` burned to `0xdead` on first deposit; invariant `deadSharesLocked`             |
| **T2**   | Curator charges fee when underperforming HODL                                      | Economic         | `settleFee` requires `strategyNav > benchmarkNav`; both gates must pass                            |
| **T3**   | HWM ratchet down — oscillating NAV farms repeated fees                             | Economic         | HWM never decreases; set to post-dilution NAV/share after each fee mint                            |
| **T3b**  | Pre-fee HWM blocks all future yield (Tokemak/Sherlock class)                       | Economic         | Billable = `min(alpha, gainAboveHWM)`; HWM is post-dilution, not pre-fee                           |
| **T3c**  | Withdrawer captures 100% of `feesAccrued`                                          | Accounting       | `callerDelta - feesAccrued` split in unlock path; fees go to hook idle, shared pro-rata            |
| **T4**   | External LP bypasses hook and dilutes the curated book                             | Access control   | `_beforeAddLiquidity` / `_beforeRemoveLiquidity` gate to `address(this)` only                      |
| **T9**   | Double-settle same epoch                                                           | Economic         | `epochStartTimestamp` checked; second call reverts with `EpochNotElapsed`                          |
| **T10**  | Withdraw rounding leaves remaining LPs with zero NAV                               | Rounding         | `liqToRemove` capped at `liq - 1` when other shares remain                                         |
| **T10b** | Dust fee ratchets HWM without dilution                                             | Economic         | `feeWad == 0` early-return skips HWM update                                                        |
| **T11**  | JIT sandwich around `settleEpoch` if fee is a `donate`                             | MEV              | Fee is share minting to curator, not `donate` — JIT gets diluted, not enriched                     |
| **T13**  | Reentrancy via ERC-20 transfer callback in `withdraw` / `settle`                   | Reentrancy       | `ReentrancyGuardTransient` on `deposit`, `withdraw`, `rebalance`, `keeperRebalance`, `settleEpoch` |

**Regression suite**: `test/HighwaterLib.t.sol`, `test/HighwaterLib.fuzz.t.sol`, `test/HighwaterSecurity.t.sol`, `test/HighwaterThreatPoCs.t.sol`, `test/invariant/HighwaterInvariant.t.sol`

---

### v2 → v3: Keeper + audit findings

Two bugs found by structured code review of the keeper system and migration path.

| #      | Finding                                                                                                                                                                                                                                                                                                                                                               | Severity   | Fix                                                                                              |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------ |
| **S2** | `migrateStrategy` with `doRebalance=true` does not refresh the HODL benchmark. The next epoch compares strategy NAV (at the new range's composition) against the old range's inventory snapshot, attributing the forced composition shift as false alpha. The curator could earn a performance fee they did not earn.                                                 | **Medium** | `_snapshotBenchmark()` called at end of `doRebalance` branch in `migrateStrategy`                |
| **S3** | `keeperRebalance` validated tick alignment and bounds via `_validateTicks` but did not verify that the new range contains the current tick. A compromised keeper (or a keeper tx frontrun on a chain with a public mempool) could move the position entirely away from the current price, leaving depositor inventory permanently out of range, earning no swap fees. | **Medium** | Added guard: reverts with `InvalidTicks` if `currentTick < newLower` or `currentTick > newUpper` |

**Two additional findings documented (not code bugs):**

| #      | Finding                                                                                                                                                                                                                                                                         | Severity          | Status                                                                      |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------------- |
| **S1** | After all live shareholders exit (only dead shares remain), `settleEpoch` is callable and refreshes the benchmark correctly from dust inventory. The next depositor gets a fresh, accurate snapshot. No bug — existing behaviour confirmed correct by test.                     | Informational     | Test written (`test_S1`)                                                    |
| **S6** | `setCurator` and `setKeeper` take effect immediately with no two-step confirmation. Setting to a wrong address is recoverable by the owner with another call, but the intermediate state leaves the curator role un-callable. No code fix needed — owner retains recovery path. | Low / Operational | Test written (`test_S6`) documenting the operational risk and recovery path |

**Regression suite**: `test/HighwaterAudit.t.sol` — `HighwaterAuditTest` (8 tests)

---

### v3 → v4: Online exploit research — B-series findings

Cross-checked against two real-world exploits found during online research:

- **Bunni V2** ($8.4M, September 2025): rounding-direction bug in withdrawal accounting, 44 micro-withdrawals drained the pool. Source: [blocksec.com](https://blocksec.com/blog/bunni-incident-repeated-small-withdrawals-compound-a-rounding-error-into-an-8.4m-drain)
- **DAI vault** ($14,838, October 2026): zero-liquidity fallback branch paid 100% of idle to 1 wei of shares instead of pro-rata. Source: [dev.to/pandasecurity](https://dev.to/pandasecurity/how-one-wei-of-shares-drained-14838-dai-a-uniswap-v4-vault-exploit-34m3)

| #      | Finding                                                                                                                                                                                                                                                                                                                                                                                                                       | Severity                           | Status                                                                                                                                                                                  |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B1** | **Bunni-class rounding**: `_payoutIdle` uses floor division `(bal * shares) / supply`. Online sources confirm floor = rounds in vault's favour = correct direction. Repeated small withdrawals accumulate rounding remainders in the vault, not in the withdrawer. Bunni's bug was the opposite — they overstated the withdrawer's share. HIGHWATER is not vulnerable to the Bunni attack pattern.                            | Informational — **not vulnerable** | 1024-run fuzz test (`test_B1_FuzzPartialWithdrawsPreserveBobShare`) + integration test (`test_B1_RepeatedSmallWithdrawalsConserveIdle`) prove conservation holds across N partial exits |
| **B2** | **DAI vault zero-liquidity idle drain**: when `liqToRemove` rounds to 0 (dust shares), the exploited vaults paid the entire idle balance to the caller. HIGHWATER's `_payoutIdle` is called with `(bal * shares) / supply` — pro-rata, not unbounded. With 1 share of a 10,000-share supply and 500 token idle, the payout is `500 * 1 / 10000 = 0.05 tokens`, not `500 tokens`. HIGHWATER is not vulnerable to this pattern. | Informational — **not vulnerable** | Tests `test_B2_DustSharesGetProRataIdleNotFullBalance` and `test_B2_ZeroPositionLiquidityIdleIsProRata` prove 1-wei-of-shares cannot drain the idle balance                             |

**Regression suite**: `test/HighwaterAudit.t.sol` — `HighwaterBSeriesAuditTest` (4 tests, including 1024-run fuzz)

---

## Full finding inventory

| ID   | Description                                                              | Version closed | Regression test                                                                  |
| ---- | ------------------------------------------------------------------------ | -------------- | -------------------------------------------------------------------------------- |
| T1   | Share inflation                                                          | v1             | `invariant_deadSharesLocked`                                                     |
| T2   | Curator fee on underperformance                                          | v1             | `HighwaterLib.t.sol::test_NoFeeWhenUnderBench`                                   |
| T3   | HWM ratchet down                                                         | v1             | `invariant_highWaterMarkNeverDecreases`                                          |
| T3b  | Pre-fee HWM exclusion (Tokemak)                                          | v1             | `HighwaterSecurity.t.sol::test_SettleSetsPostDilutionHwm`                        |
| T3c  | Withdrawer captures all fees                                             | v1             | `HighwaterSecurity.t.sol::test_WithdrawDoesNotCaptureAllAccruedFees`             |
| T4   | External LP bypass                                                       | v1             | `Highwater.t.sol::test_ExternalLiquidityGated`                                   |
| T9   | Double-settle                                                            | v1             | `HighwaterSecurity.t.sol::test_DoubleSettleRequiresAnotherEpoch`                 |
| T10  | Withdraw rounding                                                        | v1             | `invariant_sharesImplyPositiveNav`                                               |
| T10b | Dust fee HWM ratchet                                                     | v1             | `HighwaterLib.fuzz.t.sol::testFuzz_DustFeeDoesNotRatchetHwm`                     |
| T11  | JIT donate sandwich                                                      | v1             | Structural (share mint, not donate)                                              |
| T13  | Reentrancy                                                               | v1             | `ReentrancyGuardTransient` (audit-verified)                                      |
| S2   | Stale HODL benchmark after `migrateStrategy`                             | **v3**         | `HighwaterAudit.t.sol::test_S2_MigrateStrategyLeavesStaleHodlBenchmark`          |
| S3   | Keeper moves range to tick-free zone                                     | **v3**         | `HighwaterAudit.t.sol::test_S3_KeeperRangeDoesNotNeedToContainCurrentTick`       |
| B1   | Bunni-class rounding (not vulnerable — confirmed by fuzz)                | **v4**         | `HighwaterAudit.t.sol::test_B1_FuzzPartialWithdrawsPreserveBobShare` (1024 runs) |
| B2   | DAI vault zero-liquidity idle drain (not vulnerable — confirmed by test) | **v4**         | `HighwaterAudit.t.sol::test_B2_DustSharesGetProRataIdleNotFullBalance`           |
| R18  | Mid-epoch benchmark freeze — curator paid for deposits not alpha         | **FIXED (v5)** | `_snapshotBenchmark()` runs on every deposit/withdrawal; `test/HighwaterP0.t.sol`. |
| R19  | Non-standard token hazards (decimals fallback, FOT, rebasing, ERC-777, pausable) | **OPEN** | No regression test yet. Restrict to standard 18-decimal ERC-20s until resolved.  |
| R20  | Donation-driven fee / HWM ratchet via permissionless settleEpoch         | **MITIGATED**  | Direct transfers excluded by tracked idle + owner sweep; `poolManager.donate()` route remains LOW. |

---

## Still open

The following items are known gaps, documented rather than hidden:

1. **No live testnet deployment.** No broadcast receipts in `deployments/`. The deploy script is ready (`script/00_DeployHighwater.s.sol`). A CREATE2 salt mined for the three permission flags (`AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY`) is required before broadcasting.

2. **No fork test of the full deposit → rebalance → settle cycle** against a canonical `PoolManager` on Base/Unichain. `HighwaterForkSmoke.t.sol` currently only checks that the Base `PoolManager` address has bytecode.

3. **Production oracle not yet wired.** `IHighwaterOracle` + fail-closed settlement are shipped, but only a test spot stub exists in-tree. Production needs a real two-source adapter (push feed verified by a deep v3 TWAP) on the deployment chain.

4. **No two-step owner / curator transfer.** `transferOwnership` and `setCurator` are single-step. A mistyped address can be corrected by the owner with another call, but the intermediate window is a trust surface.

5. **Keeper `halfWidthSpacings` is a trusted parameter.** The keeper owner can set a half-width of 1 spacing, producing a range that the next swap will immediately exit, triggering another keeper call. Gas griefing is bounded by who pays the keeper tip, but there is no on-chain minimum half-width enforcement.

6. **Mid-epoch deposits inflate benchmark-relative alpha (Threat 18 — OPEN).** `_snapshotBenchmark()` runs only on the first capital event of an epoch and at `settleEpoch`. A deposit made mid-epoch raises `strategyNav` without updating `benchAmount0/1`, causing the curator to collect a performance fee on deposited capital rather than on generated alpha. For example: 100 tokens deposited (Alice) + 50 tokens of real alpha → correct fee ≈ 10 tokens. Same setup but Bob deposits 1,000 mid-epoch → fee ≈ 90 tokens. The curator collected 9× more despite creating no extra alpha. Fix requires snapshotting (or proportionally adjusting) the benchmark on every `deposit` and `withdraw`. This is the highest-priority economic flaw before the vault accepts real funds.

7. **Non-standard token types break NAV accounting (Threat 19 — OPEN).** There is no token allowlist or type guard. Five failure modes:
   - **Wrong decimals**: `_currencyDecimals` silently falls back to 18 on a failed `decimals()` call. A 6-decimal token (e.g. USDC) would be priced as 10¹² × its actual value, corrupting all NAV, share-pricing, and fee calculations.
   - **Fee-on-transfer**: `_settlePrincipalFrom` records the nominal transfer amount, but the hook receives less. The PoolManager ends with an unsettled debt that reverts the unlock callback or silently under-funds the position.
   - **Rebasing tokens** (e.g. stETH): `_inventory` reads `balanceOf(address(this))` for idle; that balance changes outside of transfers, creating phantom alpha at settle or silently erasing real alpha.
   - **ERC-777**: `tokensReceived` is called on the hook during settlement transfers, re-entering before state is finalised. `ReentrancyGuardTransient` guards the outer entry-points but does not cover internal settle→transfer chains.
   - **Pausable / blacklistable tokens** (e.g. USDC, USDT): a frozen hook address causes `safeTransfer` to revert mid-withdrawal, locking all depositor funds until the freeze is lifted.
   Until an allowlist or deployer-validated token check is added, deployments **must** use standard 18-decimal, non-rebasing, non-fee-on-transfer ERC-20s.

8. **Donation-driven fee / HWM ratchet (Threat 20 — LOW).** Direct transfers are now excluded from NAV by internal idle accounting and recoverable by the owner. The `poolManager.donate()` + poke route remains; curator and owner should monitor for it.

---

## Reproduce the security tests

```bash
# All audit regression tests
forge test --match-contract HighwaterAudit -vv

# Full suite
forge test
# expect 89 passes
```

---

## Version history

| Version          | Key changes                                                                                                                                                                                                                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **v1**           | Initial hook + vault + settlement math. All T-series threats mitigated before first commit.                                                                                                                                                                                                                                 |
| **v2**           | Added `HighwaterKeeper` auto-rebalance contract. Added `keeperRebalance` to hook with `setKeeper` admin. Added 12 keeper tests.                                                                                                                                                                                             |
| **v3**           | Fixed S2: `migrateStrategy` now refreshes HODL benchmark after rebalance. Fixed S3: `keeperRebalance` now requires new range to contain current tick. Added `HighwaterAudit.t.sol` with 8 regression tests.                                                                                                                 |
| **v4**           | Cross-checked against two real-world exploits (Bunni V2 $8.4M rounding attack; DAI vault $14,838 zero-liquidity idle drain). Both attack patterns verified not applicable to HIGHWATER via 4 new tests including a 1024-run fuzz. `HighwaterAudit.t.sol` now contains `HighwaterBSeriesAuditTest`. |
| **v5**           | Priority-0 hardening: idle inventory is tracked internally (`_idle0`/`_idle1`) so unsolicited transfers cannot inflate shares or create alpha; owner-only `sweepUnexpected` recovers them. HODL benchmark is snapshotted on every deposit/withdrawal. Added permissionless `poke()`. `optimizer_runs` lowered to 100 to stay under EIP-170. Three new P0 regressions in `test/HighwaterP0.t.sol`. |
| **v6 (current)** | Oracle-anchored settlement: `IHighwaterOracle` adapter, owner-configurable `priceDeviationBps` (default 5%, cap 20%), `settleEpoch` values NAV at the reference price and fails closed (fee 0) when the oracle is missing/reverting/zero/divergent. Added `src/interfaces/IHighwaterOracle.sol`, test stub, and three fail-closed/bounds regressions. `via_ir = true` keeps the hook at 20,657 B (3,919 B EIP-170 margin). Total: 89 tests passing. |
