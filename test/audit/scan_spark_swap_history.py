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
        except urllib.error.HTTPError as exc:
            # Expose error response because a 422 often means invalid cursor fields.
            body = exc.read(480).decode("utf-8", "replace")
            if exc.code in (400, 404, 422):
                raise RuntimeError("HTTP %s %s" % (exc.code, body[:240])) from exc
            last = "HTTP %s %s" % (exc.code, body[:150])
            if attempt < 2:
                time.sleep(1 + attempt)
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            last = str(exc)
            if attempt < 2:
                time.sleep(1 + attempt)
    raise RuntimeError(str(last))


def clean_cursor(cursor):
    # urlencode(None) produces literal "None": invalid for Blockscout integer cursors.
    return {key: value for key, value in cursor.items() if value is not None}


def get_page(controller, endpoint, cursor):
    fixed = {"filter": "to"} if endpoint == "transactions" else {}
    attempts = [clean_cursor(cursor)]
    if cursor:
        # Blockscout's pagination cursors vary by endpoint; retry conservative
        # alternatives rather than stopping on the first 422.
        attempts.extend([
            {k: v for k, v in clean_cursor(cursor).items()
             if k != "items_count"},
            {k: v for k, v in clean_cursor(cursor).items()
             if k not in ("items_count", "index")},
        ])
    tried = set()
    errors = []
    for attempt in attempts:
        query = {**fixed, **attempt}
        url = BASE + "/addresses/" + controller + "/" + endpoint
        if query:
            url += "?" + urllib.parse.urlencode(query)
        if url in tried:
            continue
        tried.add(url)
        try:
            return request_json(url)
        except RuntimeError as exc:
            errors.append(str(exc))
            print("CURSOR REQUEST FAILED:", str(exc)[:180], flush=True)
    raise RuntimeError("Pagination alternatives exhausted: " + " | ".join(errors)[-600:])


def _walk_trace(root, target):
    # Blockscout may return either a list of flat Parity traces or a nested
    # callTracer-like tree. Internal calldata lives in the raw trace, not the
    # address internal-transactions summary record.
    stack = [root]
    inspected = 0
    while stack and inspected < 250000:
        node = stack.pop()
        inspected += 1
        if isinstance(node, list):
            stack.extend(reversed(node))
            continue
        if not isinstance(node, dict):
            continue
        action = node.get("action")
        options = [node]
        if isinstance(action, dict):
            options.append(action)
        for obj in options:
            to_addr = address_of(obj.get("to"))
            raw = raw_input_of(obj)
            if to_addr == target and raw.startswith(SELECTOR):
                try:
                    decoded = parse_swap(raw)
                except (ValueError, OverflowError) as exc:
                    decoded = {"decode_error": str(exc)}
                yield {
                    "parsed_swap": decoded,
                    "call_from": address_of(obj.get("from")),
                    "call_to": to_addr,
                    "trace_error": node.get("error"),
                }
        for key, val in node.items():
            if key == "action":
                continue
            if isinstance(val, (dict, list)):
                stack.append(val)


def get_trace_swaps(tx_hash, target):
    url = BASE + "/transactions/" + tx_hash + "/raw-trace"
    return list(_walk_trace(request_json(url), target))

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
    calls_to_controller = 0
    raw_trace_scans = 0
    raw_trace_errors = 0
    matches = []
    error = None
    exhausted = False
    seen_cursors = set()
    looked_up_hashes = set()
    TRACE_LIMIT = 20  # Protect public indexer against excessive requests.
    for _ in range(PAGE_LIMIT):
        cursor_key = json.dumps(cursor, sort_keys=True)
        if cursor_key in seen_cursors:
            error = "Repeated pagination cursor"
            break
        seen_cursors.add(cursor_key)

        try:
            data = get_page(controller, endpoint, cursor)
            items = data.get("items", [])
            if not isinstance(items, list):
                raise RuntimeError("Invalid items in response")
        except Exception as exc:
            error = str(exc)[:240]
            print("REQUEST INCONCLUSIVE:", error, flush=True)
            break

        page_count += 1
        scanned += len(items)
        page_calls = 0
        for tx in items:
            if address_of(tx.get("to")) != controller:
                continue
            page_calls += 1
            calls_to_controller += 1
            raw = raw_input_of(tx)
            method = str(tx.get("method") or "").lower()
            decoded = tx.get("decoded_input")
            decoded_method = (
                str(decoded.get("method_call") or "").lower()
                if isinstance(decoded, dict) else ""
            )

            tx_hash = tx.get("hash") or tx.get("transaction_hash")
            parsed = parse_swap(raw) if raw.startswith(SELECTOR) else None
            if parsed is not None or "swapuniswapv4" in (method + decoded_method):
                entry = {
                    "version": label, "source": endpoint,
                    "transaction_hash": tx_hash, "block_number": tx.get("block_number"),
                    "timestamp": tx.get("timestamp"), "method": method,
                    "parsed_swap": parsed,
                    "status": tx.get("status"), "verification": "indexed_summary",
                }
                matches.append(entry)
                print("POSSIBLE SWAP BY SUMMARY:", json.dumps(entry), flush=True)

            # For internal calls, the account's internal-transactions endpoint
            # usually does NOT include calldata. Decode the parent transaction
            # via Blockscout's raw-trace endpoint when available.
            if endpoint != "internal-transactions" or not tx_hash:
                continue
            if tx_hash in looked_up_hashes or raw_trace_scans >= TRACE_LIMIT:
                continue
            looked_up_hashes.add(tx_hash)
            raw_trace_scans += 1
            try:
                for found in get_trace_swaps(tx_hash, controller):
                    entry = {
                        "version": label, "source": "raw-trace",
                        "transaction_hash": tx_hash,
                        "block_number": tx.get("block_number"),
                        "timestamp": tx.get("timestamp"),
                        "parsed_swap": found["parsed_swap"],
                        "trace_error": found.get("trace_error"),
                        "verification": "decoded_internal_calldata",
                        "explorer_url": "https://eth.blockscout.com/tx/" + tx_hash
                    }
                    matches.append(entry)
                    print("DECODED REAL INTERNAL CALL:", json.dumps(entry), flush=True)
            except Exception as exc:
                raw_trace_errors += 1
                if raw_trace_errors <= 3:
                    print("RAW TRACE INCONCLUSIVE:", tx_hash[:14], str(exc)[:150], flush=True)
            time.sleep(0.2)

        print(
            "Page", page_count, "records", len(items),
            "calls_TO_controller", page_calls,
            "raw_traces_checked", raw_trace_scans, flush=True
        )

        next_params = data.get("next_page_params")
        if not isinstance(next_params, dict) or not next_params:
            exhausted = True
            break
        cursor = clean_cursor(next_params)
        print("NEXT CURSOR", json.dumps(cursor, sort_keys=True), flush=True)
        if not cursor:
            error = "Empty cursor after sanitization"
            break
        time.sleep(0.4)

    if page_count == PAGE_LIMIT and not exhausted and error is None:
        error = "Page limit reached; history incomplete"
    return {
        "controller": controller, "endpoint": endpoint,
        "pages": page_count, "records_scanned": scanned,
        "calls_to_controller": calls_to_controller,
        "raw_trace_requests": raw_trace_scans, "raw_trace_errors": raw_trace_errors,
        "is_exhaustive": exhausted, "error": error, "matches": matches
    }

print("=== PASSO 363: TRACE-AWARE SPARK SWAP HISTORY ===", flush=True)
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
                (item.get("transaction_hash"), label, item.get("source"), json.dumps(item.get("parsed_swap"),sort_keys=True))
            ] = item

result["unique_transactions"] = list(dedup.values())
print("\n=== SUMMARY ===", flush=True)
for run in result["runs"]:
    print(
        run["endpoint"], run["controller"][:14],
        "pages", run["pages"],
        "records", run["records_scanned"],
        "matches", len(run["matches"]),
        "calls_to_controller", run["calls_to_controller"],
        "traces_checked", run["raw_trace_requests"],
        "complete", run["is_exhaustive"],
        "error", run["error"],
        flush=True
    )
print("Potential matching calls", len(result["unique_transactions"]), flush=True)
print("CAUTION: internal-trace availability and pagination may be incomplete.", flush=True)
print("Not finding a call does NOT prove no swaps: pagination and internal indexes can be partial.", flush=True)

with open("audit-output/pass363_swap_history.json", "w") as file:
    json.dump(result, file, ensure_ascii=False, indent=2)

print("Saved audit-output/pass363_swap_history.json", flush=True)
print("NO ARCHIVE RPC. NO LIVE TRANSACTIONS. NO KEYS REQUIRED.", flush=True)
