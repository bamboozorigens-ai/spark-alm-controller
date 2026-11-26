#!/usr/bin/env python3
# PASSO 362: Read-only historical search for actual Spark Uniswap V4 swaps.
# Uses the public Blockscout indexed REST API; never signs or sends transactions.
# Both direct and internal contract calls are examined because relayers may be Safes.
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal

BASE = "https://eth.blockscout.com/api/v2"
CONTROLLERS = {
    "V1_10_OLD": "0x5c46fc65855c0c7465a1ea85eea0b24b601502d3",
    "V1_11_NEW": "0xc953972cd006d1f12686fd7185c6d443b15900cd",
}
TOKENS = {
    "0x8292bb45bf1ee4d140127049757c2e0ff06317ed": ("RLUSD", 18),
    "0xdc035d45d973e3ec169d2276ddab16f1e407384f": ("USDS", 18),
    "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6),
    "0x6c3ea9036406852006290770bedfcaba0e23a0e8": ("PYUSD", 6),
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6),
}
POOLS = {
    "0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f": "RLUSD/USDS",
    "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9": "USDT/USDS",
    "0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45": "PYUSD/USDS",
}
PAGE_LIMIT = 8
SIGNATURE = "swapUniswapV4(bytes32,address,uint128,uint128)"

def get_selector():
    result = subprocess.run(
        ["cast", "sig", SIGNATURE],
        capture_output=True, text=True, timeout=15
    )
    if result.returncode != 0:
        raise RuntimeError("Foundry cast missing: " + result.stderr[:150])
    return result.stdout.strip().lower()

SELECTOR = get_selector()

def request_json(url):
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0 SparkReadOnlyAudit/1.0"}
            )
            with urllib.request.urlopen(req, timeout=25) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError) as exc:
            last = exc
            if attempt < 2:
                time.sleep(1 + attempt)
    raise RuntimeError(str(last))

def address_of(value):
    if isinstance(value, str):
        return value.lower()
    if isinstance(value, dict):
        return str(value.get("hash") or value.get("address") or "").lower()
    return ""

def raw_input_of(obj):
    for name in ("raw_input", "input", "data", "calldata"):
        value = obj.get(name)
        if isinstance(value, str) and value.startswith("0x") and len(value) >= 10:
            return value.lower()
    return ""

def parse_swap(raw):
    if not raw.startswith(SELECTOR):
        return None
    if len(raw) < 10 + 64 * 4:
        return {"error": "Short calldata", "raw_input": raw[:80]}
    words = [raw[10 + 64 * i:10 + 64 * (i+1)] for i in range(4)]
    pool = "0x" + words[0]
    token = "0x" + words[1][-40:]
    amount = int(words[2], 16)
    minimum = int(words[3], 16)
    symbol, decimals = TOKENS.get(token, ("UNKNOWN", 18))
    # Token output decimals are known only for the three mapped 2-token pools.
    output_decimals = 18
    if POOLS.get(pool) == "USDT/USDS" and symbol == "USDS":
        output_decimals = 6
    elif POOLS.get(pool) == "USDT/USDS" and symbol == "USDT":
        output_decimals = 18
    elif POOLS.get(pool) == "PYUSD/USDS" and symbol == "USDS":
        output_decimals = 6
    elif POOLS.get(pool) == "PYUSD/USDS" and symbol == "PYUSD":
        output_decimals = 18

    amount_decimal = Decimal(amount) / Decimal(10 ** decimals)
    minimum_decimal = Decimal(minimum) / Decimal(10 ** output_decimals)
    ratio = (minimum_decimal / amount_decimal) if amount_decimal else Decimal(0)

    return {
        "pool": POOLS.get(pool, "OTHER_POOL"),
        "pool_id": pool,
        "token_in": symbol,
        "token_in_address": token,
        "amount_in": str(amount_decimal),
        "amount_out_min": str(minimum_decimal),
        "minimum_ratio_to_par": str(ratio),
        "raw_amount_in": str(amount),
        "raw_min_out": str(minimum),
    }

def scan(label, controller, endpoint):
    print("\n---", label, endpoint, "---", flush=True)
    cursor = {}
    page_count = 0
    scanned = 0
    matches = []
    error = None
    exhausted = False
    for _ in range(PAGE_LIMIT):
        params = {"filter": "to"} if endpoint == "transactions" else {}
        params.update(cursor)
        url = (
            BASE + "/addresses/" + controller + "/" + endpoint
            + "?" + urllib.parse.urlencode(params)
        )
        try:
            data = request_json(url)
            items = data.get("items", [])
            if not isinstance(items, list):
                raise RuntimeError("Invalid items in response")
        except Exception as exc:
            error = str(exc)[:200]
            print("REQUEST INCONCLUSIVE:", error, flush=True)
            break

        page_count += 1
        scanned += len(items)
        print("Page", page_count, "records", len(items), flush=True)

        for tx in items:
            if address_of(tx.get("to")) != controller:
                continue
            raw = raw_input_of(tx)
            method = str(tx.get("method") or "").lower()
            decoded = tx.get("decoded_input")
            decoded_method = (
                str(decoded.get("method_call") or "").lower()
                if isinstance(decoded, dict) else ""
            )
            is_target = raw.startswith(SELECTOR) or "swapuniswapv4" in (method + decoded_method)
            if not is_target:
                continue

            parsed = parse_swap(raw)
            item = {
                "contract_version": label,
                "call_kind": endpoint,
                "timestamp": tx.get("timestamp"),
                "block_number": tx.get("block_number"),
                "transaction_hash": tx.get("hash") or tx.get("transaction_hash"),
                "from_address": address_of(tx.get("from")),
                "to_address": address_of(tx.get("to")),
                "status": tx.get("status"),
                "method": tx.get("method"),
                "has_raw_calldata": bool(raw),
                "parsed_swap": parsed
            }
            if item["transaction_hash"]:
                item["explorer_url"] = "https://eth.blockscout.com/tx/" + item["transaction_hash"]
            matches.append(item)
            print("POSSIBLE REAL SWAP:", json.dumps(item, ensure_ascii=False), flush=True)

        next_params = data.get("next_page_params")
        if not isinstance(next_params, dict) or not next_params:
            exhausted = True
            break
        cursor = next_params
        time.sleep(0.35)
    return {
        "controller": controller,
        "endpoint": endpoint,
        "pages": page_count,
        "records_scanned": scanned,
        "is_exhaustive": exhausted,
        "error": error,
        "matches": matches,
    }

print("=== PASSO 362: REAL SPARK SWAP HISTORY ===", flush=True)
print("Source: Blockscout API v2, readonly", flush=True)
print("Method selector:", SELECTOR, flush=True)

result = {"method":SIGNATURE,"selector":SELECTOR,"runs":[],"unique_transactions":[]}
dedup = {}
for label, controller in CONTROLLERS.items():
    for endpoint in ("transactions", "internal-transactions"):
        run = scan(label, controller, endpoint)
        result["runs"].append(run)
        for item in run["matches"]:
            dedup[
                (item.get("transaction_hash"), label, item.get("call_kind"))
            ] = item

result["unique_transactions"] = list(dedup.values())
print("\n=== SUMMARY ===", flush=True)
for run in result["runs"]:
    print(
        run["endpoint"], run["controller"][:14],
        "pages", run["pages"],
        "records", run["records_scanned"],
        "matches", len(run["matches"]),
        "complete", run["is_exhaustive"],
        "error", run["error"],
        flush=True
    )
print("Candidate matching calls", len(result["unique_transactions"]), flush=True)
print("Not finding a call does NOT prove no swaps: pagination and internal indexes can be partial.", flush=True)

with open("audit-output/pass362_swap_history.json", "w") as file:
    json.dump(result, file, ensure_ascii=False, indent=2)

print("Saved audit-output/pass362_swap_history.json", flush=True)
print("NO ARCHIVE RPC. NO LIVE TRANSACTIONS. NO KEYS REQUIRED.", flush=True)
