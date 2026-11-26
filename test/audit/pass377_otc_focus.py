#!/usr/bin/env python3
"""
PASSO 377 - Summarize the completed pass376 report, prioritizing REAL OTC
exchange addresses found in OTCBufferSet / OTCWhitelistedAssetSet / OTCRechargeRateSet.
Fetch fresh read-only contract getters only for those addresses (no wide re-scan).
No transactions or state mutations.
"""
import json
import os
import subprocess
from pathlib import Path

REPORT = Path("audit-output/pass376_otc_inventory.json")
RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
CURRENT = "0xc953972Cd006d1f12686fd7185c6D443b15900Cd"
LIMITS = "0x7A5FD5cf045e010e62147F065cEAe59e5344b188"
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
USDS = "0xdc035d45d973e3ec169d2276ddab16f1e407384f"
USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
EVENTS = ("OTCBufferSet", "OTCWhitelistedAssetSet", "OTCRechargeRateSet")
OUTPUT = Path("audit-output/pass377_otc_focused.json")

def run_cast(*args):
    try:
        result = subprocess.run(
            ["cast", *args], capture_output=True, text=True, timeout=35,
            check=False,
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip()[:250]}
        return {"value": result.stdout.strip()}
    except Exception as ex:
        return {"error": str(ex)[:220]}

def call(address, signature, *args):
    return run_cast("call", address, signature, *args, "--rpc-url", RPC)

def rate_limit_for(exchange):
    base = run_cast("keccak", "LIMIT_OTC_SWAP")
    if "value" not in base:
        return {"error":"Could not hash LIMIT_OTC_SWAP", "details":base}
    encoded=run_cast("abi-encode", "f(bytes32,address)", base["value"], exchange)
    if "value" not in encoded:
        return {"error":"Could not ABI encode exchange key", "details":encoded}
    key=run_cast("keccak", encoded["value"])
    if "value" not in key:
        return {"error":"Could not hash encoded rate limit key", "details":key}
    return {
        "key":key["value"],
        "data":call(LIMITS, "getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)", key["value"]),
        "available":call(LIMITS, "getCurrentRateLimit(bytes32)(uint256)", key["value"]),
    }

print("=== PASSO 377: REAL OTC EXCHANGE CONFIGURATION ===", flush=True)
if not REPORT.is_file():
    print("Passo 376 JSON report not found. Cannot infer exchanges from truncated log.",flush=True)
    print("Expected file:",REPORT,flush=True)
    print("Check the end of audit-output/pass376_otc_inventory.log for errors.",flush=True)
else:
    with REPORT.open() as f:
        doc=json.load(f)
    scans=doc.get("event_scans",{})
    found={}
    seen=set()
    for name in EVENTS:
        key="CURRENT:"+name
        scan=scans.get(key,{})
        print(key,"count",len(scan.get("events",[])),
              "complete",scan.get("complete"),
              "error",scan.get("error"),flush=True)
        for event in scan.get("events",[]):
            indexed=event.get("indexed_addresses") or []
            if not indexed:
                continue
            exchange=indexed[0].lower()
            if exchange == "0x"+"0"*40:
                continue
            found.setdefault(exchange,{}).setdefault(name,[]).append(event)
            if name=="OTCWhitelistedAssetSet" and len(indexed)>1:
                print("  Asset in whitelist event:",indexed[1],flush=True)
    print("Distinct OTC exchange candidates from dedicated events:",len(found),flush=True)
    results=[]
    for exchange,evidence in sorted(found.items()):
        print("\nOTC exchange:",exchange,flush=True)
        print("Event types:",", ".join(sorted(evidence)),flush=True)
        info={
            "exchange":exchange,
            "event_evidence":evidence,
            "otc_state":call(CURRENT,"otcs(address)(address,uint256,uint256,uint256,uint256)",exchange),
            "maximum_slippage":call(CURRENT,"maxSlippages(address)(uint256)",exchange),
            "ready":call(CURRENT,"isOtcSwapReady(address)(bool)",exchange),
            "assets":{
                "USDT":call(CURRENT,"otcWhitelistedAssets(address,address)(bool)",exchange,USDT),
                "USDS":call(CURRENT,"otcWhitelistedAssets(address,address)(bool)",exchange,USDS),
                "USDC":call(CURRENT,"otcWhitelistedAssets(address,address)(bool)",exchange,USDC),
            },
            "rate_limit":rate_limit_for(exchange),
        }
        results.append(info)
        print("Current state and rate limit:",json.dumps({
            k:v for k,v in info.items() if k!="event_evidence"
        },ensure_ascii=False),flush=True)
    OUT={
        "source_file":str(REPORT),
        "dedicated_OTC_event_scan_complete":all(scans.get("CURRENT:"+x,{}).get("complete") for x in EVENTS),
        "actual_otc_exchange_candidates":results,
        "notes":[
            "An OTC configuration event proves a historical configured exchange, not active exposure.",
            "Current calls are read-only and no live token moves were made.",
            "Some events might have been superseded or allowances revoked.",
        ]
    }
    OUTPUT.parent.mkdir(parents=True,exist_ok=True)
    with OUTPUT.open("w") as f:
        json.dump(OUT,f,ensure_ascii=False,indent=2)
    print("\nSaved:",OUTPUT,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
