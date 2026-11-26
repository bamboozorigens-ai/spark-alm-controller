#!/usr/bin/env python3
"""
PASSO 382 - Read-only live Curve RLUSD/USDC quote and authorization preflight.

Data: live MainnetController, RateLimits and pool. No swap or token transfer,
no fork state mutation, no signing, no broadcasting.
Does not purport to predict exact future execution or establish a MEV exploit.
"""
import json
import os
import re
import subprocess
import urllib.request
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec=65
RPC=os.getenv("MAINNET_RPC_URL","https://ethereum-rpc.publicnode.com")
POOL="0xd001ae433f254283fece51d4acce8c53263aa186"
RLUSD="0x8292bb45bf1ee4d140127049757c2e0ff06317ed"
USDC="0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
CONTROLLER="0xc953972cd006d1f12686fd7185c6d443b15900cd"
PROXY="0x1601843c5e9bc251a3272907010afa41fa18347e"
LIMITS="0x7a5fd5cf045e010e62147f065ceae59e5344b188"
RELAYER="0x8a25a24ede9482c4fc0738f99611be58f1c839ab"
AMOUNTS=[1000,10000,100000,500000,1000000,2000000,5000000]

def cast(*args, onchain=True):
    cmd=["cast",*args] + (["--rpc-url",RPC] if onchain else [])
    try:
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=38)
        if p.returncode:
            return None,(p.stderr or p.stdout).strip()[:330] or ("cast exit "+str(p.returncode))
        return p.stdout.strip(),None
    except Exception as e:
        return None,str(e)[:330]

def clean_number(raw):
    if not raw:
        return None
    first=raw.splitlines()[0].strip().split(" [")[0].strip()
    try:
        return int(first,0)
    except ValueError:
        return None

def read_uint(target, signature, *args):
    raw,err=cast("call",target,signature,*args)
    return clean_number(raw),err

def read_address(target, signature,*args):
    raw,err=cast("call",target,signature,*args)
    if err:
        return None,err
    v=raw.strip().splitlines()[0].split(" [")[0].strip()
    if not re.fullmatch("0x[0-9a-fA-F]{40}",v):
        return None,"Invalid address: "+v[:120]
    return v.lower(),None

def jsonrpc(method,params):
    req=urllib.request.Request(RPC,data=json.dumps({
        "jsonrpc":"2.0","id":382,"method":method,"params":params
    }).encode(),headers={
        "Content-Type":"application/json","User-Agent":"SparkReadOnlyAudit382"
    })
    with urllib.request.urlopen(req,timeout=34) as res:
        result=json.load(res)
    if result.get("error"):
        raise RuntimeError(str(result["error"]))
    return result.get("result")

def dynamic_uint_array(contract,signature):
    """ABI-decoding dynamic uint256[] response; no external ABI library."""
    selector,err=cast("sig",signature,onchain=False)
    if err or not selector or len(selector)!=10:
        raise RuntimeError("Selector error: "+str(err or selector))
    payload=jsonrpc("eth_call",[{"to":contract,"data":selector},"latest"])
    if not isinstance(payload,str) or not payload.startswith("0x"):
        raise RuntimeError("Invalid JSON-RPC eth_call result")
    data=bytes.fromhex(payload[2:])
    if len(data)<64 or len(data)%32:
        raise RuntimeError("Malformed ABI array response length")
    offset=int.from_bytes(data[:32],"big")
    if offset+32>len(data) or offset%32:
        raise RuntimeError("Malformed ABI array offset")
    n=int.from_bytes(data[offset:offset+32],"big")
    if n>16 or offset+32+n*32>len(data):
        raise RuntimeError("Unexpected ABI array length")
    return [int.from_bytes(data[offset+32+i*32:offset+64+i*32],"big") for i in range(n)]

def make_pool_key(root,pool):
    encoded,err=cast("abi-encode","f(bytes32,address)",root,pool,onchain=False)
    if err:
        raise RuntimeError(err)
    key,err=cast("keccak",encoded,onchain=False)
    if err:
        raise RuntimeError(err)
    return key

def rate_data(key):
    raw,err=cast("call",LIMITS,
                 "getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)",key)
    if err:
        return {"error":err}
    parts=[clean_number(line) for line in raw.splitlines()]
    if len(parts)!=4 or any(p is None for p in parts):
        return {"error":"Invalid RateLimitData tuple"}
    available,av_err=read_uint(LIMITS,"getCurrentRateLimit(bytes32)(uint256)",key)
    return {
        "maxAmount18":parts[0],"slope18PerSecond":parts[1],
        "lastAmount18":parts[2],"lastUpdated":parts[3],
        "available18":available,"available_error":av_err
    }

def display(n,d):
    return str(Decimal(n)/(Decimal(10)**d)) if n is not None else None

print("=== PASSO 382: RLUSD/USDC CURVE SWAP PREFLIGHT (READ ONLY) ===",flush=True)
block=jsonrpc("eth_getBlockByNumber",["latest",False])
info={"number":int(block["number"],16),"timestamp":int(block["timestamp"],16)}
print("Snapshot block before subsequent calls:",info,flush=True)
n,err=read_uint(POOL,"N_COINS()(uint256)")
assert err is None and n==2,(err,n)
coins=[]
for i in range(2):
    addr,error=read_address(POOL,"coins(uint256)(address)",str(i))
    assert error is None,(i,error)
    coins.append(addr)
assert coins==[USDC,RLUSD],"Unexpected Curve pool coin order; abort"
print("Verified coin order: USDC index 0, RLUSD index 1",flush=True)

slip,err=read_uint(CONTROLLER,"maxSlippages(address)(uint256)",POOL)
assert err is None and slip is not None and 0<slip<=10**18,("Invalid slippage",err,slip)
root,err=cast("call",CONTROLLER,"LIMIT_CURVE_SWAP()(bytes32)")
assert err is None and root is not None and len(root.strip())==66,(err,root)
key=make_pool_key(root.strip(),POOL)
limit=rate_data(key)
assert "error" not in limit,limit

rates=dynamic_uint_array(POOL,"stored_rates()")
assert len(rates)==2 and all(r>0 for r in rates),("Invalid stored rates",rates)
relayerRole,err=cast("call",CONTROLLER,"RELAYER()(bytes32)")
assert err is None and relayerRole,err
hasRelayer,roleerr=cast("call",CONTROLLER,"hasRole(bytes32,address)(bool)",relayerRole.strip(),RELAYER)
assert roleerr is None,roleerr
isRelayer=(hasRelayer or "").strip().lower()=="true"

asset_balances={}
for name,address,decimals in [("RLUSD",RLUSD,18),("USDC",USDC,6)]:
    asset_balances[name]={}
    for label,account in [("ALMProxy",PROXY),("CurvePool",POOL)]:
        val,e=read_uint(address,"balanceOf(address)(uint256)",account)
        asset_balances[name][label]={"native":val,"display":display(val,decimals),"error":e}
    allowance,e=read_uint(address,"allowance(address,address)(uint256)",PROXY,POOL)
    asset_balances[name]["proxy_to_pool_erc20_allowance"]={"native":allowance,"error":e}

pool_balance=[]
for i in range(2):
    amount,err=read_uint(POOL,"balances(uint256)(uint256)",str(i))
    pool_balance.append({"coin":i,"native":amount,"error":err})

print("Slippage ratio (1e18):",slip,"~",display(slip,18),flush=True)
print("stored_rates:",rates,flush=True)
print("Rate limit key:",key,flush=True)
print("Swap maximum nominal:",display(limit["maxAmount18"],18),flush=True)
print("Current swap capacity nominal:",display(limit["available18"],18),flush=True)
print("Swap limit regeneration nominal/day:",
      display(limit["slope18PerSecond"]*86400,18),flush=True)
print("Authorized relayer role:",isRelayer,flush=True)
for name in asset_balances:
    print(name,"balances/allowance:",asset_balances[name],flush=True)
print("Pool reported balances:",pool_balance,flush=True)

quote_rows=[]
for units in AMOUNTS:
    amt=units*10**18
    min_out=amt*rates[1]*slip//rates[0]//10**18
    quote=None
    method=None
    failures={}
    for signature in [
        "get_dy(uint256,uint256,uint256)(uint256)",
        "get_dy(int128,int128,uint256)(uint256)",
    ]:
        value,e=read_uint(POOL,signature,"1","0",str(amt))
        if e is None and value is not None:
            quote=value
            method=signature
            break
        failures[signature]=e
    limit_ok=(limit.get("available18") is not None and amt<=limit["available18"])
    balance_ok=(asset_balances["RLUSD"]["ALMProxy"]["native"] is not None
                and amt<=asset_balances["RLUSD"]["ALMProxy"]["native"])
    output_liquidity_ok=(asset_balances["USDC"]["CurvePool"]["native"] is not None
                         and min_out<=asset_balances["USDC"]["CurvePool"]["native"])
    quote_above_min=(quote>=min_out) if quote is not None else None
    loss_nominal_usdc=(amt//10**12-quote) if quote is not None else None
    gap_ppm=(10**6*(amt//10**12-quote)//(amt//10**12)) if quote is not None else None
    entry={
        "RLUSD_in":units,"RLUSD_in_native":amt,"min_USDC_out_native":min_out,
        "min_USDC_out":display(min_out,6),
        "pool_get_dy_USDC_native":quote,"pool_get_dy_USDC":display(quote,6),
        "quote_implementation":method,
        "quote_errors":failures if method is None else None,
        "quote_meets_controller_minimum":quote_above_min,
        "nominal_USDC_in_minus_quote_out":display(loss_nominal_usdc,6),
        "nominal_difference_ppm":gap_ppm,
        "within_live_swap_limit":limit_ok,
        "within_ALMProxy_RLUSD_balance":balance_ok,
        "min_output_covered_by_pool_USDC_balance":output_liquidity_ok
    }
    quote_rows.append(entry)
    print("RLUSD",units,
          "minUSDC",entry["min_USDC_out"],
          "get_dy_USDC",entry["pool_get_dy_USDC"],
          "quote_meets_min",quote_above_min,
          "rate_limit_ok",limit_ok,
          "RLUSD_balance_ok",balance_ok,
          "USDC_pool_liquidity_ok",output_liquidity_ok,flush=True)

report={
    "source":"Live read-only Ethereum calls; NOT simulated swap execution",
    "pool":POOL,"controller":CONTROLLER,"proxy":PROXY,"rpc_block_before_calls":info,
    "pool_coins":coins,"pool_stored_rates":rates,
    "max_slippage_1e18":slip,"live_swap_limit":limit,"rate_limit_key":key,
    "relayer_address":RELAYER,"relayer_authorized":isRelayer,
    "asset_balances":asset_balances,"pool_reported_balances":pool_balance,
    "quote_rows":quote_rows,
    "interpretation":[
      "A quote below required minOut suggests the swap should revert, not that protection is bypassed.",
      "get_dy quote is hypothetical and can change before any future execution.",
      "A quote above minOut does NOT prove arbitrage, exploitability, or unauthorized token movement.",
      "Historical/non-standard pool quote ABIs may not be supported; quote errors must not be interpreted as zero output.",
      "No user credentials, no token transfers and no live transactions."
    ]
}
Path("audit-output").mkdir(exist_ok=True)
out="audit-output/pass382_live_rlusd_curve_quotes.json"
Path(out).write_text(json.dumps(report,ensure_ascii=False,indent=2))
print("Report:",out,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
