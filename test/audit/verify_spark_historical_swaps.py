#!/usr/bin/env python3
"""
PASSO 365: independently verify 3 real Spark V4 swap CALLS found in Passo 364.
Read-only Blockscout API v2. No wallet, private key, archive RPC, or broadcasts.

Validate: top-level receipt success, decoded internal call target and parameters,
ERC-20 transfers to/from actual Spark ALMProxy, and any discrepancies.
Token flows represent the ENTIRE top-level tx (not necessarily only one swap).
"""
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, getcontext

getcontext().prec = 60
BASE = "https://eth.blockscout.com/api/v2"
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
OLD = "0x5c46fc65855c0c7465a1ea85eea0b24b601502d3"
POOL = "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9"
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
USDS = "0xdc035d45d973e3ec169d2276ddab16f1e407384f"
SELECTOR = "0xde34d3dd"
TXS = [
    "0x5e871d0f2ba2bac08b257ae2c871ab28d4a119082576acd9c9d0f70e25677bd3",
    "0xabfd65f56c8188041d2760fb672fc61e96afd53e78d265001a22fd9d3119643d",
    "0xf16bd190cf0c12b347035abd8528308f3b4f9c09e73b341a8c35ccc496dcdd40",
]
TOKEN_META = {
    USDT: ("USDT", 6),
    USDS: ("USDS", 18),
}

def fetch(path, query=None):
    url = BASE + path
    if query:
        safe = {
            k: v for k, v in query.items()
            if v is not None and not isinstance(v, bool)
            and k != "include_zero_value"
        }
        if safe:
            url += "?" + urllib.parse.urlencode(safe)
    for trial in range(3):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent":"SparkReadOnlyAudit/365 Mozilla/5.0"}
            )
            with urllib.request.urlopen(request,timeout=25) as res:
                return json.load(res)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError) as exc:
            if isinstance(exc, urllib.error.HTTPError) and exc.code in (400, 404, 422):
                body = exc.read(300).decode("utf-8","replace")
                raise RuntimeError(f"HTTP {exc.code}: {body[:200]}") from exc
            if trial == 2:
                raise RuntimeError(str(exc)) from exc
            time.sleep(trial+1)

def addr(x):
    if isinstance(x, str):
        return x.lower()
    if isinstance(x, dict):
        return str(x.get("hash") or x.get("address") or x.get("address_hash") or "").lower()
    return ""

def walk_trace(root):
    todo=[root]
    while todo:
        obj=todo.pop()
        if isinstance(obj,list):
            todo.extend(reversed(obj))
            continue
        if not isinstance(obj,dict):
            continue
        action=obj.get("action")
        pieces=[obj] + ([action] if isinstance(action,dict) else [])
        for item in pieces:
            if addr(item.get("to")) != OLD:
                continue
            raw = item.get("input") or item.get("raw_input") or item.get("data")
            if not isinstance(raw, str) or not raw.lower().startswith(SELECTOR):
                continue
            raw=raw.lower()
            if len(raw) < 10 + 4*64:
                continue
            words=[raw[10+64*i:10+64*(i+1)] for i in range(4)]
            pool="0x"+words[0]
            token="0x"+words[1][-40:]
            incoming=int(words[2],16)
            minimum=int(words[3],16)
            yield {
                "to":OLD, "from":addr(item.get("from")),
                "pool":pool, "token_in":token, "amount_in_raw":str(incoming),
                "amount_in":str(Decimal(incoming)/Decimal(10**6)) if token==USDT else None,
                "min_out":str(Decimal(minimum)/Decimal(10**18)) if token==USDT and pool==POOL else None,
                "trace_error":obj.get("error"),
            }
        for key,val in obj.items():
            if key!="action" and isinstance(val,(dict,list)):
                todo.append(val)

def transfer_amount(t):
    token=t.get("token") or {}
    token_addr=addr(token)
    if token_addr not in TOKEN_META:
        return None
    raw=t.get("total")
    if isinstance(raw,dict):
        raw=raw.get("value")
    elif raw is None:
        raw=t.get("amount")
    if raw is None:
        return None
    symbol, decimals=TOKEN_META[token_addr]
    try:
        return symbol, Decimal(str(raw))/Decimal(10**decimals), token_addr
    except Exception:
        return None

def transfers_for_hash(tx_hash):
    items=[]
    cursor=None
    complete=False
    error=None
    for page in range(6):
        try:
            data=fetch("/transactions/"+tx_hash+"/token-transfers",cursor)
            batch=data.get("items",[])
            if not isinstance(batch,list):
                error="token-transfers does not return list"
                break
            items.extend(batch)
            next_cursor=data.get("next_page_params")
            if not next_cursor or not isinstance(next_cursor,dict):
                complete=True
                break
            cursor=next_cursor
            time.sleep(0.15)
        except Exception as exc:
            error=str(exc)[:250]
            break
    else:
        error="pagination capped at six pages"
    return items,complete,error

print("=== PASSO 365: CONFIRMAR SWAPS E MOVIMENTACAO REAL ===",flush=True)
print("Blockscout indexed receipts + raw traces + token transfers, READ ONLY",flush=True)
results=[]
for tx_hash in TXS:
    print("\n=== TX",tx_hash,"===",flush=True)
    item={"tx_hash":tx_hash, "explorer":"https://eth.blockscout.com/tx/"+tx_hash}
    try:
        tx=fetch("/transactions/"+tx_hash)
        if not isinstance(tx,dict):
            raise RuntimeError("Transaction response not an object")
        receipt_status=tx.get("status")
        item["receipt"]={
            "status":receipt_status,
            "result":tx.get("result"),
            "block_number":tx.get("block_number"),
            "timestamp":tx.get("timestamp"),
            "tx_index":tx.get("position",tx.get("transaction_index")),
            "from":addr(tx.get("from")),"to":addr(tx.get("to")),
            "gas_used":tx.get("gas_used"),"fee":tx.get("fee")
        }
        print("TX:",json.dumps(item["receipt"],ensure_ascii=False),flush=True)
        status_str=str(receipt_status).lower()
        item["top_level_success"] = status_str in ("ok","success","1","true")
        if not item["top_level_success"]:
            print("WARNING: transaction not confirmed successful by 'status' field",flush=True)
    except Exception as exc:
        item["receipt_error"]=str(exc)[:300]
        print("RECEIPT INCONCLUSIVE:",item["receipt_error"],flush=True)

    try:
        trace=fetch("/transactions/"+tx_hash+"/raw-trace")
        swaps=list(walk_trace(trace))
        item["controller_swap_calls"]=swaps
        print("Controller V4 swaps in trace:",len(swaps),flush=True)
        for swap in swaps:
            print("TRACE CALL:",json.dumps(swap,ensure_ascii=False),flush=True)
        item["valid_target_swap"] = any(
            s["pool"]==POOL and s["token_in"]==USDT
            and Decimal(s["amount_in_raw"])==Decimal(1_000_000*10**6)
            and s.get("trace_error") is None
            for s in swaps
        )
    except Exception as exc:
        item["trace_error"]=str(exc)[:300]
        print("TRACE INCONCLUSIVE:",item["trace_error"],flush=True)

    transfers,complete,error=transfers_for_hash(tx_hash)
    item["transfer_index_complete"]=complete
    item["transfers_error"]=error
    item["transfer_records_seen"]=len(transfers)
    totals={"USDT":Decimal(0),"USDS":Decimal(0)}
    relevant=[]
    for t in transfers:
        pair=transfer_amount(t)
        if not pair:
            continue
        symbol, amount, token_address=pair
        from_addr=addr(t.get("from"))
        to_addr=addr(t.get("to"))
        if from_addr!=PROXY and to_addr!=PROXY:
            continue
        change=amount*(int(to_addr==PROXY)-int(from_addr==PROXY))
        totals[symbol]+=change
        relevant.append({
            "token":symbol,"amount":str(amount),"delta_proxy":str(change),
            "from":from_addr,"to":to_addr,
            "log_index":t.get("log_index"),
        })
    item["proxy_net_transfers"]={k:str(v) for k,v in totals.items()}
    item["proxy_transfer_details"]=relevant
    item["transfer_proof"]=(complete and totals["USDT"]<0 and totals["USDS"]>0)
    print("Proxy NET ERC20 transfers:",json.dumps(item["proxy_net_transfers"]),flush=True)
    print("Transfer records:",len(transfers),"complete:",complete,"error:",error,flush=True)
    print("TOP-LEVEL SUCCESS:",item.get("top_level_success"),flush=True)
    print("DECODED CALL VALID:",item.get("valid_target_swap"),flush=True)
    print("PROXY SENT USDT AND RECEIVED USDS:",item["transfer_proof"],flush=True)
    item["all_checks_pass"]=(
        bool(item.get("top_level_success")) and
        bool(item.get("valid_target_swap")) and item["transfer_proof"]
    )
    print("ALL CHECKS PASS:",item["all_checks_pass"],flush=True)
    results.append(item)
    time.sleep(0.35)

total=sum(bool(r.get("all_checks_pass")) for r in results)
print("\n=== RESUMO ===",flush=True)
print("Transactions fully validated:",total,"/",len(results),flush=True)
print("NOTE: transfer deltas cover the entire transaction, NOT solely an internal call.",flush=True)
print("NOTE: proven execution does NOT prove public mempool visibility, sandwich or novel bug.",flush=True)
with open("audit-output/pass365_actual_swaps.json","w") as f:
    json.dump({"results":results,"fully_validated":total},f,ensure_ascii=False,indent=2)
print("Report: audit-output/pass365_actual_swaps.json",flush=True)
print("NO TRANSACTION SENT.",flush=True)
