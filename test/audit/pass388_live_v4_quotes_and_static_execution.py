#!/usr/bin/env python3
"""
PASSO 388: Direct Ethereum read-only V4 QUOTER and eth_call swap preflight.

Three real, CURRENT-controller enabled V4 pools from PASSO 387. Obtain full
pool keys from PositionManager, quote through V4 Quoter and simulate the
Controller's full swap with eth_call (state is discarded). No transactions.

The relayer address is ONLY used as eth_call.from. No private key, signing,
broadcast, live asset movement, mempool interaction or on-chain approvals.

An eth_call that succeeds demonstrates simulation under that latest state,
NOT that a real transaction can always execute. Reverts may be due to
price, RPC, gas, role changes or market movement: report reason if available.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec=60
RPC=os.getenv("MAINNET_RPC_URL","https://ethereum-rpc.publicnode.com")
CONTROLLER="0xc953972cd006d1f12686fd7185c6d443b15900cd"
PROXY="0x1601843c5e9bc251a3272907010afa41fa18347e"
RELAYER="0x8a25a24ede9482c4fc0738f99611be58f1c839ab"
POSITION_MANAGER="0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e"
QUOTER="0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203"
LIMITS="0x7a5fd5cf045e010e62147f065ceae59e5344b188"
POOLS={
 "RLUSD/USDS":"0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f",
 "PYUSD/USDS":"0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45",
 "USDT/USDS":"0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9"
}
TOKENS={
 "RLUSD":("0x8292bb45bf1ee4d140127049757c2e0ff06317ed",18),
 "PYUSD":("0x6c3ea9036406852006290770bedfcaba0e23a0e8",6),
 "USDT":("0xdac17f958d2ee523a2206206994597c13d831ec7",6),
 "USDS":("0xdc035d45d973e3ec169d2276ddab16f1e407384f",18),
}
STABLE_ADDRESS_TO_META={a:(name,d) for name,(a,d) in TOKENS.items()}
ONE=10**18
RETRIES=max(1,int(os.getenv("V4_RPC_RETRIES","2")))
TIMEOUT=max(8,int(os.getenv("V4_RPC_TIMEOUT","24")))
RPC_ERRORS=[]

def cast_sig(signature):
    p=subprocess.run(["cast","sig",signature],capture_output=True,text=True,timeout=15)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip()[:300])
    v=p.stdout.strip()
    if len(v)!=10 or not v.startswith("0x"):
        raise RuntimeError("Invalid selector for "+signature)
    return v.lower()

def abiword(value):
    if isinstance(value,int):
        return value.to_bytes(32,"big")
    if isinstance(value,bytes):
        if len(value)!=32:
            raise ValueError("ABI argument must be 32 bytes")
        return value
    raise TypeError("Unexpected ABI word type")

def as_words(data):
    if data is None or len(data)%32:
        raise ValueError("Malformed ABI returndata")
    return [int.from_bytes(data[i:i+32],"big") for i in range(0,len(data),32)]

def read_call(to,call_data,label,from_account=None):
    call_args={"to":to,"data":call_data}
    if from_account:
        call_args["from"]=from_account
        call_args["gas"]="0x989680"   # 10,000,000 gas for EVM simulation only
    body=json.dumps({"jsonrpc":"2.0","id":388,
          "method":"eth_call","params":[call_args,"latest"]}).encode()
    last_error=None
    for attempt in range(RETRIES):
        try:
            request=urllib.request.Request(
                RPC,data=body,
                headers={"Content-Type":"application/json",
                         "User-Agent":"SparkReadOnlyV4Quote388"}
            )
            with urllib.request.urlopen(request,timeout=TIMEOUT) as f:
                payload=json.load(f)
            if "error" in payload:
                detail=payload["error"]
                last_error=str(detail)[:620]
                # Reverts are deterministic EVM responses; don't blindly repeat.
                if "revert" in last_error.lower() or "execution" in last_error.lower():
                    return None,last_error
                raise RuntimeError(last_error)
            raw=payload.get("result")
            if not isinstance(raw,str) or not raw.startswith("0x"):
                raise RuntimeError("Invalid eth_call result")
            return bytes.fromhex(raw[2:]),None
        except (urllib.error.URLError,RuntimeError,TimeoutError,ValueError) as ex:
            last_error=str(ex)[:620]
            if attempt+1<RETRIES:
                time.sleep(0.6*(attempt+1))
    RPC_ERRORS.append({"label":label,"address":to,"error":last_error})
    return None,last_error

def simple_call(to,signature,words,label):
    return read_call(to,cast_sig(signature)+b"".join(abiword(w) for w in words).hex(),label)

def get_uint(to,signature,words,label):
    data,err=simple_call(to,signature,words,label)
    if err:
        return None,err
    values=as_words(data)
    if len(values)!=1:
        return None,"Not one ABI word"
    return values[0],None

def get_address(i):
    return "0x"+(i & ((1<<160)-1)).to_bytes(20,"big").hex()

def norm(value,decimals):
    return value*(10**18)//(10**decimals)

def display(value,decimals):
    if value is None:
        return None
    return str(Decimal(value)/Decimal(10**decimals))

def ceildiv(a,b):
    return (a+b-1)//b

def quote_payload(raw_pool_key,zero_for_one,amount_in):
    # quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))
    # 32 bytes top-level offset, tuple head: 5 PoolKey words + bool +
    # amount + 32-byte dynamic offset; empty bytes tail.
    sig="quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"
    if len(raw_pool_key)!=160 or not 0<=amount_in<2**128:
        raise ValueError("Invalid PoolKey or amount")
    encoded = (
        abiword(32) +
        raw_pool_key +
        abiword(int(zero_for_one)) +
        abiword(amount_in) +
        abiword(8*32) +
        abiword(0)
    )
    return cast_sig(sig)+encoded.hex()

def simulate_controller_swap(pool_id,asset_in,amount_in,min_amount,label):
    signature="swapUniswapV4(bytes32,address,uint128,uint128)"
    payload=cast_sig(signature)+(
        bytes.fromhex(pool_id[2:])+
        b"\x00"*12+bytes.fromhex(asset_in[2:])+
        abiword(amount_in)+abiword(min_amount)
    ).hex()
    data,err=read_call(CONTROLLER,payload,label,from_account=RELAYER)
    return {"success":err is None,"error":err,
            "returndata_hex":data.hex()[:90] if data is not None else None}

def pool_limit(root,pool_id):
    # bytes32 rateLimit key = keccak256(abi.encode(root, poolId))
    candidate="0x"+root[2:]+pool_id[2:]
    p=subprocess.run(["cast","keccak",candidate],capture_output=True,text=True,timeout=15)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip()[:250])
    key=p.stdout.strip()
    values_data,err=simple_call(LIMITS,"getRateLimitData(bytes32)",
                                [bytes.fromhex(key[2:])],"limit_data:"+pool_id)
    values=as_words(values_data) if values_data is not None else []
    available,err_av=get_uint(LIMITS,"getCurrentRateLimit(bytes32)",
        [bytes.fromhex(key[2:])],"limit_available:"+pool_id)
    return {"key":key,"maxAmount18":values[0] if len(values)==4 else None,
            "available18":available,"error":err or err_av}

print("=== PASSO 388: LIVE UNISWAP V4 QUOTES AND ETH_CALL PREFLIGHT ===",flush=True)
print("Current active pools from PASSO 387, NO LIVE TRANSACTIONS.",flush=True)
root_data,root_error=simple_call(CONTROLLER,"LIMIT_UNISWAP_V4_SWAP()",[],"swap_root")
root="0x"+root_data.hex() if root_data is not None and len(root_data)==32 else None
if root is None:
    raise RuntimeError("Unable to read swap limit root: "+str(root_error))
print("Swap limit root:",root,flush=True)

results=[]
for label,pool_id in POOLS.items():
    name_in=label.split("/")[0]
    in_address,in_decimals=TOKENS[name_in]
    data,err=simple_call(POSITION_MANAGER,"poolKeys(bytes25)",
        [bytes.fromhex(pool_id[2:])[:25]+b"\x00"*7],label+":poolKeys")
    print("\nPOOL",label,pool_id,flush=True)
    if err or data is None or len(data)!=160:
        print("POOL KEY INCONCLUSIVE:",err or "unexpected ABI length",flush=True)
        results.append({"pair":label,"pool_id":pool_id,
                        "error":err or "Invalid PoolKey ABI","quotes":[]})
        continue
    words=as_words(data)
    token0=get_address(words[0]);token1=get_address(words[1])
    if in_address not in (token0,token1):
        print("NOT A MATCHING POOL: token pair does not contain input",flush=True)
        results.append({"pair":label,"pool_id":pool_id,
                        "error":"Pool does not contain expected input token","quotes":[]})
        continue
    zero_for_one=in_address==token0
    token_out=token1 if zero_for_one else token0
    if token_out not in STABLE_ADDRESS_TO_META:
        print("Output token decimals unknown; skip numeric quote",flush=True)
        results.append({"pair":label,"pool_id":pool_id,
                        "error":"Unrecognized output token "+token_out,"quotes":[]})
        continue
    name_out,out_decimals=STABLE_ADDRESS_TO_META[token_out]
    suffix="0x"+pool_id[-40:]
    slippage,err_slip=get_uint(CONTROLLER,"maxSlippages(address)",
        [b"\x00"*12+bytes.fromhex(suffix[2:])],label+":maxSlippages")
    limit=pool_limit(root,pool_id)
    proxy_balance,err_balance=get_uint(in_address,"balanceOf(address)",
        [b"\x00"*12+bytes.fromhex(PROXY[2:])],label+":proxy_balance")
    entry={"pair":label,"pool_id":pool_id,
           "currency0":token0,"currency1":token1,
           "input_token":name_in,"input_token_decimals":in_decimals,
           "output_token":name_out,"output_token_decimals":out_decimals,
           "zeroForOne":zero_for_one,
           "slippage_1e18":slippage,"slippage_error":err_slip,
           "rate_limit":limit,"proxy_input_balance_native":proxy_balance,
           "proxy_balance_error":err_balance,"quotes":[]}

    print("  Pool tokens:",STABLE_ADDRESS_TO_META.get(token0),
          "->",STABLE_ADDRESS_TO_META.get(token1),flush=True)
    print("  Input balance:",display(proxy_balance,in_decimals),name_in,
          "maxSwap:",display(limit.get("maxAmount18"),18),
          "available:",display(limit.get("available18"),18),
          "slippage:",display(slippage,18),flush=True)
    volumes=[100_000,1_000_000,5_000_000] if name_in!="USDT" else [1000,5000,6000]
    for units in volumes:
        amount_in=units*10**in_decimals
        amount_normalized=norm(amount_in,in_decimals)
        # Exact controller predicate for normal ERC20 decimals <= 18:
        # normalizedOut *1e18 >= normalizedIn*slippage.
        min_normalized=ceildiv(amount_normalized*slippage,ONE) if slippage else None
        min_out=ceildiv(min_normalized*10**out_decimals,ONE) if min_normalized is not None else None
        qdata,qerr=read_call(QUOTER,quote_payload(data,zero_for_one,amount_in),
                             label+":quote:"+str(units))
        qwords=as_words(qdata) if qdata is not None else []
        quoted_out=qwords[0] if len(qwords)==2 else None
        quote_error=qerr if qerr else ("unexpected quoter output" if len(qwords)!=2 else None)
        enough_capacity=(amount_normalized<=limit["available18"]) if limit.get("available18") is not None else None
        enough_balance=(amount_in<=proxy_balance) if proxy_balance is not None else None
        meets_floor=(quoted_out>=min_out) if quoted_out is not None and min_out is not None else None
        item={"input_nominal":units,"amount_in_native":amount_in,
              "amount_in_normalized_18":amount_normalized,
              "minimum_out_native":min_out,
              "minimum_out_display":display(min_out,out_decimals),
              "quoter_out_native":quoted_out,
              "quoter_out_display":display(quoted_out,out_decimals),
              "quoter_error":quote_error,
              "quote_meets_floor":meets_floor,
              "within_controller_swap_rate_limit":enough_capacity,
              "within_proxy_token_balance":enough_balance,
              "simulation":None,"under_floor_control":None}
        if (enough_capacity and enough_balance and min_out is not None
                and amount_in<2**128 and min_out<2**128):
            item["simulation"]=simulate_controller_swap(
                pool_id,in_address,amount_in,min_out,label+":swap:"+str(units))
            # Test the floor enforcement for ONE representative amount per pool.
            if units==volumes[0] and min_out>0:
                item["under_floor_control"]=simulate_controller_swap(
                    pool_id,in_address,amount_in,min_out-1,
                    label+":below_floor:"+str(units))
        entry["quotes"].append(item)
        print(" ",units,name_in,"quoter",item["quoter_out_display"],name_out,
              "min required",item["minimum_out_display"],
              "quote above floor",meets_floor,
              "cap OK",enough_capacity,
              "balance OK",enough_balance,
              "eth_call swap success",
              item["simulation"]["success"] if item["simulation"] else "NOT_SIMULATED",
              "error",item["simulation"]["error"] if item["simulation"] else quote_error,
              flush=True)
        if item["under_floor_control"]:
            print("   Under-min control success (expected False):",
                  item["under_floor_control"]["success"],
                  "reason",item["under_floor_control"]["error"],flush=True)
    results.append(entry)

report={
    "title":"Three live V4 routes: actual quoter + full controller eth_call simulations",
    "RPC":RPC.split("?")[0],
    "controller":CONTROLLER,"proxy":PROXY,
    "relayer":RELAYER,"position_manager":POSITION_MANAGER,"quoter":QUOTER,
    "pools":results,
    "rpc_errors":RPC_ERRORS,
    "limitations":[
      "eth_call only: simulated EVM state is discarded; no transaction is broadcast.",
      "From-address impersonation in eth_call is NOT live authorization control.",
      "A successful simulation is not proof of unrestricted attack or guaranteed execution.",
      "A reverted eth_call is not an exploit and must be classified by its actual reason.",
      "Quoter and controller simulate independent latest snapshots; prices may change.",
      "Configured max slippage uses normalized 18-decimal values, not an oracle.",
      "Controller-supplied min output is a FLOOR; real relayers may use higher min outputs.",
      "No proof of adverse manipulation, attacker profit or missing permission."
    ]
}
Path("audit-output").mkdir(exist_ok=True)
out="audit-output/pass388_live_v4_quotes_and_static_execution.json"
Path(out).write_text(json.dumps(report,indent=2,ensure_ascii=False))
print("\n=== SUMMARY ===",flush=True)
for item in results:
    checks=[row for row in item.get("quotes",[]) if row.get("simulation")]
    successes=sum(1 for row in checks if row["simulation"]["success"])
    print(item["pair"],"simulated",len(checks),"successful",successes,
          "RPC / read errors:",len(RPC_ERRORS),flush=True)
print("Report:",out,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
