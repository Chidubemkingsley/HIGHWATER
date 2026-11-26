#!/usr/bin/env python3
"""Fetch real Uniswap v4 ETH/USDC swaps on Unichain mainnet.

Sources (verified online 2026-11-26):
  - Uniswap v4 deployments: PoolManager 0x1F98400000000000000000000000000000000004 (chain 130)
  - Unichain contract addresses: WETH 0x4200...0006, USDC 0x078d...57ad6
  - ETH/USDC 5bp v4 pool id: 0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b6774485d8acc39d9
  - PoolManager Swap event: Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)
  - Public RPC: https://unichain-rpc.publicnode.com (rate limited; override with UNICHAIN_RPC_URL)

No third-party Python packages are required. The tape is committed so compare.py
reproduces every number offline.
"""
import gzip
import json
import os
import subprocess
import sys
import time
import urllib.request

RPC = os.environ.get("UNICHAIN_RPC_URL", "https://unichain-rpc.publicnode.com")
POOL_MANAGER = "0x1f98400000000000000000000000000000000004"
POOL_ID = "3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b6774485d8acc39d9"
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
BATCH = int(os.environ.get("FETCH_BATCH", "1000"))
BLOCKS = int(os.environ.get("UNICHAIN_BLOCKS", "0"))  # 0 => days * 86_400
OUT = os.path.join(os.path.dirname(__file__), "swaps_eth_usdc_5bp.csv.gz")
STATE = os.path.join(os.path.dirname(__file__), "fetch_state.json")


def rpc(method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    for attempt in range(8):
        try:
            req = urllib.request.Request(RPC, data=payload.encode(), headers={"content-type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                obj = json.loads(resp.read())
            if "error" in obj:
                raise RuntimeError(obj["error"])
            return obj["result"]
        except Exception:
            try:
                # curl sometimes succeeds when Python's resolver fails in this environment
                out = subprocess.check_output(
                    ["curl", "-sS", "-m", "30", "-H", "content-type: application/json",
                     "--data", payload, RPC], text=True
                )
                obj = json.loads(out)
                if "error" in obj:
                    raise RuntimeError(obj["error"])
                return obj["result"]
            except Exception:
                if attempt == 7:
                    raise
                time.sleep(2 ** attempt)


def signed(word):
    v = int(word, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def decode(log):
    data = log["data"][2:]
    words = [data[i:i + 64] for i in range(0, len(data), 64)]
    return {
        "block": int(log["blockNumber"], 16),
        "txIndex": int(log["transactionIndex"], 16),
        "logIndex": int(log["logIndex"], 16),
        "sender": "0x" + log["topics"][2][-40:],
        "amount0": signed(words[0]),
        "amount1": signed(words[1]),
        "sqrtPriceX96": int(words[2], 16),
        "liquidity": int(words[3], 16),
        "tick": signed(words[4]),
        "fee": int(words[5], 16),
    }


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    latest = int(rpc("eth_blockNumber", []), 16)
    # Unichain block time is ~1s (official network docs). Public RPCs may cap archive reads.
    span = BLOCKS if BLOCKS > 0 else days * 86_400
    start = max(1, latest - span)
    if os.path.exists(STATE):
        saved = json.load(open(STATE))
        start = max(start, saved.get("next_block", start))
    fh = gzip.open(OUT, "at", encoding="utf-8") if os.path.exists(OUT) else gzip.open(OUT, "wt", encoding="utf-8")
    if fh.tell() == 0:
        fh.write("block,txIndex,logIndex,sender,amount0,amount1,sqrtPriceX96,liquidity,tick,fee,timestamp\n")
    block_ts = {}
    cur = start
    while cur <= latest:
        end = min(cur + BATCH - 1, latest)
        logs = rpc("eth_getLogs", [{
            "address": POOL_MANAGER,
            "fromBlock": hex(cur),
            "toBlock": hex(end),
            "topics": [SWAP_TOPIC, "0x" + POOL_ID],
        }])
        blocks = sorted({int(l["blockNumber"], 16) for l in logs})
        for b in blocks:
            if b not in block_ts:
                hdr = rpc("eth_getBlockByNumber", [hex(b), False])
                block_ts[b] = int(hdr["timestamp"], 16)
        for log in logs:
            row = decode(log)
            fh.write(
                f'{row["block"]},{row["txIndex"]},{row["logIndex"]},{row["sender"]},'
                f'{row["amount0"]},{row["amount1"]},{row["sqrtPriceX96"]},{row["liquidity"]},'
                f'{row["tick"]},{row["fee"]},{block_ts[row["block"]]}\n'
            )
        fh.flush()
        json.dump({"next_block": end + 1, "latest": latest}, open(STATE, "w"))
        print(f"blocks {cur}-{end}: {len(logs)} swaps", flush=True)
        cur = end + 1
    fh.close()


if __name__ == "__main__":
    main()
