#!/usr/bin/env python3
"""PASSO 377: Corrected LIVE OTC-only inventory.
Read-only. No eth_getLogs, no historical state/fork requirement, no signing.

Event discovery ONLY from OTC-specific events (never MaxSlippageSet).
Always include the exchange verified in the prior production read (pass330).
Live readiness is not taken as proof of route authorization.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

RPC = os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
API = "https://eth.blockscout.com/api/v2"
CONTROLLER = "0xc953972cd006d1f12686fd7185c6d443b15900cd"
RATE_LIMITS = "0x7a5fd5cf045e010e62147f065ceae59e5344b188"
KNOWN_BINANCE_OTC = "0xd010b876696f345d9e0a1b70f573244fcc2e0a0e"

TOKENS = {
    "USDT": "0xdac17f958d2ee523a2206206994597c13d831ec7",
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    "USDS": "0xdc035d45d973e3ec169d2276ddab16f1e407384f",
    "RLUSD": "0x8292bb45bf1ee4d140127049757c2e0ff06317ed",
}
EVENTS = {
    "OTCBufferSet": "OTCBufferSet(address,address,address)",
    "OTCWhitelistedAssetSet": "OTCWhitelistedAssetSet(address,address,bool)",
    "OTCRechargeRateSet": "OTCRechargeRateSet(address,uint256,uint256)",
    "OTCSwapSent": "OTCSwapSent(address,address,address,uint256,uint256)",
    "OTCClaimed": "OTCClaimed(address,address,address,uint256,uint256)",
}
MAX_PAGES = int(os.getenv("OTC_EVENT_MAX_PAGES", "3"))
MAX_ASSETS = int(os.getenv("OTC_ASSETS_MAX", "12"))

def run_cast(*args):
    cmd = ["cast", *args]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=38)
    except Exception as exc:
        return None, str(exc)[:230]
    if p.returncode:
        return None, (p.stderr or p.stdout).strip()[:300]
    return p.stdout.strip(), None

def call(address, signature, *args):
    value, err = run_cast("call", address, signature, *args, "--rpc-url", RPC)
    return {"value": value, "error": err}

def first_line(result):
    if result["error"] or not result["value"]:
        return None
    return result["value"].splitlines()[0].split(" [")[0].strip()

def bool_value(result):
    text = first_line(result)
    if text is None:
        return None
    return True if text.lower() == "true" else False if text.lower() == "false" else None

def uint_value(result):
    text = first_line(result)
    try:
        return int(text, 0) if text else None
    except ValueError:
        return None

def fetch_json(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/json", "User-Agent": "SparkAuditReadOnly377"
    })
    with urllib.request.urlopen(req, timeout=23) as res:
        return json.load(res)

def event_topic(signature):
    value, err = run_cast("keccak", signature)
    if err or not value or len(value) != 66:
        raise RuntimeError("Topic calculation error: " + str(err or value))
    return value.lower()

def decode_addr(topic):
    s = str(topic or "").lower()
    if not s.startswith("0x") or len(s) != 66:
        return None
    return "0x" + s[-40:]

def scan_event(name, topic):
    events, cursor, seen = [], {}, set()
    complete, error, pages = False, None, 0
    for _ in range(MAX_PAGES):
        marker = json.dumps(cursor, sort_keys=True)
        if marker in seen:
            error = "Repeated pagination cursor"
            break
        seen.add(marker)
        params = {"topic": topic}
        params.update({k: v for k, v in cursor.items()
                       if v is not None and not isinstance(v, bool)
                       and k != "include_zero_value"})
        url = API + "/addresses/" + CONTROLLER + "/logs?" + urllib.parse.urlencode(params)
        try:
            payload = fetch_json(url)
            pages += 1
            rows = payload.get("items") or []
            for row in rows:
                topics = row.get("topics") or []
                if not topics or str(topics[0]).lower() != topic:
                    continue
                exchange = decode_addr(topics[1]) if len(topics) > 1 else None
                asset_index = 2 if name == "OTCWhitelistedAssetSet" else (
                    3 if name in ("OTCSwapSent", "OTCClaimed") else None
                )
                asset = decode_addr(topics[asset_index]) if asset_index is not None and len(topics) > asset_index else None
                events.append({
                    "event": name, "exchange": exchange, "asset": asset,
                    "tx_hash": row.get("transaction_hash"),
                    "block_number": row.get("block_number"),
                    "log_index": row.get("index"),
                })
            nxt = payload.get("next_page_params")
            if not nxt:
                complete = True
                break
            cursor = {k: v for k, v in nxt.items()
                      if v is not None and not isinstance(v, bool)
                      and k != "include_zero_value"}
            if not cursor:
                error = "Empty cursor"
                break
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError) as ex:
            error = str(ex)[:250]
            break
        time.sleep(0.12)
    if not complete and not error:
        error = "Page cap reached"
    return {"pages": pages, "complete": complete, "error": error, "events": events}

def key_for_exchange(root, exchange):
    encoded, err = run_cast("abi-encode", "f(bytes32,address)", root, exchange)
    if err:
        return None, err
    return run_cast("keccak", encoded)

def collect_live(exchange, assets, root_key):
    state = call(CONTROLLER, "otcs(address)(address,uint256,uint256,uint256,uint256)", exchange)
    values = state["value"].splitlines() if state["value"] and not state["error"] else []
    keys = ["buffer", "rechargeRate18", "sent18", "sentTimestamp", "claimed18"]
    otc = {name: (values[i].split(" [")[0] if i < len(values) else None)
           for i, name in enumerate(keys)}
    if state["error"]:
        otc["read_error"] = state["error"]
    slippage = uint_value(call(CONTROLLER, "maxSlippages(address)(uint256)", exchange))
    ready = bool_value(call(CONTROLLER, "isOtcSwapReady(address)(bool)", exchange))
    by_token = {}
    for symbol, token in TOKENS.items():
        by_token[symbol] = bool_value(call(
            CONTROLLER, "otcWhitelistedAssets(address,address)(bool)", exchange, token))
    for token in sorted(assets):
        if token in TOKENS.values():
            continue
        if len(by_token) >= MAX_ASSETS:
            break
        by_token[token] = bool_value(call(
            CONTROLLER, "otcWhitelistedAssets(address,address)(bool)", exchange, token))

    key, keyerr = key_for_exchange(root_key, exchange) if root_key else (None, "root key unavailable")
    limit = {}
    if key:
        limit["key"] = key
        limit["data"] = call(RATE_LIMITS,
             "getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)", key)
        limit["available"] = call(RATE_LIMITS,
             "getCurrentRateLimit(bytes32)(uint256)", key)
        raw = limit["data"]["value"]
        if raw and not limit["data"]["error"]:
            parts = [line.split(" [")[0] for line in raw.splitlines()]
            if len(parts) >= 4:
                try:
                    limit["maxAmount18"] = int(parts[0])
                    limit["slope18PerSecond"] = int(parts[1])
                except ValueError:
                    pass
    else:
        limit["read_error"] = keyerr

    buffer = otc["buffer"]
    nonzero_buffer = bool(buffer and buffer.lower() != "0x" + "0"*40)
    whitelisted = [a for a, flag in by_token.items() if flag is True]
    max_amount = limit.get("maxAmount18")
    operational = (nonzero_buffer and len(whitelisted) > 0
                   and isinstance(max_amount, int) and max_amount > 0
                   and slippage is not None and slippage > 0)
    return {
        "exchange": exchange,
        "otc": otc,
        "maxSlippage": slippage,
        "isOtcSwapReady": ready,
        "whitelist": by_token,
        "rateLimit": limit,
        "operational_checks_pass": operational,
        "important": "Readiness alone is NOT route authorization. Operational checks are necessary, not proof of exploitability."
    }

print("=== PASSO 377: CORRECTED LIVE OTC-ONLY DISCOVERY ===", flush=True)
print("Current controller only; historical retired controller deliberately excluded", flush=True)
print("Historical known OTC exchange always checked:", KNOWN_BINANCE_OTC, flush=True)
print("No MaxSlippageSet sources are treated as OTC exchange registrations.", flush=True)
print("No wallet, live tx, storage changes, or eth_getLogs calls.", flush=True)

root = first_line(call(CONTROLLER, "LIMIT_OTC_SWAP()(bytes32)"))
print("OTC limit root:", root, flush=True)
events = {}
exchange_assets = {}
candidates = {KNOWN_BINANCE_OTC}
for name, sig in EVENTS.items():
    result = scan_event(name, event_topic(sig))
    events[name] = result
    print(name, "matched", len(result["events"]),
          "complete", result["complete"],
          "error", result["error"], flush=True)
    for ev in result["events"]:
        address = ev["exchange"]
        if address and address != "0x" + "0"*40:
            candidates.add(address)
            if ev.get("asset"):
                exchange_assets.setdefault(address, set()).add(ev["asset"])
    time.sleep(0.15)

print("OTC-only unique candidate exchanges:", len(candidates), flush=True)
config = []
for exchange in sorted(candidates):
    print("\nEXCHANGE:", exchange, flush=True)
    row = collect_live(exchange, exchange_assets.get(exchange, set()), root)
    config.append(row)
    print("  buffer:", row["otc"]["buffer"], flush=True)
    print("  whitelist:", row["whitelist"], flush=True)
    print("  maxSlippage:", row["maxSlippage"], flush=True)
    print("  isOtcSwapReady:", row["isOtcSwapReady"], flush=True)
    print("  OTC rate limit max (18 decimals):",
          row["rateLimit"].get("maxAmount18"), flush=True)
    print("  operational checks pass:", row["operational_checks_pass"], flush=True)

result_path = "audit-output/pass377_otc_verified_configuration.json"
Path("audit-output").mkdir(exist_ok=True)
with open(result_path, "w") as f:
    json.dump({
        "controller": CONTROLLER,
        "known_exchange": KNOWN_BINANCE_OTC,
        "source_events": events,
        "live_configuration": config,
        "notes": [
          "Only OTC-specific event types used to discover exchange addresses.",
          "All values are live read calls and may span more than one block.",
          "Historical event scanning may be partial. Known exchange is included independently.",
          "A positive operational readiness indicator is not a proof of vulnerability.",
          "No production writes, token transfers or transactions sent."
        ]
    }, f, indent=2, ensure_ascii=False)
print("\nSaved:", result_path, flush=True)
print("NO TRANSACTIONS SENT.", flush=True)
