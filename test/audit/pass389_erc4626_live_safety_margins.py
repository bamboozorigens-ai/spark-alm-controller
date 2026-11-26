#!/usr/bin/env python3
"""
PASSO 389 -- ERC-4626 live-configured deposit/withdraw economic safety margins.

Defensive research, using latest-state Ethereum eth_call ONLY.
Review vaults directly sourced from the Spark repository:
  - sUSDS: mainnet Spark address registry and test/mainnet-fork/4626Calls.t.sol
  - sparkUSDS MetaMorpho: test/mainnet-fork/ERC4626DonationAttack.t.sol

No donation, no mint, no deposits, no fork, no tx, no signing.
Goal: measure whether controller maxExchangeRate and rate-limit ceilings
are aligned with vault convertToShares and the proxy's real asset balance.
A misaligned setting is a RISK INDICATOR, not a verified exploit.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec=85
RPC=os.getenv("MAINNET_RPC_URL","https://ethereum-rpc.publicnode.com")
CONTROLLER="0xc953972cd006d1f12686fd7185c6d443b15900cd"
RATE_LIMITS="0x7a5fd5cf045e010e62147f065ceae59e5344b188"
PROXY="0x1601843c5e9bc251a3272907010afa41fa18347e"
VAULTS={
 "sUSDS": "0xa3931d71877c0e7a3148cb7eb4463524fec27fbd",
 "sparkUSDS_Morpho_test": "0xe41a0583334f0dc4e023acd0bfef3667f6fe0597",
}
REQUEST_AMOUNTS=[100_000,1_000_000,5_000_000]
TIMEOUT=int(os.getenv("V4_RPC_TIMEOUT","24"))
RETRIES=max(1,int(os.getenv("V4_RPC_RETRIES","2")))
ERRORS=[]

def sig(s):
    p=subprocess.run(["cast","sig",s],capture_output=True,text=True,timeout=15)
    if p.returncode:raise RuntimeError("Foundry cast selector error: "+(p.stderr or p.stdout).strip()[:180])
    v=p.stdout.strip()
    if len(v)!=10 or not v.startswith("0x"):raise ValueError("Unexpected selector: "+v)
    return v

def word(n):
    if not isinstance(n,int) or not 0<=n<2**256:raise ValueError("Unexpected ABI word")
    return n.to_bytes(32,"big")

def address_arg(a):
    h=a.lower().removeprefix("0x")
    if len(h)!=40:raise ValueError("Bad Ethereum address")
    return b"\x00"*12+bytes.fromhex(h)

def rpc(to,sig_,args=(),label="call"):
    body=json.dumps({"jsonrpc":"2.0","id":389,"method":"eth_call",
                     "params":[{"to":to,"data":sig(sig_)+b"".join(args).hex()},"latest"]}).encode()
    err=None
    for attempt in range(RETRIES):
        try:
            req=urllib.request.Request(RPC,data=body,headers={
                "Content-Type":"application/json","User-Agent":"SparkReadOnlyERC4626389"
            })
            with urllib.request.urlopen(req,timeout=TIMEOUT) as f:p=json.load(f)
            if p.get("error"):raise RuntimeError(str(p["error"])[:260])
            raw=p.get("result")
            if not isinstance(raw,str) or not raw.startswith("0x"):raise ValueError("Unexpected RPC result")
            return bytes.fromhex(raw[2:]),None
        except (urllib.error.URLError,TimeoutError,RuntimeError,ValueError) as e:
            err=str(e)[:260]
            if "revert" in err.lower():break
            if attempt+1<RETRIES:time.sleep(0.5)
    ERRORS.append({"contract":to,"method":sig_,"label":label,"error":err})
    return None,err

def number(to,sig_,args=(),label=""):
    raw,err=rpc(to,sig_,args,label)
    if raw is not None and len(raw)==32:
        return int.from_bytes(raw,"big"),None
    return None,err or "Invalid ABI number"

def address(to,sig_,args=(),label=""):
    value,err=number(to,sig_,args,label)
    return ("0x"+word(value)[12:].hex(),None) if value is not None else (None,err)

def fmt(value,decimals):
    return str(Decimal(value)/(Decimal(10)**decimals)) if value is not None else None

def key(root,vault):
    encoded=bytes.fromhex(root[2:])+address_arg(vault)
    p=subprocess.run(["cast","keccak","0x"+encoded.hex()],capture_output=True,text=True,timeout=15)
    if p.returncode:raise RuntimeError("Cannot compute rate key: "+(p.stderr or p.stdout)[:200])
    return p.stdout.strip()

def read_limit(root,vault,label):
    k=key(root,vault)
    data,err=rpc(RATE_LIMITS,"getRateLimitData(bytes32)",(bytes.fromhex(k[2:]),),label)
    fields=([int.from_bytes(data[i:i+32],"big") for i in range(0,128,32)]
            if data is not None and len(data)==128 else None)
    av,e2=number(RATE_LIMITS,"getCurrentRateLimit(bytes32)",(bytes.fromhex(k[2:]),),label+"_current")
    return {"key":k,
      "maxAmount_native":fields[0] if fields else None,
      "slope_native_per_second":fields[1] if fields else None,
      "lastAmount_native":fields[2] if fields else None,
      "lastUpdated":fields[3] if fields else None,
      "available_native":av,
      "error":err or e2}

print("=== PASSO 389: LIVE ERC4626 DEPOSIT PROTECTION AND ECONOMIC MARGINS ===",flush=True)
print("Only state queries, no vault interaction or transfers.",flush=True)
roots={}
for label in ("DEPOSIT","WITHDRAW"):
    v,e=number(CONTROLLER,"LIMIT_4626_"+label+"()",label="root_"+label)
    if v is None:raise RuntimeError("Cannot read "+label+" root: "+str(e))
    roots[label]="0x"+word(v).hex()
    print(label,"root:",roots[label],flush=True)

results=[]
for name,vault in VAULTS.items():
    print("\nVAULT",name,vault,flush=True)
    asset,asset_err=address(vault,"asset()",label=name+"_asset")
    decimals,dec_err=number(vault,"decimals()",label=name+"_vault_decimals")
    total_assets,ta_err=number(vault,"totalAssets()",label=name+"_totalAssets")
    total_supply,ts_err=number(vault,"totalSupply()",label=name+"_totalSupply")
    proxy_shares,ps_err=number(vault,"balanceOf(address)",[address_arg(PROXY)],name+"_proxyShares")
    max_exchange,ex_err=number(CONTROLLER,"maxExchangeRates(address)",[address_arg(vault)],name+"_maxRate")
    limits={label:read_limit(root,vault,name+"_"+label) for label,root in roots.items()}
    asset_decimals,ad_err=(number(asset,"decimals()",label=name+"_assetDecimals")
                           if asset else (None,asset_err))
    proxy_assets,pa_err=(number(asset,"balanceOf(address)",[address_arg(PROXY)],name+"_proxyAssets")
                         if asset else (None,asset_err))
    row={
     "name":name,"vault":vault,"asset":asset,"asset_error":asset_err,
     "share_decimals":decimals,"share_decimals_error":dec_err,
     "asset_decimals":asset_decimals,"asset_decimals_error":ad_err,
     "total_assets_native":total_assets,"total_assets_error":ta_err,
     "total_supply_native":total_supply,"total_supply_error":ts_err,
     "proxy_share_balance_native":proxy_shares,"proxy_share_balance_error":ps_err,
     "proxy_asset_balance_native":proxy_assets,"proxy_asset_balance_error":pa_err,
     "maxExchangeRate_1e36":max_exchange,"maxExchangeRate_error":ex_err,
     "limits":limits,"scenarios":[]
    }
    print(" underlying asset:",asset,"decimals",asset_decimals,flush=True)
    print(" proxy assets:",fmt(proxy_assets,asset_decimals) if asset_decimals is not None else None,
          "proxy shares:",fmt(proxy_shares,decimals) if decimals is not None else None,flush=True)
    print(" vault totalAssets:",fmt(total_assets,asset_decimals) if asset_decimals is not None else None,
          "totalSupply:",fmt(total_supply,decimals) if decimals is not None else None,flush=True)
    print(" governance maxExchangeRate (scaled 1e36):",max_exchange,flush=True)
    for label,l in limits.items():
        print(" ",label,"max:",fmt(l["maxAmount_native"],asset_decimals) if asset_decimals is not None else l["maxAmount_native"],
              "available:",fmt(l["available_native"],asset_decimals) if asset_decimals is not None else l["available_native"],
              "error:",l["error"],flush=True)
    if asset_decimals is None:
        print(" asset metadata unavailable: skip economic calculations",flush=True)
        results.append(row)
        continue
    for nominal in REQUEST_AMOUNTS:
        amount=nominal*10**asset_decimals
        quote,quote_err=number(vault,"convertToShares(uint256)",[word(amount)],name+"_convertToShares_"+str(nominal))
        rate=10**36*amount//quote if quote and quote>0 else None
        # ERC4626Lib.require(getExchangeRate(shares, amount)<=maxExchangeRate)
        required_shares=(10**36*amount+max_exchange-1)//max_exchange if max_exchange and max_exchange>0 else None
        under_allowance=(quote>=required_shares) if quote is not None and required_shares is not None else None
        capacity=limits["DEPOSIT"]["available_native"]
        capacity_ok=amount<=capacity if capacity is not None else None
        balance_ok=amount<=proxy_assets if proxy_assets is not None else None
        # Shares nominally removed at the max configured exchange rate. This is NOT realized loss.
        fraction_margin=(Decimal(1)-Decimal(required_shares)/Decimal(quote)) if quote and required_shares else None
        worst_case_nominal_loss=(Decimal(nominal)*fraction_margin
                                  if fraction_margin is not None and fraction_margin>0 else Decimal(0)
                                  if fraction_margin is not None else None)
        scenario={
          "assets_nominal":nominal,
          "underlying_amount_native":amount,
          "convertToShares_quote_native":quote,
          "convertToShares_error":quote_err,
          "effective_current_exchange_rate_1e36":rate,
          "required_min_shares_by_controller_native":required_shares,
          "quote_passes_configured_exchange_rate":under_allowance,
          "within_deposit_limit":capacity_ok,
          "within_proxy_asset_balance":balance_ok,
          "hypothetical_allowed_share_shortfall_ratio":str(fraction_margin) if fraction_margin is not None else None,
          "hypothetical_nominal_value_margin_if_max_rate_exhausted":str(worst_case_nominal_loss) if worst_case_nominal_loss is not None else None,
        }
        row["scenarios"].append(scenario)
        print(" ",nominal,"units: quote shares=",quote,
              "required min shares=",required_shares,
              "rate guard passes current quote=",under_allowance,
              "capacity sufficient=",capacity_ok,
              "proxy balance sufficient=",balance_ok,
              "theoretical margin (unit parity)=",scenario["hypothetical_nominal_value_margin_if_max_rate_exhausted"],
              "quote error=",quote_err,flush=True)
    results.append(row)

output="audit-output/pass389_erc4626_live_safety_margins.json"
Path("audit-output").mkdir(exist_ok=True)
Path(output).write_text(json.dumps({
 "purpose":"Read-only live margin and configuration analysis for known ERC4626 vaults",
 "controller":CONTROLLER,"proxy":PROXY,
 "rate_limits":RATE_LIMITS,"root_keys":roots,
 "vaults":results,"rpc_errors":ERRORS,
 "limitations":[
  "All calls independently use latest; no pinned block; values may change.",
  "These are two source-grounded vault candidates, not a complete whitelist.",
  "A hypothetical margin assumes a 1:1 valuation and is not a realized loss.",
  "A positive margin is not evidence of theft, market manipulation, or exploitable donation attack.",
  "ERC4626 preview rounding and vault accounting dynamics require separate fork tests.",
  "No transactions, token transfers, changes or token donations were executed."
 ]
},ensure_ascii=False,indent=2))
print("\n=== SUMMARY ===",flush=True)
print("Vault candidates checked:",len(results),flush=True)
print("Positive live deposit capacity:",
      sum((r["limits"]["DEPOSIT"]["maxAmount_native"] or 0)>0 for r in results),flush=True)
print("Nonzero rate guards:",sum((r["maxExchangeRate_1e36"] or 0)>0 for r in results),flush=True)
print("RPC read errors:",len(ERRORS),flush=True)
print("Report:",output,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
