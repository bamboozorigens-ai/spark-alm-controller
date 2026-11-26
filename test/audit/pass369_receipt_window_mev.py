#!/usr/bin/env python3
"""
PASSO 369: Read-only same-block USDT/USDS V4 swap-order audit around the
3 ACTUAL Spark swaps verified in pass 367. No eth_getLogs and no archive state.

Transaction indexes come from eth_getBlockByNumber; fallback: Blockscout
GET /api/v2/blocks/{number}/transactions with paginated indexed records.
Receipts are fetched with eth_getTransactionReceipt and searched for the
V4 PoolManager Swap event + pool ID. This does NOT prove intent or MEV.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, getcontext

getcontext().prec = 65
RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
BS = "https://eth.blockscout.com/api/v2"
POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
POOL_ID = "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9"
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
WINDOW = int(os.environ.get("SPARK_TX_WINDOW", "30"))
MAX_PAGES = 28
TARGETS = [
    (26478318, 207, "0xf16bd190cf0c12b347035abd8528308f3b4f9c09e73b341a8c35ccc496dcdd40"),
    (26478348, 235, "0xabfd65f56c8188041d2760fb672fc61e96afd53e78d265001a22fd9d3119643d"),
    (26478363, 184, "0x5e871d0f2ba2bac08b257ae2c871ab28d4a119082576acd9c9d0f70e25677bd3")
]

def request_json(url, payload=None):
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"User-Agent": "SparkReadOnlyHistory/369", "Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=body, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as res:
                return json.load(res)
        except urllib.error.HTTPError as e:
            detail = e.read(350).decode("utf-8", "replace")
            last = "HTTP " + str(e.code) + ": " + detail[:230]
            if e.code in (400, 403, 404, 422):
                break
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            last = str(e)
        if attempt < 2:
            time.sleep(1 + attempt)
    raise RuntimeError(last or "Network request failed")

def rpc(method, params):
    answer = request_json(RPC, {"jsonrpc": "2.0", "id": 369,
                                "method": method, "params": params})
    if answer.get("error"):
        raise RuntimeError(str(answer["error"])[:280])
    return answer.get("result")

def clean_cursor(data):
    return {k: v for k, v in (data or {}).items()
            if v is not None and not isinstance(v, bool)
            and k != "include_zero_value"}

def blockscout_block_transactions(block):
    mapping = {}
    next_page = {}
    seen_cursors = set()
    error = None
    complete = False
    pages = 0
    for _ in range(MAX_PAGES):
        sig = json.dumps(next_page, sort_keys=True)
        if sig in seen_cursors:
            error = "Repeated block pagination cursor"
            break
        seen_cursors.add(sig)
        params = clean_cursor(next_page)
        url = BS + "/blocks/" + str(block) + "/transactions"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        try:
            data = request_json(url)
        except Exception as exc:
            error = str(exc)[:230]
            break
        pages += 1
        items = data.get("items") or []
        if not isinstance(items, list):
            error = "Unexpected Blockscout transaction list"
            break
        for item in items:
            index = item.get("position")
            if index is None:
                index = item.get("transaction_index")
            tx_hash = item.get("hash")
            try:
                index = int(index)
            except (ValueError, TypeError):
                continue
            if isinstance(tx_hash, str) and tx_hash.startswith("0x"):
                mapping[index] = tx_hash.lower()
        nxt = data.get("next_page_params")
        if not nxt:
            complete = True
            break
        next_page = clean_cursor(nxt)
        if not next_page:
            error = "Empty cursor after pagination filtering"
            break
        time.sleep(0.12)
    else:
        error = "Blockscout page cap reached"
    return mapping, {"source": "Blockscout block transactions", "pages": pages,
                     "complete": complete, "error": error}

def get_block_transactions(block, victim_index, victim_hash):
    try:
        data = rpc("eth_getBlockByNumber", [hex(block), False])
        txs = (data or {}).get("transactions") or []
        if not txs:
            raise RuntimeError("No transactions returned")
        mapping = {i: item.lower() for i, item in enumerate(txs)}
        if mapping.get(victim_index) != victim_hash:
            raise RuntimeError("Block RPC victim tx mismatch")
        return mapping, {"source": "eth_getBlockByNumber", "complete": True,
                         "block_tx_count": len(mapping), "error": None}
    except Exception as exc:
        print("  BLOCK RPC FALLBACK:", str(exc)[:155], flush=True)
    mapping, meta = blockscout_block_transactions(block)
    if mapping.get(victim_index) != victim_hash:
        raise RuntimeError("Blockscout index mismatch: expected Spark "
                           + victim_hash[:14] + " at " + str(victim_index)
                           + " but saw " + str(mapping.get(victim_index)))
    return mapping, meta

def signed256(word):
    v = int(word, 16)
    return v - (1 << 256) if v >= 1 << 255 else v

def parse_swap_events(receipt):
    found = []
    for log in receipt.get("logs", []):
        if (str(log.get("address") or "").lower() != POOL_MANAGER):
            continue
        topics = log.get("topics") or []
        if (len(topics) < 3 or str(topics[0]).lower() != SWAP_TOPIC
                or str(topics[1]).lower() != POOL_ID):
            continue
        raw = str(log.get("data") or "0x")[2:]
        if len(raw) < 384:
            continue
        words = [raw[64*i:64*(i+1)] for i in range(6)]
        a0 = signed256(words[0])
        a1 = signed256(words[1])
        tick = signed256(words[4])
        found.append({
            "block_number": int(receipt["blockNumber"], 16),
            "tx_index": int(receipt["transactionIndex"], 16),
            "log_index": int(log["logIndex"], 16),
            "tx_hash": receipt["transactionHash"].lower(),
            "direction": ("USDT_to_USDS" if a0 < 0 and a1 > 0 else
                          "USDS_to_USDT" if a0 > 0 and a1 < 0 else "other"),
            "pool_amount_USDT": str(Decimal(a0) / Decimal(10 ** 6)),
            "pool_amount_USDS": str(Decimal(a1) / Decimal(10 ** 18)),
            "pool_tick_after": tick,
            "sqrt_price_x96_after": str(int(words[2], 16)),
        })
    return found

def tx_origin(tx_hash):
    try:
        tx = rpc("eth_getTransactionByHash", [tx_hash])
        return str((tx or {}).get("from") or "").lower()
    except Exception:
        return ""

print("=== PASSO 369: HISTORIC RECEIPTS INSTEAD OF eth_getLogs ===",flush=True)
print("Window: up to",WINDOW,"transactions BEFORE and AFTER each Spark swap.",flush=True)
print("CAUTION: a bounded window is NOT the full block.",flush=True)

reports = []
for block, victim_index, victim_hash in TARGETS:
    print("\n=== SPARK",victim_hash,"BLOCK",block,"IDX",victim_index,"===",flush=True)
    report = {
        "victim_tx": victim_hash, "block": block, "victim_index": victim_index,
        "window_radius": WINDOW, "events": [], "errors": []
    }
    try:
        mapping, source = get_block_transactions(block, victim_index, victim_hash)
        report["block_transaction_index"] = source
        lower = max(0, victim_index - WINDOW)
        upper = min(max(mapping), victim_index + WINDOW)
        indices = list(range(lower, upper + 1))
        report["window"] = [lower, upper]
        absent = [i for i in indices if i not in mapping]
        if absent:
            report["errors"].append("Missing indexed transactions: " + str(absent[:12]))
        print("  Transaction index source:",source["source"],flush=True)
        print("  Window:",lower,"to",upper,"indexed hashes:",len(indices)-len(absent),flush=True)

        all_events = []
        receipts_ok = 0
        for i in indices:
            tx_hash = mapping.get(i)
            if not tx_hash:
                continue
            try:
                receipt = rpc("eth_getTransactionReceipt", [tx_hash])
                if not isinstance(receipt, dict):
                    raise RuntimeError("No receipt")
                if int(receipt.get("status", "0x0"),16) != 1:
                    receipts_ok += 1
                    continue
                all_events.extend(parse_swap_events(receipt))
                receipts_ok += 1
            except Exception as exc:
                report["errors"].append("Receipt tx #" + str(i) + ": " + str(exc)[:180])
            if (i - lower) % 20 == 19:
                print("  Receipts processed:",i-lower+1,"of",len(indices),flush=True)
            time.sleep(0.06)

        report["receipts_loaded"] = receipts_ok
        report["receipts_expected"] = len(indices)
        report["fully_scanned_window"] = receipts_ok == len(indices)
        for e in all_events:
            e["tx_origin"] = tx_origin(e["tx_hash"])
            time.sleep(0.04)
        all_events.sort(key=lambda x:(x["tx_index"],x["log_index"]))
        report["events"] = all_events
        victim_events = [e for e in all_events if e["tx_hash"] == victim_hash]
        before = [e for e in all_events if e["tx_index"] < victim_index]
        after = [e for e in all_events if e["tx_index"] > victim_index]
        report["spark_pool_event_seen"] = len(victim_events) > 0
        report["before_count"] = len(before)
        report["after_count"] = len(after)

        print("  RECEIPTS",receipts_ok,"/",len(indices),flush=True)
        print("  V4 same-pool Swap events:",len(all_events),
              "before Spark:",len(before),"Spark:",len(victim_events),
              "after Spark:",len(after),flush=True)
        for e in all_events:
            label = "SPARK" if e["tx_hash"] == victim_hash else (
                "BEFORE" if e["tx_index"] < victim_index else "AFTER")
            print(" ",label,"#"+str(e["tx_index"]),
                  e["direction"],
                  "USDT",e["pool_amount_USDT"],"USDS",e["pool_amount_USDS"],
                  "origin",e["tx_origin"][:15],
                  "tx",e["tx_hash"],flush=True)

        patterns = []
        for front in before:
            if front["direction"] != "USDT_to_USDS":
                continue
            for back in after:
                if back["direction"] != "USDS_to_USDT":
                    continue
                origin_matches = (
                    bool(front["tx_origin"]) and
                    front["tx_origin"] == back["tx_origin"]
                )
                patterns.append({
                    "front_tx": front["tx_hash"],
                    "back_tx": back["tx_hash"],
                    "front_index": front["tx_index"],
                    "back_index": back["tx_index"],
                    "same_top_level_sender": origin_matches,
                    "classification": (
                        "Same-origin reverse sequence worth investigation"
                        if origin_matches else "Opposite-direction shape ONLY; no identity link"
                    )
                })
        report["opposite_direction_patterns"] = patterns
        print("  Opposite-direction ordering patterns:",len(patterns),flush=True)
        print("  Same-origin patterns:",sum(p["same_top_level_sender"] for p in patterns),flush=True)
        if not report["fully_scanned_window"]:
            print("  INCOMPLETE: receipt errors prevent a negative conclusion.",flush=True)
        elif not patterns:
            print("  No opposite-direction pattern IN THIS LIMITED WINDOW.",flush=True)
    except Exception as exc:
        report["errors"].append(str(exc)[:350])
        print("  BLOCK INCONCLUSIVE:",str(exc)[:250],flush=True)
    reports.append(report)

out="audit-output/pass369_receipt_window_mev.json"
with open(out,"w") as f:
    json.dump({
        "scanned":reports,
        "limitations":[
            "Only up to 30 transactions each side by default, not entire block or adjacent blocks.",
            "Same-block opposite directions do not prove sandwich.",
            "Different origins, bridges and pools may hide MEV; missing receipts hide activity.",
            "No gas, orderflow privacy, block-builder bribes or attacker net profitability measured."
        ]
    },f,indent=2,ensure_ascii=False)

print("\n=== PASSO 369 SUMMARY ===",flush=True)
print("Targets:",len(reports),flush=True)
print("Complete windows:",sum(bool(x.get("fully_scanned_window")) for x in reports),flush=True)
print("Detected opposite-direction patterns:",sum(len(x.get("opposite_direction_patterns",[])) for x in reports),flush=True)
print("Historical receipt review only; NOT a proven attack.",flush=True)
print("Saved",out,flush=True)
print("NO TRANSACTION SENT.",flush=True)
