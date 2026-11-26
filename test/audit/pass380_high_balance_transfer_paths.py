#!/usr/bin/env python3
"""
PASSO 380: Read-only high-balance RLUSD/PYUSD USDS destination / allowance audit.

Read live ALMProxy ERC20 balances, direct ERC20 allowances to known contract
addresses, and RateLimits authorization for Controller.transferAsset.
A zero for one tested destination does NOT mean all possible destinations are
disabled. A positive destination limit means it is GOVERNANCE-CONFIGURED,
not that arbitrary outside parties can call the relayer.
No simulated or live token transfer, no eth_send*, no external signing.
"""
import json
import os
import subprocess
from decimal import Decimal
from pathlib import Path

RPC = os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
CONTROLLER = "0xc953972cd006d1f12686fd7185c6d443b15900cd"
RATE_LIMITS = "0x7a5fd5cf045e010e62147f065ceae59e5344b188"
TOKENS = {
    "RLUSD": ("0x8292bb45bf1ee4d140127049757c2e0ff06317ed", 18),
    "PYUSD": ("0x6c3ea9036406852006290770bedfcaba0e23a0e8", 6),
    "USDS": ("0xdc035d45d973e3ec169d2276ddab16f1e407384f", 18),
}
# Source: project production config, verified current controller, OTC config and tests.
PEERS = {
    "Relayer_Safe": "0x8a25a24ede9482c4fc0738f99611be58f1c839ab",
    "Governance_Admin": "0x3300f198988e4c9c63f75df86de36421f06af8c4",
    "Retired_Controller": "0x5c46fc65855c0c7465a1ea85eea0b24b601502d3",
    "OTC_Exchange": "0xd010b876696f345d9e0a1b70f573244fcc2e0a0e",
    "OTC_Buffer": "0x1851c64bbfad132cbe75481f1690c381288ea492",
    "Known_Curve_Pool": "0x4f493b7de8aac7d55f71853688b1f7c8f0243c85",
    "PSM": "0xf6e72db5454dd049d0788e411b06cfaf16853042",
    "DAI_USDS_Migrator": "0x3225737a9bbb6473cb4a45b7244aca2befdb276a",
    "UniswapV4_Router": "0x66a9893cc07d91d95644aedd05d03f95e1dba8af",
    "UniswapV4_Position_Manager": "0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e",
    "Unknown_EOA_Control": "0x000000000000000000000000000000000000beef",
}

def cast(args, use_rpc=True):
    cmd=["cast",*args]
    if use_rpc:
        cmd += ["--rpc-url",RPC]
    try:
        p=subprocess.run(cmd,capture_output=True,text=True,timeout=35)
        if p.returncode:
            return None, (p.stderr or p.stdout).strip()[:360] or f"cast exit {p.returncode}"
        return p.stdout.strip(),None
    except Exception as exc:
        return None, str(exc)[:360]

def call(address,signature,*args):
    return cast(["call",address,signature,*args])

def uint(raw):
    if not raw:
        return None
    try:
        return int(raw.splitlines()[0].split(" [")[0].strip(),0)
    except (ValueError,IndexError):
        return None

def standard(amount,decimal):
    return str(Decimal(amount) / (Decimal(10)**decimal)) if amount is not None else None

def pad_address(addr):
    h=addr.lower().removeprefix("0x")
    if len(h)!=40 or any(c not in "0123456789abcdef" for c in h):
        raise ValueError("Invalid address "+addr)
    return ("0"*24)+h

def transfer_key(root,token,destination):
    rh=root.removeprefix("0x")
    if len(rh)!=64:
        raise ValueError("Invalid LIMIT_ASSET_TRANSFER root")
    encoded="0x"+rh+pad_address(token)+pad_address(destination)
    return cast(["keccak",encoded],use_rpc=False)

print("=== PASSO 380: HIGH-BALANCE TOKEN TRANSFER DESTINATION AUDIT ===",flush=True)
print("Read-only; no transfers, no signing or authorization changes.",flush=True)
root,root_err=call(CONTROLLER,"LIMIT_ASSET_TRANSFER()(bytes32)")
if root_err:
    raise RuntimeError("Cannot read LIMIT_ASSET_TRANSFER: "+root_err)
root=root.splitlines()[0]
print("Transfer root:",root,flush=True)
print("Destinations sampled:",len(PEERS),
      "; results do NOT establish an exhaustive destination whitelist.",flush=True)

report={"proxy":PROXY,"controller":CONTROLLER,"rate_limits":RATE_LIMITS,
        "rate_limit_root":root,"tokens":[],"sampled_destinations":PEERS,
        "errors":[]}
for name,(token,decimals) in TOKENS.items():
    raw,err=call(token,"balanceOf(address)(uint256)",PROXY)
    balance=uint(raw)
    if err:report["errors"].append({"token":name,"call":"balanceOf","error":err})
    row={"name":name,"token":token,"decimals":decimals,
         "proxy_balance_native":balance,
         "proxy_balance_display":standard(balance,decimals),
         "destinations":[]}
    print(f"\nTOKEN {name}: ALMProxy balance={row['proxy_balance_display']} ({balance} native)",flush=True)
    for dest_name,dest in PEERS.items():
        key,key_err=transfer_key(root,token,dest)
        if key_err:
            report["errors"].append({"token":name,"destination":dest_name,"key_error":key_err})
            continue
        limit_raw,lim_err=call(RATE_LIMITS,"getRateLimitData(bytes32)(uint256,uint256,uint256,uint256)",key)
        limit_fields=[]
        if limit_raw and not lim_err:
            for line in limit_raw.splitlines():
                try:limit_fields.append(int(line.split(" [")[0].strip(),0))
                except ValueError:pass
        max_amount=limit_fields[0] if len(limit_fields)==4 else None
        slope=limit_fields[1] if len(limit_fields)==4 else None
        avail_raw,avail_err=call(RATE_LIMITS,"getCurrentRateLimit(bytes32)(uint256)",key)
        available=uint(avail_raw)
        allowance_raw,allowance_err=call(token,"allowance(address,address)(uint256)",PROXY,dest)
        allowance=uint(allowance_raw)
        for method,error in [("limit",lim_err),("available",avail_err),("erc20_allowance",allowance_err)]:
            if error:
                report["errors"].append({"token":name,"destination":dest_name,"call":method,"error":error})
        state={
            "destination_label":dest_name,"destination":dest,"transfer_key":key,
            "max_transfer_native":max_amount,"max_transfer_token_units":standard(max_amount,decimals),
            "limit_slope_per_second_native":slope,
            "current_transfer_allowance_native":available,
            "current_transfer_allowance_token_units":standard(available,decimals),
            "direct_erc20_allowance_native":allowance,
            "direct_erc20_allowance_token_units":standard(allowance,decimals),
            "route_configured":max_amount>0 if max_amount is not None else None,
            "can_cover_proxy_balance":(available>=balance)
                if (available is not None and balance is not None) else None,
        }
        row["destinations"].append(state)
        if state["route_configured"] or (allowance is not None and allowance>0):
            print("  CHECK",dest_name, "transfer_max=",state["max_transfer_token_units"],
                  "available=",state["current_transfer_allowance_token_units"],
                  "direct ERC20 allowance=",state["direct_erc20_allowance_token_units"],flush=True)
        else:
            print("  ",dest_name,"transfer_max=0, direct_allowance=0"
                  if max_amount==0 and allowance==0 else "READ INCOMPLETE",flush=True)
    report["tokens"].append(row)
report["limitations"]=[
    "Only the explicitly named destination addresses were checked. Other destinations may be configured.",
    "A positive rate limit is authorized configuration, not evidence of unauthorized access.",
    "A direct ERC20 allowance does not by itself mean anyone can control the spender.",
    "Values are read at latest and may span more than one block.",
    "RLUSD and USDS use 18 decimals; PYUSD uses 6.",
    "No transactions or production changes occurred."
]
Path("audit-output").mkdir(exist_ok=True)
out="audit-output/pass380_high_balance_transfer_paths.json"
with open(out,"w") as f:json.dump(report,f,ensure_ascii=False,indent=2)
print("\n=== PASSO 380 SUMMARY ===",flush=True)
print("Tokens:",len(report["tokens"]),flush=True)
print("Destination queries:",
      sum(len(x["destinations"]) for x in report["tokens"]),flush=True)
print("Nonzero configured transfer routes:",
      sum(x["route_configured"] is True for t in report["tokens"] for x in t["destinations"]),
      flush=True)
print("Nonzero direct ERC20 approvals:",
      sum((x["direct_erc20_allowance_native"] or 0)>0 for t in report["tokens"]
          for x in t["destinations"]),flush=True)
print("Read errors:",len(report["errors"]),flush=True)
print("Report:",out,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
