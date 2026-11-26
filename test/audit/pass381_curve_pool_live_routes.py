#!/usr/bin/env python3
"""
PASSO 381: Curve pool inventory from the ACTUAL cached 25 MaxSlippageSet
events collected in PASSO 376. Identifies pools with a verified Curve interface,
their coins (including RLUSD/PYUSD), actual slippage configuration, and
live rate-limit ceilings for swapping/deposit/withdraw.

No guessing pool addresses, no new Blockscout scans, no wallet/signing,
and no state-changing transactions. RPC 'eth_call' only.
Limits may differ across block reads; do not infer route safety from missing logs.
"""
import json
import os
import subprocess
from collections import Counter
from pathlib import Path
from decimal import Decimal

RPC=os.getenv("MAINNET_RPC_URL","https://ethereum-rpc.publicnode.com")
INPUT=Path("audit-output/pass376_otc_inventory.json")
OUTPUT=Path("audit-output/pass381_curve_pool_live_routes.json")
CONTROLLER="0xc953972cd006d1f12686fd7185c6d443b15900cd"
LIMITS="0x7a5fd5cf045e010e62147f065ceae59e5344b188"
TOKEN_NAMES={
    "0x8292bb45bf1ee4d140127049757c2e0ff06317ed":"RLUSD",
    "0x6c3ea9036406852006290770bedfcaba0e23a0e8":"PYUSD",
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48":"USDC",
    "0xdac17f958d2ee523a2206206994597c13d831ec7":"USDT",
    "0xdc035d45d973e3ec169d2276ddab16f1e407384f":"USDS",
}
IMPORTANT={"RLUSD","PYUSD"}
ROOT_GETTERS={
    "CURVE_SWAP": "LIMIT_CURVE_SWAP()(bytes32)",
    "CURVE_DEPOSIT": "LIMIT_CURVE_DEPOSIT()(bytes32)",
    "CURVE_WITHDRAW": "LIMIT_CURVE_WITHDRAW()(bytes32)"
}
TIMEOUT=int(os.getenv("RPC_CALL_TIMEOUT_SECONDS","18"))
MAX_CANDIDATES=int(os.getenv("CURVE_CANDIDATE_CAP","50"))

def execute_cast(*args, rpc=True):
    cmd=["cast",*args]+(["--rpc-url",RPC] if rpc else [])
    try:
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=TIMEOUT)
        if p.returncode:
            return None,(p.stderr or p.stdout).strip()[:220] or f"cast exit {p.returncode}"
        return p.stdout.strip(),None
    except Exception as ex:
        return None,str(ex)[:220]

def call(contract,signature,*args):
    return execute_cast("call",contract,signature,*args)

def rows(raw):
    return [line.split(" [")[0].strip() for line in (raw or "").splitlines()
            if line.strip()]

def quantity(text):
    try:
        return int(str(text),0)
    except (ValueError,TypeError):
        return None

def read_uint(contract,signature,*args):
    raw,err=call(contract,signature,*args)
    values=rows(raw)
    return (quantity(values[0]) if values else None),err

def read_address(contract,signature,*args):
    raw,err=call(contract,signature,*args)
    values=rows(raw)
    if err or not values or not values[0].startswith("0x") or len(values[0])!=42:
        return None,err or "Invalid address returned"
    return values[0].lower(),None

def make_address_key(root,address):
    enc,err=execute_cast("abi-encode","key(bytes32,address)",root,address,rpc=False)
    if err:
        return None,err
    return execute_cast("keccak",enc,rpc=False)

def read_rate(key):
    raw,err=call(LIMITS,"getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)",key)
    if err:
        return {"error":err}
    parsed=[quantity(v) for v in rows(raw)]
    if len(parsed)!=4 or any(n is None for n in parsed):
        return {"error":"Unexpected RateLimitData tuple"}
    available,avail_err=read_uint(LIMITS,"getCurrentRateLimit(bytes32)(uint256)",key)
    return {
        "maxAmount_native":parsed[0],
        "slope_native_per_second":parsed[1],
        "lastAmount_native":parsed[2],
        "lastUpdated":parsed[3],
        "available_native":available,
        "error":avail_err
    }

print("=== PASSO 381: DISCOVER CONFIGURED CURVE POOLS FROM KNOWN EVENTS ===",flush=True)
if not INPUT.exists():
    raise SystemExit("Missing PASSO 376 cache: "+str(INPUT)+"; do not invent pool addresses.")
data=json.loads(INPUT.read_text())
record=data.get("event_scans",{}).get("CURRENT:MaxSlippageSet")
if not isinstance(record,dict):
    raise SystemExit("The PASSO 376 cache does not contain CURRENT:MaxSlippageSet events.")
events=record.get("events",[])
candidates=sorted({
    ev.get("indexed_addresses",[None])[0].lower()
    for ev in events
    if ev.get("indexed_addresses") and
    isinstance(ev["indexed_addresses"][0],str)
    and ev["indexed_addresses"][0].startswith("0x")
    and len(ev["indexed_addresses"][0])==42
})
if len(candidates)>MAX_CANDIDATES:
    print("Candidate cap:",MAX_CANDIDATES,"of",len(candidates),
          "- scan incomplete; no claims about omitted addresses.",flush=True)
    candidates=candidates[:MAX_CANDIDATES]
print("Cached current MaxSlippageSet events:",len(events),flush=True)
print("Unique candidate pools:",len(candidates),flush=True)
print("Cached event scan complete:",record.get("complete"),
      "scan error:",record.get("error"),flush=True)
print("No new Blockscout requests, only live eth_call checks.",flush=True)
roots={}
for label,getter in ROOT_GETTERS.items():
    raw,err=call(CONTROLLER,getter)
    values=rows(raw)
    roots[label]=values[0] if values and len(values[0])==66 else None
    print(label,"root:",roots[label],"error:",err,flush=True)

curve_pools=[]
unrecognized=[]
for i,pool in enumerate(candidates):
    n,error=read_uint(pool,"N_COINS()(uint256)")
    if error or n is None or n<2 or n>8:
        unrecognized.append({"address":pool,"N_COINS":n,"error":error})
        print(f"[{i+1}/{len(candidates)}] not recognized as Curve interface:",pool,flush=True)
        continue
    tokens=[]
    for j in range(n):
        token,coin_error=read_address(pool,"coins(uint256)(address)",str(j))
        tokens.append({"index":j,"token":token,"name":TOKEN_NAMES.get(token,"OTHER") if token else "READ_FAILED",
                       "read_error":coin_error})
    if any(x["token"] is None for x in tokens):
        unrecognized.append({"address":pool,"N_COINS":n,
                             "error":"N_COINS present but some coins(uint256) failed"})
        print(f"[{i+1}/{len(candidates)}] pool coin reads failed:",pool,flush=True)
        continue
    slippage,slippage_error=read_uint(CONTROLLER,"maxSlippages(address)(uint256)",pool)
    rate_limits={}
    for label,root in roots.items():
        if root is None:
            rate_limits[label]={"error":"Rate limit root unavailable"}
            continue
        key,ke=make_address_key(root,pool)
        if ke:
            rate_limits[label]={"error":ke}
        else:
            rate_limits[label]={"key":key,"data":read_rate(key)}
    matched=sorted(set(x["name"] for x in tokens)&IMPORTANT)
    entry={"pool":pool,"N_COINS":n,"coins":tokens,
           "maxSlippage_1e18":slippage,"maxSlippage_read_error":slippage_error,
           "rate_limits":rate_limits,"high_balance_token_matches":matched}
    curve_pools.append(entry)
    print(f"[{i+1}/{len(candidates)}] CURVE:",pool,flush=True)
    print("  tokens:",", ".join(x["name"]+"="+x["token"] for x in tokens),flush=True)
    print("  max slippage:",slippage,flush=True)
    for label,info in rate_limits.items():
        d=info.get("data",{})
        val=d.get("maxAmount_native")
        print(" ",label,"max native:",val,"error:",d.get("error",info.get("error")),flush=True)
    if matched:
        print("  *** HIGH-BALANCE ASSET ROUTE CANDIDATE:",", ".join(matched),flush=True)

report={
    "purpose":"Identify live configured Curve pools and rate limits without guessing destinations",
    "input":str(INPUT),"source_scan_complete":record.get("complete"),
    "source_scan_error":record.get("error"),
    "candidates_checked":len(candidates),"candidate_pools":candidates,
    "rate_limit_roots":roots,"curve_pools":curve_pools,
    "unrecognized_addresses":unrecognized,
    "limitations":[
        "This inventory covers only current-controller MaxSlippageSet events in the PASSO 376 cache.",
        "A recognized N_COINS/coins interface does not establish contract correctness or safety.",
        "Some configured pools might not emit MaxSlippageSet in the scanned window.",
        "Rate limit units depend on pool tokens; no monetary conversion is assumed.",
        "MaxSlippageSet may include addresses derived from Uniswap V4 pool IDs; they are not Curve contracts.",
        "No contract writes, tokens transferred, or mainnet transactions broadcast."
    ]
}
OUTPUT.parent.mkdir(exist_ok=True)
OUTPUT.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print("\n=== SUMMARY ===",flush=True)
print("Candidates probed:",len(candidates),flush=True)
print("Recognized Curve interfaces:",len(curve_pools),flush=True)
print("RLUSD/PYUSD-containing Curve interfaces:",
      sum(bool(p["high_balance_token_matches"]) for p in curve_pools),flush=True)
print("Unrecognized candidates:",len(unrecognized),flush=True)
print("Report:",OUTPUT,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
