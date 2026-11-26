#!/usr/bin/env python3
"""
PASSO 379: READ-ONLY inventory of potential residual token spending
permissions after Uniswap V4 operations on the Spark ALMProxy.
No forging credentials, writes or transactions.

The expected post-operation state is 0 ERC20 allowance from proxy to Permit2,
and 0 live Permit2 per-token allowance to Universal Router / PositionManager.
Both layers need to be inspected; neither by itself proves an exploit.
"""
import json
import os
import subprocess
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
PERMIT2 = "0x000000000022d473030f116ddeE9f6b43ac78ba3"
ROUTER = "0x66a9893cc07d91d95644aedd05d03f95e1dba8af"
POSITION_MANAGER = "0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e"
TOKENS = {
    "USDT": ("0xdac17f958d2ee523a2206206994597c13d831ec7", 6),
    "USDC": ("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 6),
    "USDS": ("0xdc035d45d973e3ec169d2276ddab16f1e407384f", 18),
    "RLUSD": ("0x8292bb45bf1ee4d140127049757c2e0ff06317ed", 18),
    "PYUSD": ("0x6c3ea9036406852006290770bedfcaba0e23a0e8", 6),
}
SPENDERS = {
    "Permit2": PERMIT2,
    "Uniswap_V4_Router": ROUTER,
    "Uniswap_V4_PositionManager": POSITION_MANAGER,
}

def cast_call(target, signature, *args):
    cmd=["cast","call",target,signature,*args,"--rpc-url",RPC]
    try:
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=35)
        if p.returncode:
            return [],(p.stderr or p.stdout).strip()[:350]
        return [x.split(" [")[0].strip() for x in p.stdout.splitlines() if x.strip()],None
    except Exception as ex:
        return [],str(ex)[:350]

def number(value):
    try:
        return int(value,0)
    except (ValueError,TypeError):
        return None

def rpc_latest_block():
    request=urllib.request.Request(RPC,
        data=json.dumps({"jsonrpc":"2.0","id":379,"method":"eth_getBlockByNumber","params":["latest",False]}).encode(),
        headers={"Content-Type":"application/json","User-Agent":"SparkReadOnlyAudit379"})
    try:
        with urllib.request.urlopen(request,timeout=30) as res:
            data=json.load(res)
        b=data.get("result")
        if not b:
            return {"error":str(data.get("error") or "No block returned")}
        return {"number":int(b["number"],16),"timestamp":int(b["timestamp"],16)}
    except Exception as ex:
        return {"error":str(ex)[:300]}

block=rpc_latest_block()
now=block.get("timestamp")
print("=== PASSO 379: PERMIT2 AND ERC20 ALLOWANCE INVENTORY ===",flush=True)
print("Latest block:",block,flush=True)
print("ALMProxy:",PROXY,flush=True)
print("Permit2:",PERMIT2,flush=True)
print("Router:",ROUTER,flush=True)
print("PositionManager:",POSITION_MANAGER,flush=True)

report=[]
errors=[]
for name,(token,decimals) in TOKENS.items():
    bal,err=cast_call(token,"balanceOf(address)(uint256)",PROXY)
    if err:errors.append({"token":name,"method":"balanceOf","error":err})
    balance=number(bal[0]) if bal else None
    row={"token":name,"contract":token,"decimals":decimals,"balance_native":balance,
         "balance_token_units":str(balance/(10**decimals)) if balance is not None else None,
         "direct_erc20_allowances":{},"permit2_spender_allowances":{}}
    print("\nTOKEN",name,"proxy_balance_native",balance,flush=True)
    for spender_name,spender in SPENDERS.items():
        values,err=cast_call(token,"allowance(address,address)(uint256)",PROXY,spender)
        allowed=number(values[0]) if values else None
        row["direct_erc20_allowances"][spender_name]={"allowance_native":allowed,"error":err}
        if err:errors.append({"token":name,"method":"allowance/"+spender_name,"error":err})
        print("  Direct ERC20 to",spender_name,":",allowed if allowed is not None else "READ_FAILED",flush=True)
    for spender_name,spender in [("Uniswap_V4_Router",ROUTER),
                                 ("Uniswap_V4_PositionManager",POSITION_MANAGER)]:
        values,err=cast_call(PERMIT2,
            "allowance(address,address,address)(uint160,uint48,uint48)",
            PROXY,token,spender)
        amount=number(values[0]) if len(values)>=3 else None
        expiry=number(values[1]) if len(values)>=3 else None
        nonce=number(values[2]) if len(values)>=3 else None
        active=(amount > 0 and expiry >= now) if (
            amount is not None and expiry is not None and now is not None
        ) else None
        row["permit2_spender_allowances"][spender_name]={
            "allowance_native":amount,"expiry":expiry,"nonce":nonce,
            "active":active,"error":err
        }
        if err:errors.append({"token":name,"method":"Permit2/"+spender_name,"error":err})
        print("  Permit2 ->",spender_name,
              "amount:",amount,"expiry:",expiry,"active:",active,"nonce:",nonce,
              flush=True)

    erc20_to_permit2=row["direct_erc20_allowances"]["Permit2"]["allowance_native"]
    row["currently_exercisable_allowance_path"] = (
        balance is not None and balance > 0
        and erc20_to_permit2 is not None and erc20_to_permit2 > 0
        and any(v["active"] is True for v in row["permit2_spender_allowances"].values())
    )
    row["warnings"]=[]
    if erc20_to_permit2 is not None and erc20_to_permit2 > 0:
        row["warnings"].append("Nonzero ALMProxy token->Permit2 allowance")
    if any(v["active"] for v in row["permit2_spender_allowances"].values() if v["active"] is not None):
        row["warnings"].append("One or more active Permit2 spender allowances")
    if balance and any((v["allowance_native"] or 0)>0 for k,v in row["direct_erc20_allowances"].items()
                       if k!="Permit2"):
        row["warnings"].append("Nonzero direct allowance to Router or PositionManager; check intended behavior")
    print("  Currently exercisable two-layer path with proxy balance:",
          row["currently_exercisable_allowance_path"],flush=True)
    if row["warnings"]:
        print("  CHECK:", "; ".join(row["warnings"]),flush=True)
    report.append(row)

result={
    "title":"Spark ALMProxy live allowances after Uniswap V4 operations",
    "snapshot_block_before_calls":block,
    "proxy":PROXY,
    "permit2":PERMIT2,
    "router":ROUTER,
    "position_manager":POSITION_MANAGER,
    "tokens":report,
    "read_errors":errors,
    "limitations":[
        "Allowances are read at latest independently and may reflect different blocks.",
        "An allowance is not evidence of theft; spender code and permissions matter.",
        "Two-layer Permit2 ERC20 approval and per-spender approval both need examination.",
        "A positive path flag is only a capability indicator; no attacker control is established.",
        "Absence of allowances now does not prove no historical residual allowance.",
        "No real transactions or writes sent."
    ]
}
Path("audit-output").mkdir(exist_ok=True)
path="audit-output/pass379_permit2_allowances.json"
with open(path,"w") as f:json.dump(result,f,indent=2,ensure_ascii=False)
print("\n=== SUMMARY ===",flush=True)
print("Tokens inspected:",len(report),flush=True)
print("Read errors:",len(errors),flush=True)
print("Nonzero token->Permit2 approvals:",sum(
    (x["direct_erc20_allowances"]["Permit2"]["allowance_native"] or 0)>0 for x in report),flush=True)
print("Active Permit2 spender allowances:",sum(
    1 for x in report for y in x["permit2_spender_allowances"].values()
    if y["active"] is True),flush=True)
print("Potentially exercisable two-layer paths with token balance:",sum(
    x["currently_exercisable_allowance_path"] for x in report),flush=True)
print("Report:",path,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
