#!/usr/bin/env python3
"""
PASSO 378 - Read-only live OTC accounting and buffer authority inventory.

Ground all values in eth_call or eth_getBlockByNumber 'latest'; report if a
read fails. No tx sending, no EVM forking, no token minting, no assumptions
about historical recoveries or attacker permissions.
"""
import json
import os
import subprocess
import urllib.request
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 65
RPC = os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
CONTROLLER = "0xc953972cd006d1f12686fd7185c6d443b15900cd"
LIMITS = "0x7a5fd5cf045e010e62147f065ceae59e5344b188"
EXCHANGE = "0xd010b876696f345d9e0a1b70f573244fcc2e0a0e"
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
TOKENS = {
    "USDT": "0xdac17f958d2ee523a2206206994597c13d831ec7",
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
}
ZERO_ROLE = "0x" + "0"*64
UNIT = Decimal(10)**18

def run_cast(*args):
    try:
        p = subprocess.run(
            ["cast", *args, "--rpc-url", RPC] if args[0] != "abi-encode"
            and args[0] != "keccak" else ["cast", *args],
            capture_output=True, text=True, timeout=40
        )
        if p.returncode:
            return None, p.stderr.strip()[:400] or ("cast exit " + str(p.returncode))
        return p.stdout.strip(), None
    except Exception as ex:
        return None, str(ex)[:400]

def call(contract, signature, *args):
    result, err = run_cast("call", contract, signature, *args)
    return {"raw": result, "error": err}

def parts(item):
    if item.get("error") or not item.get("raw"):
        return []
    return [x.split(" [")[0].strip() for x in item["raw"].splitlines() if x.strip()]

def integer(s):
    if s is None:
        return None
    try:
        return int(str(s), 0)
    except ValueError:
        return None

def uint(item):
    p = parts(item)
    return integer(p[0]) if p else None

def boolean(item):
    p = parts(item)
    if not p:
        return None
    return True if p[0].lower() == "true" else False if p[0].lower() == "false" else None

def qty(v, decimals=18):
    if v is None:
        return None
    return str(Decimal(v) / (Decimal(10)**decimals))

def net_info(token, buffer):
    balances = {}
    for location, owner in [("Spark proxy", PROXY), ("OTC buffer", buffer), ("OTC exchange", EXCHANGE)]:
        balances[location] = uint(call(token, "balanceOf(address)(uint256)", owner))
    allowance = uint(call(token, "allowance(address,address)(uint256)", buffer, PROXY))
    whitelisted = boolean(call(CONTROLLER, "otcWhitelistedAssets(address,address)(bool)", EXCHANGE, token))
    return {
        "symbol": next((k for k,v in TOKENS.items() if v == token), "?"),
        "balances_native": balances,
        "allowance_buffer_to_almproxy_native": allowance,
        "whitelisted": whitelisted,
        "display_decimals": 6,
        "balances_display": {k: qty(v,6) for k,v in balances.items()},
        "allowance_display": qty(allowance,6)
    }

def rpc_latest_block():
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 378,
        "method": "eth_getBlockByNumber", "params": ["latest", False]
    }).encode()
    req = urllib.request.Request(RPC, data=payload, headers={
        "Content-Type": "application/json", "User-Agent": "SparkReadOnly378"
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            response = json.load(res)
        if response.get("error") or not response.get("result"):
            return {"error": str(response.get("error") or "empty response")}
        block = response["result"]
        return {
            "block_number": int(block["number"], 16),
            "timestamp": int(block["timestamp"], 16),
            "hash": block["hash"]
        }
    except Exception as ex:
        return {"error": str(ex)[:300]}

print("=== PASSO 378: ON-CHAIN OTC ACCOUNTING (READ ONLY) ===", flush=True)
block = rpc_latest_block()
print("Latest block before RPC calls:", block, flush=True)

otc_call = call(CONTROLLER, "otcs(address)(address,uint256,uint256,uint256,uint256)", EXCHANGE)
lines = parts(otc_call)
keys = ["buffer", "rechargeRate18", "sent18", "sentTimestamp", "claimed18"]
otc = dict(zip(keys, lines)) if len(lines) == 5 else {"error": otc_call["error"] or "Invalid tuple response"}
if "error" in otc:
    print("OTC STATE UNAVAILABLE:", otc["error"], flush=True)
else:
    print("Exchange:", EXCHANGE, flush=True)
    print("Buffer:", otc["buffer"], flush=True)
    for k in keys[1:]:
        print(k + ":", otc[k], flush=True)

slippage = uint(call(CONTROLLER, "maxSlippages(address)(uint256)", EXCHANGE))
available_ready = boolean(call(CONTROLLER, "isOtcSwapReady(address)(bool)", EXCHANGE))
claimed_with_recharge = uint(call(CONTROLLER, "getOtcClaimWithRecharge(address)(uint256)", EXCHANGE))
limit_root = parts(call(CONTROLLER, "LIMIT_OTC_SWAP()(bytes32)"))
root = limit_root[0] if limit_root else None
key = None
if root:
    abi, err = run_cast("abi-encode", "f(bytes32,address)", root, EXCHANGE)
    if not err:
        key, err = run_cast("keccak", abi)

rl = call(LIMITS, "getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)", key) if key else {"error": "Unable to construct OTC limit key"}
rl_parts = parts(rl)
limit = {}
if len(rl_parts) == 4:
    for k, v in zip(["maxAmount18", "slope18PerSecond", "lastAmount18", "lastUpdated"], rl_parts):
        limit[k] = integer(v)
else:
    limit["error"] = rl.get("error") or "Invalid limit tuple response"

limit_available = uint(call(LIMITS, "getCurrentRateLimit(bytes32)(uint256)", key)) if key else None
buffer = otc.get("buffer")
buffer_valid = bool(buffer and buffer.startswith("0x") and len(buffer) == 42
                    and int(buffer,16) != 0)

print("Max slippage ratio:", qty(slippage), flush=True)
print("Contract isOtcSwapReady:", available_ready, flush=True)
print("getOtcClaimWithRecharge (18 decimals):", claimed_with_recharge, flush=True)
print("RateLimit key:", key, flush=True)
print("OTC max (normalized units):", qty(limit.get("maxAmount18")), flush=True)
print("OTC current available (normalized units):", qty(limit_available), flush=True)
print("OTC refilling per day (normalized units):",
      qty(limit.get("slope18PerSecond") * 86400 if limit.get("slope18PerSecond") is not None else None),
      flush=True)

model = {"configuration": "partial if any read errors"}
if len(lines) == 5 and slippage is not None and claimed_with_recharge is not None:
    sent = integer(otc["sent18"])
    sent_at = integer(otc["sentTimestamp"])
    claimed = integer(otc["claimed18"])
    recharge = integer(otc["rechargeRate18"])
    required = sent * slippage // (10**18) if sent is not None else None
    model = {
        "last_sent_normalized": qty(sent),
        "last_claimed_normalized": qty(claimed),
        "recharge_rate_normalized_per_second": qty(recharge),
        "recharge_rate_normalized_per_day": qty(recharge * 86400 if recharge is not None else None),
        "required_for_next_send_normalized": qty(required),
        "actual_claimed_plus_recharge_normalized": qty(claimed_with_recharge),
        "remaining_to_readiness_normalized": qty(max(0, required - claimed_with_recharge)) if required is not None else None,
        "locally_computed_ready": claimed_with_recharge >= required if required is not None else None,
        "contract_ready": available_ready,
        "seconds_since_send_approx": (
            max(0, block["timestamp"] - sent_at)
            if sent_at and "timestamp" in block else None
        ),
        "note": "Recharge is part of the documented controller logic, not proof of recovery of assets."
    }
    for k,v in model.items():
        print(k + ":", v, flush=True)

tokens = {}
if buffer_valid:
    for name, addr in TOKENS.items():
        tokens[name] = net_info(addr, buffer)
        print(name + " whitelisted:", tokens[name]["whitelisted"], flush=True)
        print(name + " balances:", tokens[name]["balances_display"], flush=True)
        print(name + " buffer->proxy allowance:", tokens[name]["allowance_display"], flush=True)

authority = {}
if buffer_valid:
    authority["almProxy"] = parts(call(buffer, "almProxy()(address)"))
    count = uint(call(buffer, "getRoleMemberCount(bytes32)(uint256)", ZERO_ROLE))
    authority["default_admin_count"] = count
    authority["default_admins"] = []
    if count is not None and 0 <= count <= 12:
        for i in range(count):
            authority["default_admins"].append(parts(call(
                buffer, "getRoleMember(bytes32,uint256)(address)", ZERO_ROLE, str(i)
            )))
    authority["proxy_is_admin"] = boolean(call(
        buffer, "hasRole(bytes32,address)(bool)", ZERO_ROLE, PROXY
    ))
    print("Buffer ALMProxy getter:", authority["almProxy"], flush=True)
    print("Buffer admin count:", count, flush=True)
    print("Buffer admins:", authority["default_admins"], flush=True)
    print("Buffer role: Spark Proxy is admin:", authority["proxy_is_admin"], flush=True)

report = {
    "title": "Live OTC state/accounting inventory",
    "exchange": EXCHANGE,
    "head_block_before_calls": block,
    "otc": otc,
    "maxSlippageRaw": slippage,
    "contractReady": available_ready,
    "getOtcClaimWithRecharge18": claimed_with_recharge,
    "rateLimitKey": key,
    "rateLimit": limit,
    "rateLimitAvailable18": limit_available,
    "model": model,
    "tokens": tokens,
    "bufferAuthority": authority,
    "limitations": [
        "Read calls are latest, not pinned to one block; amounts can change during queries.",
        "USDT/USDC are shown at six decimals; normalized accounting is 18 decimals.",
        "OTC exchange balances are not a measure of Spark deposits or liabilities.",
        "Time-based recharge is intentionally part of code and does not prove received assets.",
        "No exploit, transaction, mempool data, signing or state change performed."
    ]
}
Path("audit-output").mkdir(exist_ok=True)
out = "audit-output/pass378_otc_accounting_live.json"
with open(out,"w") as f:
    json.dump(report, f, indent=2, ensure_ascii=False)
print("\nReport:", out, flush=True)
print("READ-ONLY. NO TRANSACTIONS SENT.", flush=True)
