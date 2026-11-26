# HIGHWATER evidence harness

Reproducible, offline re-pricing of real Uniswap v4 swaps. No RPC is needed to
reproduce the published numbers once the tape is committed.

## Online sources (verified 2026-11-26)

| Fact | Source |
|---|---|
| Unichain v4 PoolManager `0x1F98400000000000000000000000000000000004` (chain 130) | https://developers.uniswap.org/docs/protocols/v4/deployments |
| WETH `0x4200…0006`, USDC `0x078d…57ad6` | https://developers.uniswap.org/docs/unichain/technical-information/contract-addresses |
| ETH/USDC 5bp v4 pool id `0x3258f413…acc39d9` | https://docs.chainstack.com/docs/unichain-collecting-uniswapv4-eth-usdc-trades |
| `Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)` + filter by PoolId | https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol |
| Fees accrue only in range, pro-rata to active liquidity | https://developers.uniswap.org/docs/get-started/concepts/fees |
| `unclaimed = (feeGrowthCurrent - feeGrowthLast) * liquidity / Q128` | https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/calculate-fees |
| Position amounts from sqrt prices | https://github.com/Uniswap/v4-core/blob/main/src/libraries/LiquidityAmounts.sol (mirrored in `compare.py`) |
| Public RPC `https://unichain-rpc.publicnode.com` | https://unichain.publicnode.com/ |

Public-node archive reads require a personal token; `fetch.py` therefore supports
`UNICHAIN_BLOCKS` / `FETCH_BATCH` for a recent-window tape and `UNICHAIN_RPC_URL`
for a provider with archive access. The committed tape's actual window and size
are printed by `compare.py` — no claim is made beyond what it contains.

Current committed tape: **1,214 real swaps / ~83 minutes**, fetched from the
public Unichain RPC on 2026-11-26. With 30-minute epochs the suite reports a
**negative result**: the fixed curated range earns 0.00 WAD while random ranges
average 2.15 WAD (z = −0.98, 0/30 wins). This is published as-is — the short tape
does not demonstrate curation skill, which is exactly the discipline Hindsight
used for its retracted headlines. A 7-day archive tape is still needed.

## Run

```bash
python3 compare.py            # reproduces every number in evidence.json
# optional: refresh the tape
UNICHAIN_RPC_URL=<archive rpc> python3 fetch.py 7
# or a recent window on a public node:
UNICHAIN_BLOCKS=5000 FETCH_BATCH=1000 python3 fetch.py 1
```

## What it compares

Identical realized swaps are re-priced under:

1. **HIGHWATER** — a curated range centered on the epoch-open tick, charging a
   20% ex-post fee only when strategy NAV beats the rolling HODL benchmark and
   clears a post-dilution high-water mark.
2. **Frozen HODL** of the epoch-start inventory.
3. **Static full-range LP** at the same 5bp fee tier.
4. **Flat 5bp fee** on all volume.

The null re-runs with 30 random ranges and prints the z-score. The script prints
negative results and does not claim curation skill unless the null is defeated.

## Caveat

This is a replay model, not a claim about an on-chain HIGHWATER position. It
excludes gas, slippage, JIT, and MEV rebates; fee accrual is approximated with
the documented in-range pro-rata rule. It is evidence about the mechanism's
*decision rule*, not live PnL.
