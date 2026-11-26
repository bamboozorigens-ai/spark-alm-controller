#!/usr/bin/env python3
# PASSO 366 - Validate three historical Spark swaps using canonical Ethereum
# transaction receipts. Read-only requests: NO wallet, NO eth_sendTransaction.
# Do NOT confuse the proxy's net token transfers in a multicall with the
# gross tokens used by a single Uniswap V4 swap.

import json
import os
import subprocess
import time
import urllib.request
from decimal import Decimal, getcontext

getcontext().prec = 70
RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
POOL = "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9"
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
USDS = "0xdc035d45d973e3ec169d2276ddab16f1e407384f"
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
SWAP_SIGNATURE = "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"

TRANSACTIONS = [
    {
        "hash": "0x5e871d0f2ba2bac08b257ae2c871ab28d4a119082576acd9c9d0f70e25677bd3",
        "min_out_USDS": "999000.999000999000999",
    },
    {
        "hash": "0xabfd65f56c8188041d2760fb672fc61e96afd53e78d265001a22fd9d3119643d",
        "min_out_USDS": "999000.999000999000999",
    },
    {
        "hash": "0xf16bd190cf0c12b347035abd8528308f3b4f9c09e73b341a8c35ccc496dcdd40",
        "min_out_USDS": "999020.959459729465124178",
    },
]

def get_topic(signature):
    out = subprocess.run(
        ["cast", "keccak", signature],
        capture_output=True, text=True, timeout=15
    )
    if out.returncode != 0:
        raise RuntimeError("Cannot derive event topic via Foundry cast: " + out.stderr[:180])
    value = out.stdout.strip().lower()
    if not value.startswith("0x") or len(value) != 66:
        raise RuntimeError("Unexpected keccak topic: " + value)
    return value

def rpc_receipt(tx_hash):
    body = json.dumps({
        "jsonrpc": "2.0", "id": 366,
        "method": "eth_getTransactionReceipt", "params": [tx_hash]
    }).encode()
    req = urllib.request.Request(
        RPC, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=30) as stream:
        response = json.load(stream)
    if response.get("error"):
        raise RuntimeError(str(response["error"])[:300])
    if not response.get("result"):
        raise RuntimeError("No Ethereum receipt returned")
    return response["result"]

def d18(n):
    return str(Decimal(n) / Decimal(10 ** 18))

def d6(n):
    return str(Decimal(n) / Decimal(10 ** 6))

def parse_int(hex_value, bits=256):
    raw = int(hex_value, 16)
    if raw & (1 << (bits - 1)):
        raw -= 1 << bits
    return raw

def pool_swap_events(receipt, topic):
    result = []
    for log in receipt.get("logs", []):
        topics = log.get("topics") or []
        if (str(log.get("address", "")).lower() != POOL_MANAGER
            or len(topics) < 3
            or str(topics[0]).lower() != topic
            or str(topics[1]).lower() != POOL):
            continue
        data = log.get("data", "0x")[2:]
        if len(data) < 64 * 6:
            result.append({"error": "Short Uniswap V4 Swap data", "log_index": int(log["logIndex"], 16)})
            continue
        words = [data[64*i:64*(i+1)] for i in range(6)]
        amount0 = parse_int(words[0])
        amount1 = parse_int(words[1])
        tick = parse_int(words[4])
        evt = {
            "log_index": int(log["logIndex"], 16),
            "sender": "0x" + str(topics[2])[-40:].lower(),
            "amount0_USDT": d6(amount0),
            "amount1_USDS": d18(amount1),
            "sqrt_price_x96": str(int(words[2], 16)),
            "liquidity": str(int(words[3], 16)),
            "tick": tick,
            "fee": int(words[5], 16),
            "direction_USDT_to_USDS": amount0 < 0 and amount1 > 0
        }
        result.append(evt)
    return result

def parse_transfer_logs(receipt):
    rows = []
    for log in receipt.get("logs", []):
        token = str(log.get("address", "")).lower()
        if token not in (USDT, USDS):
            continue
        topics = log.get("topics") or []
        if len(topics) != 3 or str(topics[0]).lower() != TRANSFER_TOPIC:
            continue
        sender = "0x" + str(topics[1])[-40:].lower()
        recipient = "0x" + str(topics[2])[-40:].lower()
        symbol = "USDT" if token == USDT else "USDS"
        amount = int(log.get("data", "0x0"), 16)
        value = Decimal(amount) / Decimal(10 ** (6 if symbol == "USDT" else 18))
        rows.append({
            "log_index": int(log["logIndex"], 16),
            "symbol": symbol,
            "amount": str(value),
            "from": sender,
            "to": recipient
        })
    return sorted(rows, key=lambda x: x["log_index"])

def gross_proxy(rows):
    result = {
        symbol: {"in": Decimal(0), "out": Decimal(0)}
        for symbol in ("USDT", "USDS")
    }
    for row in rows:
        amount = Decimal(row["amount"])
        slot = result[row["symbol"]]
        if row["to"] == PROXY:
            slot["in"] += amount
        if row["from"] == PROXY:
            slot["out"] += amount
    return {
        sym: {"gross_in": str(data["in"]),
              "gross_out": str(data["out"]),
              "net": str(data["in"] - data["out"])}
        for sym, data in result.items()
    }

print("=== PASSO 367: EVENTO CORE CORRIGIDO E SWAPS VERIFICADOS ===", flush=True)
actual_transfer_topic = get_topic("Transfer(address,address,uint256)")
if actual_transfer_topic != TRANSFER_TOPIC:
    raise RuntimeError("ERC20 Transfer topic mismatch; stop analysis")
SWAP_TOPIC = get_topic(SWAP_SIGNATURE)
print("Uniswap V4 Swap event topic:", SWAP_TOPIC, flush=True)
print("Read-only Ethereum JSON-RPC: eth_getTransactionReceipt", flush=True)

report = []
for entry in TRANSACTIONS:
    tx_hash = entry["hash"]
    print("\n=== TX", tx_hash, "===", flush=True)
    record = {"hash": tx_hash, "expected_controller_call": {
        "token_in": "USDT", "amount_in": "1000000",
        "min_out_USDS": entry["min_out_USDS"]
    }}
    try:
        receipt = rpc_receipt(tx_hash)
        record["status"] = int(receipt["status"], 16)
        record["block_number"] = int(receipt["blockNumber"], 16)
        record["tx_index"] = int(receipt["transactionIndex"], 16)
        record["log_count"] = len(receipt.get("logs", []))

        events = pool_swap_events(receipt, SWAP_TOPIC)
        rows = parse_transfer_logs(receipt)
        gross = gross_proxy(rows)
        record["pool_swap_events"] = events
        record["proxy_gross_flows"] = gross
        record["all_USDT_USDS_transfers"] = rows

        eligible = [
            evt for evt in events
            if evt.get("direction_USDT_to_USDS")
            and Decimal(evt["amount0_USDT"]) == Decimal(-1_000_000)
            and Decimal(evt["amount1_USDS"]) >= Decimal(entry["min_out_USDS"])
        ]
        record["matched_successful_pool_swap"] = (
            record["status"] == 1 and len(eligible) >= 1
        )

        print("Top-level receipt success:", record["status"] == 1, flush=True)
        print("Block:", record["block_number"], "tx index:", record["tx_index"], flush=True)
        print("USDT/USDS pool Swap events:", len(events), flush=True)
        for evt in events:
            print("  CORE SWAP EVENT:", json.dumps(evt), flush=True)
        for token, measures in gross.items():
            print("Proxy", token, "gross IN:", measures["gross_in"],
                "gross OUT:", measures["gross_out"], "NET:", measures["net"], flush=True)
        print("ALL ERC20 USDT/USDS TRANSFER EVENTS, IN CHAIN ORDER:", flush=True)
        for row in rows:
            print(" ", json.dumps(row), flush=True)
        print("MATCHED SUCCESSFUL CORE SWAP:", record["matched_successful_pool_swap"], flush=True)
    except Exception as exc:
        record["error"] = str(exc)[:350]
        record["matched_successful_pool_swap"] = False
        print("INCONCLUSIVE:", record["error"], flush=True)
    report.append(record)
    time.sleep(0.35)

validated = sum(bool(r.get("matched_successful_pool_swap")) for r in report)
with open("audit-output/pass367_swap_events.json", "w") as stream:
    json.dump({
        "validation_count": validated,
        "transactions": report,
        "note": "Swap events can confirm pool execution; wallet net movement can be zero in a multicall."
    }, stream, indent=2, ensure_ascii=False)

print("\n=== SUMMARY ===", flush=True)
print("Successful core swaps matching 1m USDT + minOut:", validated, "/", len(report), flush=True)
print("Archive RPC is NOT required for historical transaction receipts.", flush=True)
print("Does not establish mempool visibility, sandwich, attacker identity or novel vulnerability.", flush=True)
print("NO TRANSACTIONS SENT. Report: audit-output/pass367_swap_events.json", flush=True)
