#!/usr/bin/env python3
"""Prove that a deployed HIGHWATER hook is this repository's compiled bytecode.

Usage:
  HOOK_ADDRESS=0x... UNICHAIN_SEPOLIA_RPC_URL=<rpc> python3 tools/verify_deployment.py

Immutable values differ per deployment, so their 32-byte spans (reported by solc
in `deployedBytecode.immutableReferences`) are masked in both strings before
comparison. No linked-library placeholders exist in this hook; if one appears the
script fails loudly rather than silently comparing different code.
"""
import json
import os
import urllib.request

RPC = os.environ.get("UNICHAIN_SEPOLIA_RPC_URL", "https://sepolia.unichain.org")
ADDR = os.environ.get("HOOK_ADDRESS", "")
ARTIFACT = os.path.join(os.path.dirname(__file__), "..", "out", "HighwaterHook.sol", "HighwaterHook.json")


def eth_get_code(address):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    req = urllib.request.Request(RPC, data=payload, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        obj = json.loads(resp.read())
    if "error" in obj:
        raise RuntimeError(obj["error"])
    return obj["result"][2:]


def main():
    if not ADDR:
        raise SystemExit("set HOOK_ADDRESS")
    art = json.load(open(ARTIFACT))
    expected = art["deployedBytecode"]["object"]
    if "__$" in expected:
        raise SystemExit("artifact contains unlinked library placeholders; link before verifying")
    live = eth_get_code(ADDR)
    spans = []
    for refs in art["deployedBytecode"].get("immutableReferences", {}).values():
        spans.extend(refs)
    spans = sorted({(r["start"] * 2, (r["start"] + r["length"]) * 2) for r in spans})

    def mask(code):
        chars = list(code)
        for a, b in spans:
            for i in range(a, min(b, len(chars))):
                chars[i] = "0"
        return "".join(chars)

    expected_size, live_size = len(expected) // 2, len(live) // 2
    print(f"expected runtime: {expected_size} bytes")
    print(f"live runtime:     {live_size} bytes")
    print(f"immutable spans:  {len(spans)}")
    if expected_size != live_size:
        print("MISMATCH: size differs")
        raise SystemExit(1)
    match = mask(expected) == mask(live)
    print("MATCH" if match else "MISMATCH")
    raise SystemExit(0 if match else 1)


if __name__ == "__main__":
    main()
