#!/usr/bin/env python3
"""
PASSO 390: current-state ERC4626 custody/reserve and redemption exit inventory.

Read-only Ethereum eth_call for known sUSDS and sparkUSDS vaults.
No withdrawal or deposit is attempted, no transaction and no signatures.
Measure real Spark ALMProxy share balances, estimated shares-to-assets value,
ERC4626 previews and maxRedeem/maxWithdraw, and controller rate limits.
A positive redeem value is an asset exposure, not an attacker profit/loss.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec=70
RPC=os.getenv("MAINNET_RPC_URL","https://ethereum-rpc.publicnode.com")
PROXY="0x1601843c5e9bc251a3272907010afa41fa18347e"
CONTROLLER="0xc953972cd006d1f12686fd7185c6d443b15900cd"
RATE_LIMITS="0x7a5fd5cf045e010e62147f065ceae59e5344b188"
VAULTS={
"sUSDS":"0xa3931d71877c0e7a3148cb7eb4463524fec27fbd",
"sparkUSDS_Morpho_test":"0xe41a0583334f0dc4e023acd0bfef3667f6fe0597"
}
RETRIES=int(os.getenv("V4_RPC_RETRIES","2"))
TIMEOUT=int(os.getenv("V4_RPC_TIMEOUT","24"))
READ_ERRORS=[]

def cast(*args):
    p=subprocess.run(["cast",*args],text=True,capture_output=True,timeout=14)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip()[:190])
    return p.stdout.strip()

def w(n):
    return n.to_bytes(32,"big")

def aw(addr):
    return b"\0"*12+bytes.fromhex(addr.lower().removeprefix("0x"))

def read(contract,signature,args=(),label=""):
    payload=json.dumps({"jsonrpc":"2.0","id":390,
                        "method":"eth_call",
                        "params":[{"to":contract,"data":cast("sig",signature)+b"".join(args).hex()},
                                  "latest"]}).encode()
    err=None
    for attempt in range(RETRIES):
        try:
            req=urllib.request.Request(RPC,data=payload,headers={
              "Content-Type":"application/json","User-Agent":"SparkERC4626ReadOnly390"
            })
            with urllib.request.urlopen(req,timeout=TIMEOUT) as resp:
                data=json.load(resp)
            if data.get("error"):
                raise RuntimeError(str(data["error"])[:240])
            h=data.get("result")
            if not isinstance(h,str) or not h.startswith("0x"):
                raise RuntimeError("Invalid JSON-RPC result")
            b=bytes.fromhex(h[2:])
            if len(b)%32:raise RuntimeError("Invalid ABI return length")
            return [int.from_bytes(b[i:i+32],"big") for i in range(0,len(b),32)],None
        except (urllib.error.URLError,TimeoutError,ValueError,RuntimeError) as ex:
            err=str(ex)[:260]
            if "revert" in err.lower():break
            if attempt+1<RETRIES:time.sleep(0.5)
    READ_ERRORS.append({"contract":contract,"method":signature,"label":label,"error":err})
    return None,err

def number(to,sig,args=(),label=""):
    vals,err=read(to,sig,args,label)
    if vals is not None and len(vals)==1:
        return vals[0],None
    return None,err or "Non-uint ABI response"

def number_fmt(n,decimals):
    return str(Decimal(n)/Decimal(10**decimals)) if n is not None and decimals is not None else None

def rate_key(root,vault):
    return cast("keccak","0x"+root[2:]+aw(vault).hex()).strip()

def get_limit(root,vault):
    k=rate_key(root,vault)
    fields,e=read(RATE_LIMITS,"getRateLimitData(bytes32)",[bytes.fromhex(k[2:])],"limit_data")
    av,e2=number(RATE_LIMITS,"getCurrentRateLimit(bytes32)",[bytes.fromhex(k[2:])],"limit_current")
    return {"key":k,"maxAmount":fields[0] if fields and len(fields)==4 else None,
            "slopePerSecond":fields[1] if fields and len(fields)==4 else None,
            "available":av,"error":e or e2}

print("=== PASSO 390: ERC4626 ALMProxy CUSTODY AND REDEMPTION EXPOSURE ===",flush=True)
root_num,e=number(CONTROLLER,"LIMIT_4626_WITHDRAW()",label="withdraw_root")
if root_num is None:
    raise RuntimeError("Cannot get 4626 withdrawal root: "+str(e))
root="0x"+w(root_num).hex()
report={"controller":CONTROLLER,"proxy":PROXY,"withdrawal_root":root,
        "vaults":[],"rpc_errors":READ_ERRORS,
        "limitations":[
            "All eth_call reads use latest state, not one pinned block.",
            "convertToAssets and previewRedeem are hypothetical vault accounting views.",
            "Token prices are not verified; nominal USDS units are not guaranteed USD market value.",
            "Exit controls do not guarantee liquidity or settlement at a later time.",
            "Only two repository-grounded vault candidates were tested.",
            "No transfers, deposits, withdrawals, broadcasts, signatures or live state changes."
        ]}
for name,vault in VAULTS.items():
    print("\nVAULT:",name,vault,flush=True)
    shares,shares_err=number(vault,"balanceOf(address)",[aw(PROXY)],name+" shares")
    share_decimals,share_dec_err=number(vault,"decimals()",label=name+" decimals")
    asset_num,asset_err=number(vault,"asset()",label=name+" asset")
    asset="0x"+w(asset_num)[12:].hex() if asset_num is not None else None
    asset_decimals,ad_err=number(asset,"decimals()",label=name+" asset decimals") if asset else (None,asset_err)
    underlying_balance,ub_err=number(asset,"balanceOf(address)",[aw(PROXY)],name+" asset balance") if asset else (None,asset_err)
    max_redeem,redeem_err=number(vault,"maxRedeem(address)",[aw(PROXY)],name+" maxRedeem")
    max_withdraw,withdraw_err=number(vault,"maxWithdraw(address)",[aw(PROXY)],name+" maxWithdraw")
    converted,conv_err=number(vault,"convertToAssets(uint256)",[w(shares)],name+" convertedAssets") if shares is not None else (None,shares_err)
    preview,prev_err=number(vault,"previewRedeem(uint256)",[w(shares)],name+" previewRedeem") if shares is not None else (None,shares_err)
    limit=get_limit(root,vault)
    available=limit.get("available")
    nominal_withdrawals_supported=(available>=converted) if available is not None and converted is not None else None
    nominal_vault_withdrawable=(max_withdraw>=converted) if max_withdraw is not None and converted is not None else None
    row={
        "vault":vault,"name":name,"asset":asset,"asset_decimals":asset_decimals,
        "share_decimals":share_decimals,
        "almProxy_share_balance_native":shares,
        "almProxy_share_balance":number_fmt(shares,share_decimals),
        "almProxy_underlying_asset_native":underlying_balance,
        "almProxy_underlying_asset":number_fmt(underlying_balance,asset_decimals),
        "convertToAssets_allShares_native":converted,
        "convertToAssets_allShares":number_fmt(converted,asset_decimals),
        "previewRedeem_allShares_native":preview,
        "previewRedeem_allShares":number_fmt(preview,asset_decimals),
        "maxRedeem_native_shares":max_redeem,
        "maxRedeem_shares":number_fmt(max_redeem,share_decimals),
        "maxWithdraw_native_assets":max_withdraw,
        "maxWithdraw_assets":number_fmt(max_withdraw,asset_decimals),
        "withdrawal_rate_limit":limit,
        "withdrawal_limit_covers_share_claim":nominal_withdrawals_supported,
        "vault_maxWithdraw_covers_share_claim":nominal_vault_withdrawable,
        "read_errors":{
            "shares":shares_err,"shareDecimals":share_dec_err,"asset":asset_err,
            "assetDecimals":ad_err,"underlyingBalance":ub_err,"maxRedeem":redeem_err,
            "maxWithdraw":withdraw_err,"convertToAssets":conv_err,"previewRedeem":prev_err
        }
    }
    print("  ALMProxy shares:",row["almProxy_share_balance"],flush=True)
    print("  Preview underlying claim:",row["previewRedeem_allShares"],
          "asset",asset,flush=True)
    print("  ConvertToAssets claim:",row["convertToAssets_allShares"],flush=True)
    print("  ALMProxy underlying balance:",row["almProxy_underlying_asset"],flush=True)
    print("  Vault maxRedeem:",row["maxRedeem_shares"],
          "Vault maxWithdraw:",row["maxWithdraw_assets"],flush=True)
    print("  Controller withdraw limit max:",limit["maxAmount"],
          "available:",limit["available"],flush=True)
    print("  Controller limit covers claim:",nominal_withdrawals_supported,
          "Vault maxWithdraw covers claim:",nominal_vault_withdrawable,flush=True)
    report["vaults"].append(row)

out="audit-output/pass390_erc4626_custody_redemption_readonly.json"
Path("audit-output").mkdir(exist_ok=True)
Path(out).write_text(json.dumps(report,indent=2,ensure_ascii=False))
print("\n=== SUMMARY ===",flush=True)
print("Vaults read:",len(report["vaults"]),flush=True)
print("RPC read errors:",len(READ_ERRORS),flush=True)
print("Output:",out,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
