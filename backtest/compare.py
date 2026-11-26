#!/usr/bin/env python3
"""Offline, reproducible evidence suite for HIGHWATER.

Reads the committed Unichain ETH/USDC v4 swap tape and re-prices IDENTICAL realized
trades under:
  1. HIGHWATER curated range (ex-post fee vs rolling HODL + high-water mark)
  2. Frozen HODL of epoch-start inventory
  3. Static full-range LP (same fee tier)
  4. Flat 5bp fee on all volume

Publishes the null (random ranges), horizon sensitivity, and negative results.
No RPC, no third-party packages. Run: python3 backtest/compare.py

Online sources for the model (checked 2026-11-26):
  - https://developers.uniswap.org/docs/get-started/concepts/fees
      "Only in-range liquidity earns fees. Fees are distributed pro-rata: the more
       liquidity you provide in the active price range, the larger your share."
  - https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/calculate-fees
      unclaimed = (feeGrowthInsideCurrent - feeGrowthInsideLast) * liquidity / Q128
  - https://github.com/Uniswap/v4-core/blob/main/src/libraries/LiquidityAmounts.sol
      getAmountsForLiquidity / getLiquidityForAmounts (mirrored in Python below)
  - https://docs.chainstack.com/docs/unichain-collecting-uniswapv4-eth-usdc-trades
      Swap-log filtering by PoolId; 5bp ETH/USDC pool id used by fetch.py

Caveat: this is a replay model on identical realized swaps, not a claim about an
on-chain HIGHWATER position. It does not include gas, slippage, or MEV rebates.
"""
import csv
import gzip
import json
import math
import os
import random
import statistics

HERE = os.path.dirname(__file__)
TAPE = os.path.join(HERE, "swaps_eth_usdc_5bp.csv.gz")
Q96 = 1 << 96
WAD = 10 ** 18
SCALE1 = 10 ** 12  # USDC (6dp) -> WAD (18dp)
FEE_PIPS = 500  # 5bp pool
PERF_BPS = 2000  # HIGHWATER curator fee
EPOCH = int(os.environ.get("EPOCH_SECONDS", "86_400"))
SPACING = 60
HWM_START = 0  # sentinel: first epoch establishes the mark


def tick_sqrt(tick):
    return math.exp(tick * math.log(1.0001)) * Q96


def amounts_for_liquidity(sqrt_p, sqrt_a, sqrt_b, liq):
    sqrt_a, sqrt_b = sorted((sqrt_a, sqrt_b))
    if sqrt_p <= sqrt_a:
        a0 = (liq * Q96) * (sqrt_b - sqrt_a) / sqrt_b / sqrt_a
        return a0, 0.0
    if sqrt_p < sqrt_b:
        a0 = (liq * Q96) * (sqrt_b - sqrt_p) / sqrt_b / sqrt_p
        a1 = liq * (sqrt_p - sqrt_a) / Q96
        return a0, a1
    return 0.0, liq * (sqrt_b - sqrt_a) / Q96


def liquidity_for_amounts(sqrt_p, sqrt_a, sqrt_b, a0, a1):
    sqrt_a, sqrt_b = sorted((sqrt_a, sqrt_b))
    if sqrt_p <= sqrt_a:
        return a0 * sqrt_a * sqrt_b / (Q96 * (sqrt_b - sqrt_a))
    if sqrt_p < sqrt_b:
        l0 = a0 * sqrt_p * sqrt_b / (Q96 * (sqrt_b - sqrt_p))
        l1 = a1 * Q96 / (sqrt_p - sqrt_a)
        return min(l0, l1)
    return a1 * Q96 / (sqrt_b - sqrt_a)


def price(sqrt_p):
    return (sqrt_p / Q96) ** 2


def nav_wad(a0, a1, sqrt_p):
    return (a0 * price(sqrt_p) + a1) * SCALE1


def load_tape():
    rows = []
    with gzip.open(TAPE, "rt", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("block,"):
                continue
            p = line.rstrip("\n").split(",")
            if len(p) < 11:
                continue
            rows.append({
                "block": int(p[0]), "ts": int(p[10]),
                "a0": int(p[4]), "a1": int(p[5]),
                "sqrt": int(p[6]), "liq": int(p[7]), "tick": int(p[8]),
                "sender": p[3],
            })
    rows.sort(key=lambda r: (r["block"], r["ts"]))
    return rows


def epochs(rows):
    out, cur, start = [], [], None
    for r in rows:
        if start is None:
            start = r["ts"]
        if r["ts"] >= start + EPOCH:
            out.append(cur)
            cur, start = [], r["ts"]
        cur.append(r)
    if cur:
        out.append(cur)
    return [e for e in out if len(e) >= 2]


def run_epoch(ep, center, halfwidth, hwm, full_range=False, seed_fee_bps=None):
    first, last = ep[0], ep[-1]
    start_sqrt = first["sqrt"]
    if full_range:
        lo, hi = -887272, 887272
    else:
        lo, hi = (center - halfwidth) * SPACING, (center + halfwidth) * SPACING
    sqrt_lo, sqrt_hi = tick_sqrt(lo), tick_sqrt(hi)
    # Size from a two-sided deposit: 1 WETH of token0 plus its value in USDC.
    start_price = price(start_sqrt)
    a0_seed = float(WAD)
    a1_seed = a0_seed * start_price
    liq = liquidity_for_amounts(start_sqrt, sqrt_lo, sqrt_hi, a0_seed, a1_seed)
    if liq <= 0:
        return 0.0, hwm, 0.0
    bench0, bench1 = amounts_for_liquidity(start_sqrt, sqrt_lo, sqrt_hi, liq)
    idle = 0.0
    gross_volume = 0.0
    for r in ep:
        in_range = lo <= r["tick"] <= hi
        if not in_range:
            continue
        a0, a1 = abs(r["a0"]), abs(r["a1"])
        inp = a0 if r["a0"] < 0 else a1
        gross_volume += inp
        fee_raw = inp * (FEE_PIPS if seed_fee_bps is None else seed_fee_bps) / 1_000_000
        fee_wad = fee_raw * (price(r["sqrt"]) if r["a0"] < 0 else 1.0) * SCALE1
        if r["liq"] > 0:
            idle += fee_wad * min(1.0, liq / r["liq"])
    final_sqrt = last["sqrt"]
    a0, a1 = amounts_for_liquidity(final_sqrt, sqrt_lo, sqrt_hi, liq)
    strat = nav_wad(a0, a1, final_sqrt) + idle
    bench = nav_wad(bench0, bench1, final_sqrt)
    alpha = max(0.0, strat - bench)
    fee = 0.0
    nps = strat  # supply fixed at WAD shares, so NAV/share == NAV in WAD
    if hwm <= 0:
        hwm = strat
    if alpha > 0 and nps > hwm:
        billable = min(alpha, (nps - hwm))
        fee = billable * PERF_BPS / 10_000
        hwm = (strat - fee) if (strat - fee) > hwm else hwm
    return fee, hwm, alpha


def main():
    rows = load_tape()
    eps = epochs(rows)
    print(f"tape: {len(rows)} swaps, {len(eps)} epochs of {EPOCH / 3600:.2f}h")
    if not eps:
        print("empty tape")
        return
    hwm = HWM_START
    total_fee = total_alpha = 0.0
    full_fee = flat_fee = 0.0
    for ep in eps:
        center = round(ep[0]["tick"] / SPACING)
        fee, hwm, alpha = run_epoch(ep, center, 5, hwm)
        total_fee += fee
        total_alpha += alpha
        full_fee += run_epoch(ep, center, 5, HWM_START, full_range=True)[0]
        for r in ep:
            inp_is_token0 = r["a0"] < 0
            fee_raw = (abs(r["a0"]) if inp_is_token0 else abs(r["a1"])) * 5 / 10_000
            flat_fee += fee_raw * (price(r["sqrt"]) if inp_is_token0 else 1.0) * SCALE1
    print(f"HIGHWATER curator fee: {total_fee/WAD:.2f} WAD")
    print(f"gross positive alpha:  {total_alpha/WAD:.2f} WAD")
    print(f"rho (fee / alpha):     {(total_fee/total_alpha*100 if total_alpha else 0):.1f}%")
    print(f"static full-range LP fee: {full_fee/WAD:.2f} WAD")
    print(f"flat 5bp fee:             {flat_fee/WAD:.2f} WAD")

    rng = random.Random(20261126)
    nulls = []
    for _ in range(30):
        nf = 0.0
        hwm_n = HWM_START
        for ep in eps:
            center = round(ep[0]["tick"] / SPACING) + rng.randint(-20, 20)
            hw = rng.randint(1, 12)
            f, hwm_n, _ = run_epoch(ep, center, hw, hwm_n)
            nf += f
        nulls.append(nf)
    mean = statistics.mean(nulls)
    sd = statistics.pstdev(nulls) or 1.0
    z = (total_fee - mean) / sd
    wins = sum(1 for n in nulls if n < total_fee)
    print(f"random-range null: mean {mean/WAD:.2f} WAD, z {z:+.2f}, wins {wins}/30")
    print("null is published; no claim of skill is made if z <= 2.")

    # Horizon sensitivity: the same tape at three curated half-widths.
    for hw in (2, 5, 10):
        h = HWM_START
        tot = 0.0
        for ep in eps:
            f, h, _ = run_epoch(ep, round(ep[0]["tick"] / SPACING), hw, h)
            tot += f
        print(f"halfwidth {hw} spacings: {tot/WAD:.2f} WAD")

    out = {
        "swaps": len(rows), "epochs": len(eps), "epoch_seconds": EPOCH,
        "curator_fee_wad": total_fee / WAD, "alpha_wad": total_alpha / WAD,
        "null_mean_wad": mean / WAD, "null_z": z, "null_wins": wins,
        "static_full_range_wad": full_fee / WAD, "flat_5bp_wad": flat_fee / WAD,
    }
    with open(os.path.join(HERE, "evidence.json"), "w") as fh:
        json.dump(out, fh, indent=2)


if __name__ == "__main__":
    main()
