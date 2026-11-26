#!/usr/bin/env python3
"""
PASSO 368 -- Read-only, historical SAME-POOL swap-order review around Spark's
three verified USDT/USDS trades (Nov 23 2026).
Queries eth_getLogs for blocks b-1, b, b+1; reads tx origin for relevant swaps.
NO transactions, signing, state mutation, or archive-state reads.
"""
import json
import os
import time
import urllib.error
import urllib.request
from collections import defaultdict
from decimal import Decimal, getcontext

getcontext().prec = 70

RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
POOL = "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9"
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
VICTIMS = [
    {"block": 26478318, "tx_index": 207,
     "hash": "0xf16bd190cf0c12b347035abd8528308f3b4f9c09e73b341a8c35ccc496dcdd40"},
    {"block": 26478348, "tx_index": 235,
     "hash": "0xabfd65f56c8188041d2760fb672fc61e96afd53e78d265001a22fd9d3119643d"},
    {"block": 26478363, "tx_index": 184,
     "hash": "0x5e871d0f2ba2bac08b257ae2c871ab28d4a119082576acd9c9d0f70e25677bd3"}
]

def call(method, params):
    payload = json.dumps({"jsonrpc":"2.0","id":368,"method":method,"params":params}).encode()
    req = urllib.request.Request(RPC, data=payload, headers={"Content-Type":"application/json"})
    last_error = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as conn:
                data = json.load(conn)
            if data.get("error"):
                raise RuntimeError(str(data["error"])[:350])
            return data.get("result")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as ex:
            last_error = str(ex)
            if attempt < 2:
                time.sleep(attempt + 1)
    raise RuntimeError(f"{method}: {last_error}")

def signed256(h):
    n = int(h, 16)
    return n - (1 << 256) if n >= (1 << 255) else n

def dec(n, digits):
    return str(Decimal(n) / Decimal(10 ** digits))

def swap_log(log):
    topics = log.get("topics") or []
    if len(topics) < 3 or str(topics[1]).lower() != POOL:
        return None
    raw = (log.get("data") or "0x")[2:]
    if len(raw) < 64 * 6:
        return None
    fields = [raw[64*i:64*(i+1)] for i in range(6)]
    a0 = signed256(fields[0])
    a1 = signed256(fields[1])
    tick = signed256(fields[4])
    return {
        "block": int(log["blockNumber"], 16),
        "tx_index": int(log["transactionIndex"], 16),
        "log_index": int(log["logIndex"], 16),
        "tx_hash": log["transactionHash"].lower(),
        "router_sender": "0x" + str(topics[2])[-40:].lower(),
        "pool_amount0_USDT": dec(a0, 6),
        "pool_amount1_USDS": dec(a1, 18),
        "swap_direction": ("USDT_to_USDS" if a0 < 0 and a1 > 0
            else "USDS_to_USDT" if a0 > 0 and a1 < 0 else "OTHER"),
        "tick_after": tick,
        "fee_hundredths_bip": int(fields[5],16),
        "sqrt_price_x96_after": str(int(fields[2], 16)),
        "explorer": "https://etherscan.io/tx/" + log["transactionHash"].lower()
    }

def tx_sender(tx_hash, cache):
    if tx_hash not in cache:
        try:
            tx = call("eth_getTransactionByHash", [tx_hash])
            cache[tx_hash] = {
                "from": str((tx or {}).get("from") or "").lower(),
                "to": str((tx or {}).get("to") or "").lower(),
                "value": str(int((tx or {}).get("value", "0x0"),16)),
                "gas_price_wei": str(int((tx or {}).get("gasPrice", "0x0"), 16)),
            }
        except Exception as ex:
            cache[tx_hash] = {"lookup_error":str(ex)[:220]}
    return cache[tx_hash]

def log_context(block):
    params = [{
        "fromBlock": hex(block),
        "toBlock": hex(block),
        "address": POOL_MANAGER,
        "topics": [SWAP_TOPIC, POOL]
    }]
    results = call("eth_getLogs", params)
    if not isinstance(results, list):
        raise RuntimeError("Invalid eth_getLogs response")
    parsed = []
    for l in results:
        item = swap_log(l)
        if item is not None:
            parsed.append(item)
    return sorted(parsed,key=lambda x:(x["tx_index"], x["log_index"]))

print("=== PASSO 368: ORDERING OF REAL USDT/USDS SWAPS ===",flush=True)
print("Only Uniswap V4 pool", POOL, "in the three victim blocks +/- 1",flush=True)
print("Read-only RPC methods: eth_getLogs, eth_getTransactionByHash",flush=True)

all_blocks = sorted({v["block"] + offset for v in VICTIMS for offset in (-1,0,1)})
blocks = {}
senders = {}
for block in all_blocks:
    try:
        swaps = log_context(block)
        for s in swaps:
            s.update(tx_sender(s["tx_hash"], senders))
        blocks[block] = {"status":"ok","swaps":swaps}
        print("Block",block,"same-pool V4 swaps",len(swaps),flush=True)
    except Exception as ex:
        blocks[block] = {"status":"inconclusive","error":str(ex)[:300],"swaps":[]}
        print("Block",block,"INCONCLUSIVE:",str(ex)[:230],flush=True)
    time.sleep(0.2)

analysis=[]
for victim in VICTIMS:
    block = victim["block"]
    tx_hash = victim["hash"]
    print("\n=== SPARK SWAP",tx_hash,"block",block,"index",victim["tx_index"],"===",flush=True)
    info = blocks[block]
    if info["status"] != "ok":
        analysis.append({"victim":victim,"status":"inconclusive_logs","same_block_swaps":[]})
        print("BLOCK DATA UNAVAILABLE",flush=True)
        continue

    swaps = info["swaps"]
    victims_in_block = [s for s in swaps if s["tx_hash"] == tx_hash]
    before = [s for s in swaps if s["tx_index"] < victim["tx_index"]]
    after = [s for s in swaps if s["tx_index"] > victim["tx_index"]]
    other = [s for s in swaps if s["tx_hash"] != tx_hash]
    current = {
        "victim":victim,
        "victim_core_events": victims_in_block,
        "swaps_before": before,
        "swaps_after": after,
        "all_same_pool_swaps_in_block": swaps,
        "adjacent_blocks": {
            str(b): blocks[b] for b in (block-1, block+1)
        },
        "candidate_roundtrip_patterns": [],
    }
    print("Verified Spark events:",len(victims_in_block),flush=True)
    print("Other same-pool swaps before Spark:",len(before),flush=True)
    print("Other same-pool swaps after Spark:",len(after),flush=True)
    for s in swaps:
        tag = "SPARK" if s["tx_hash"] == tx_hash else ("BEFORE" if s["tx_index"] < victim["tx_index"] else "AFTER")
        print(tag,
              "tx_index",s["tx_index"],"log_index",s["log_index"],
              "direction",s["swap_direction"],
              "pool_delta_USDT",s["pool_amount0_USDT"],
              "pool_delta_USDS",s["pool_amount1_USDS"],
              "origin",s.get("from"),"hash",s["tx_hash"],flush=True)

    # Only flag a pattern when distinct transactions from the same
    # top-level tx origin surround the Spark trade in the SAME block,
    # entering USDT->USDS before Spark and reversing it after Spark.
    for first in before:
        if first["swap_direction"] != "USDT_to_USDS" or not first.get("from"):
            continue
        for back in after:
            if (back["swap_direction"] != "USDS_to_USDT"
                or back.get("from") != first.get("from")
                or back["tx_hash"] == first["tx_hash"]):
                continue
            approx_usdt = Decimal(first["pool_amount0_USDT"]) + Decimal(back["pool_amount0_USDT"])
            approx_usds = Decimal(first["pool_amount1_USDS"]) + Decimal(back["pool_amount1_USDS"])
            candidate = {
                "first_hash":first["tx_hash"],"back_hash":back["tx_hash"],
                "same_tx_origin":first["from"],
                "gross_USDT_delta_at_pool":str(approx_usdt),
                "gross_USDS_delta_at_pool":str(approx_usds),
                "nominal_pair_delta_without_fees_gas_other_swaps":str(approx_usdt + approx_usds),
                "IMPORTANT":"Pattern only; not proof of sandwich or profit."
            }
            current["candidate_roundtrip_patterns"].append(candidate)
            print("POSSIBLE SAME-BLOCK ROUNDTRIP:",json.dumps(candidate),flush=True)
    if not current["candidate_roundtrip_patterns"]:
        print("No matching same-origin, same-block, opposite-direction roundtrip in scanned events.",flush=True)
    if not victims_in_block:
        print("WARNING: victim swap event missing from eth_getLogs result",flush=True)
    analysis.append(current)

report = {
    "scope":"Three historical Spark USDT/USDS swaps, same pool and b-1/b/b+1",
    "blocks_scanned":{str(k):v for k,v in blocks.items()},
    "analyses":analysis,
    "caveats":[
        "No detected roundtrip is not proof of no MEV; different addresses, bundles and cross-pool paths can evade matching.",
        "Same-block ordering alone does not establish mempool visibility or attacker identity.",
        "P&L approximation ignores gas, external pools, transfers, and other transactions.",
        "One block before/after is only contextual and not sufficient to infer a sandwich."
    ]
}
with open("audit-output/pass368_block_mev_review.json","w") as f:
    json.dump(report,f,ensure_ascii=False,indent=2)

print("\n=== PASSO 368 SUMMARY ===",flush=True)
print("Blocks requested:",len(all_blocks),flush=True)
print("Blocks loaded:",sum(v["status"]=="ok" for v in blocks.values()),flush=True)
print("Candidate same-origin roundtrip patterns:",sum(len(v.get("candidate_roundtrip_patterns",[])) for v in analysis),flush=True)
print("Report: audit-output/pass368_block_mev_review.json",flush=True)
print("No transactions sent, no archive-state access required.",flush=True)
