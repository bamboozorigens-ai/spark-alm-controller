#!/usr/bin/env python3
"""
PASSO 376 - Identify live OTC exchange configurations to prioritize a new
security vector. Historical role revocation from PASSO 375 was successful.
Only public Blockscout GETs + optional read-only Ethereum JSON-RPC eth_call.
No keys, no transactions, no token transfer, no RPC log filters.

The blockscout log scan is BOUNDED and may be incomplete. The script will
NOT label an exchange as unconfigured merely because no events were found.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

BLOCKSCOUT = "https://eth.blockscout.com/api/v2"
RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
CONTROLLERS = [
    ("CURRENT", "0xc953972cd006d1f12686fd7185c6d443b15900cd"),
    ("RETIRED", "0x5c46fc65855c0c7465a1ea85eea0b24b601502d3"),
]
EVENT_SIGNATURES = {
    "OTCBufferSet": "OTCBufferSet(address,address,address)",
    "OTCWhitelistedAssetSet": "OTCWhitelistedAssetSet(address,address,bool)",
    "OTCRechargeRateSet": "OTCRechargeRateSet(address,uint256,uint256)",
    "MaxSlippageSet": "MaxSlippageSet(address,uint256)",
}
PAGE_CAP = int(os.getenv("OTC_LOG_PAGE_CAP", "4"))
MAX_EXCHANGES = int(os.getenv("OTC_MAX_EXCHANGES", "16"))
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
USDS = "0xdc035d45d973e3ec169d2276ddab16f1e407384f"

def get_json(url):
    req = urllib.request.Request(
        url, headers={"Accept":"application/json","User-Agent":"SparkReadOnlyAuditor/376"}
    )
    last = None
    for retry in range(3):
        try:
            with urllib.request.urlopen(req, timeout=28) as res:
                return json.load(res)
        except (urllib.error.URLError, ValueError, TimeoutError) as ex:
            last = str(ex)
            if retry < 2:
                time.sleep(retry + 1)
    raise RuntimeError(last or "Failed GET")

def keccak_topic(signature):
    p = subprocess.run(["cast","keccak",signature],capture_output=True,text=True,timeout=15)
    if p.returncode != 0:
        raise RuntimeError("cast keccak failed: " + p.stderr[:250])
    value = p.stdout.strip().lower()
    if len(value) != 66:
        raise RuntimeError("Invalid event topic " + value)
    return value

def decode_address(topic):
    return "0x" + str(topic)[-40:].lower()

def scan_event(controller, name, topic):
    seen = set()
    cursor = {}
    matches = []
    complete = False
    error = None
    fetched = 0
    for page in range(PAGE_CAP):
        signature = json.dumps(cursor,sort_keys=True)
        if signature in seen:
            error = "Repeated cursor"
            break
        seen.add(signature)
        params = {"topic":topic}
        for key,value in cursor.items():
            if value is not None and not isinstance(value,bool) and key != "include_zero_value":
                params[key]=value
        url = BLOCKSCOUT + "/addresses/" + controller + "/logs?" + urllib.parse.urlencode(params)
        try:
            data = get_json(url)
            items = data.get("items") or []
            if not isinstance(items,list):
                raise RuntimeError("Unexpected logs response")
            fetched += len(items)
            for item in items:
                fields = item.get("topics") or []
                if not fields or str(fields[0]).lower() != topic:
                    continue
                result = {
                    "controller": controller, "name": name,
                    "block": item.get("block_number"),
                    "tx_hash": item.get("transaction_hash"),
                    "log_index": item.get("index"),
                    "indexed_addresses": [
                        decode_address(x) for x in fields[1:3]
                    ],
                    "data": item.get("data")
                }
                matches.append(result)
            next_params = data.get("next_page_params")
            if not next_params:
                complete=True
                break
            cursor={k:v for k,v in next_params.items()
                    if v is not None and not isinstance(v,bool)
                    and k!="include_zero_value"}
            if not cursor:
                error="Empty next cursor"
                break
        except Exception as ex:
            error = str(ex)[:330]
            break
        time.sleep(0.12)
    if not complete and not error:
        error = "Page cap reached; older events may not be indexed in this report"
    return {
        "events":matches,
        "complete":complete,
        "error":error,
        "items_considered":fetched
    }

def cast_call(contract, signature, *arguments):
    cmd=["cast","call",contract,signature,*arguments,"--rpc-url",RPC]
    try:
        run=subprocess.run(cmd,capture_output=True,text=True,timeout=38)
        if run.returncode != 0:
            return {"error":run.stderr.strip()[:260]}
        return {"value":run.stdout.strip()[:1000]}
    except Exception as ex:
        return {"error":str(ex)[:260]}

def inventory(exchange):
    current=CONTROLLERS[0][1]
    data = {"exchange": exchange}
    data["current_otc_state"]=cast_call(
        current,"otcs(address)(address,uint256,uint256,uint256,uint256)",exchange
    )
    data["current_max_slippage"]=cast_call(
        current,"maxSlippages(address)(uint256)",exchange
    )
    for symbol,token in [("USDT",USDT),("USDS",USDS)]:
        data[symbol+"_whitelisted"]=cast_call(
            current,"otcWhitelistedAssets(address,address)(bool)",exchange,token
        )
    data["current_otc_ready"]=cast_call(
        current,"isOtcSwapReady(address)(bool)",exchange
    )
    return data

print("=== PASSO 376: LIVE OTC EXCHANGE INVENTORY ===",flush=True)
print("Source: Blockscout controller-event logs + read-only view calls",flush=True)
print("Each event scan max pages:",PAGE_CAP,flush=True)
topics={k:keccak_topic(v) for k,v in EVENT_SIGNATURES.items()}
print("Topics:",json.dumps(topics),flush=True)

scans={}
exchange_addresses=set()
for kind,contract in CONTROLLERS:
    for name,topic in topics.items():
        key=kind+":"+name
        result=scan_event(contract,name,topic)
        scans[key]=result
        print(key,"matched:",len(result["events"]),
              "scanned_items:",result["items_considered"],
              "complete:",result["complete"],
              "error:",result["error"],flush=True)
        for row in result["events"]:
            first=row["indexed_addresses"]
            if not first:
                continue
            exchange=first[0]
            if exchange == "0x" + "0"*40:
                continue
            exchange_addresses.add(exchange)
        time.sleep(0.15)

discovered=sorted(exchange_addresses)
print("Distinct exchange / pool addresses found:",len(discovered),flush=True)
print("NOTE: MaxSlippageSet may identify pools OTHER than OTC exchanges.",flush=True)
if len(discovered)>MAX_EXCHANGES:
    print("Limited to first",MAX_EXCHANGES,
        "candidate addresses (sort order is NOT ranking).",flush=True)
config=[]
for exchange in discovered[:MAX_EXCHANGES]:
    entry=inventory(exchange)
    config.append(entry)
    print("Exchange candidate",exchange,flush=True)
    print(" ",json.dumps(entry,ensure_ascii=False),flush=True)
    time.sleep(0.1)

report={
    "description":"Bounded discovery only; no configuration claim if scan incomplete",
    "topics":topics,
    "event_scans":scans,
    "candidates":config,
    "candidate_count":len(discovered),
    "limitations":[
        "Blockscout API indexing/pagination and topic filtering may vary.",
        "Events may be older than page caps; absence of events does not mean no OTC.",
        "MaxSlippageSet includes addresses of Curve pools or other integrations.",
        "Successful read-only calls reflect latest state and do not establish exploitability.",
        "No token movement, no contract writes and no transaction broadcasting."
    ]
}
with open("audit-output/pass376_otc_inventory.json","w") as f:
    json.dump(report,f,indent=2,ensure_ascii=False)
print("Saved: audit-output/pass376_otc_inventory.json",flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
