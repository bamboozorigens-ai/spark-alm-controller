#!/usr/bin/env python3
"""
PASSO 387 -- Direct, read-only current V4 inventory of 3 historical Spark pools.

Current state of three FULL pool IDs already identified in earlier tests and
historical transaction analysis. These IDs are NOT invented; see:
  test/audit/scan_spark_swap_history.py
  test/audit/SparkFundedSwapSandwich.t.sol
  test/audit/pass368_block_mev_review.py

Earlier swaps were executed by a prior controller. These IDs must be
revalidated independently against the CURRENT controller and position manager.
Bypass previously timed-out Blockscout event searches entirely.
Each latest-state eth_call is independent; retry transient RPC failures.
If the RPC still fails, report INCONCLUSIVE, not a contract finding.

Pure read calls only. No credentials, transactions, token movements,
Cheatcodes, signing, forks, simulated attacks, or transaction broadcasts.
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

RPC = os.getenv("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
CONTROLLER = "0xc953972cd006d1f12686fd7185c6d443b15900cd"
LIMITS = "0x7a5fd5cf045e010e62147f065ceae59e5344b188"
PROXY = "0x1601843c5e9bc251a3272907010afa41fa18347e"
POSITION_MANAGER = "0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e"
STATE_VIEW = "0x7ffe42c4a5deea5b0fec41c94c136cf115597227"
API = "https://eth.blockscout.com/api/v2"
KNOWN_POOL_IDS = {
    "Prior Spark audit: RLUSD / USDS":
        "0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f",
    "Prior Spark audited transaction: USDT / USDS":
        "0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9",
    "Prior Spark audit: PYUSD / USDS":
        "0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45",
}

TOKENS = {
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "USDC",
    "0xdac17f958d2ee523a2206206994597c13d831ec7": "USDT",
    "0xdc035d45d973e3ec169d2276ddab16f1e407384f": "USDS",
    "0x8292bb45bf1ee4d140127049757c2e0ff06317ed": "RLUSD",
    "0x6c3ea9036406852006290770bedfcaba0e23a0e8": "PYUSD",
    "0x0000000000000000000000000000000000000000": "ETH",
}
ROOT_LABELS = {
    "SWAP": "LIMIT_UNISWAP_V4_SWAP",
    "DEPOSIT": "LIMIT_UNISWAP_V4_DEPOSIT",
    "WITHDRAW": "LIMIT_UNISWAP_V4_WITHDRAW",
}
MAX_PAGES = int(os.getenv("V4_EVENT_PAGE_CAP", "2"))
MAX_IDS = int(os.getenv("V4_POOL_ID_CAP", "12"))
READ_RETRIES = max(1, int(os.getenv("V4_RPC_RETRIES", "2")))
TIMEOUT = max(5, int(os.getenv("V4_RPC_TIMEOUT", "16")))
ONCHAIN_CALLS = 0
RPC_ERRORS = []

def run_cast(*args):
    try:
        p = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=18)
        if p.returncode:
            raise RuntimeError((p.stderr or p.stdout).strip()[:300])
        return p.stdout.strip()
    except Exception as exc:
        raise RuntimeError("Local cast utility: " + str(exc)[:300]) from exc

def word(value):
    if not isinstance(value, int) or value < 0 or value.bit_length() > 256:
        raise ValueError("Invalid ABI uint256")
    return value.to_bytes(32, "big")

def decode_words(data):
    if not isinstance(data, (bytes, bytearray)) or len(data) % 32:
        raise ValueError("Malformed ABI response")
    return [int.from_bytes(data[i:i+32], "big") for i in range(0, len(data), 32)]

def addr_from_word(i):
    return "0x" + (i & ((1 << 160)-1)).to_bytes(20, "big").hex()

def signed24(word_value):
    raw = word_value & 0xffffff
    return raw - (1 << 24) if raw & (1 << 23) else raw

def selector(signature):
    out = run_cast("sig", signature).lower()
    if len(out) != 10 or not out.startswith("0x"):
        raise ValueError("Invalid selector: " + out)
    return out

def abi_data(signature, *abi_words):
    return selector(signature) + b"".join(abi_words).hex()

def rpc_eth_call(to, data, label):
    global ONCHAIN_CALLS
    ONCHAIN_CALLS += 1
    req_payload = json.dumps({
        "jsonrpc": "2.0", "id": 386,
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"]
    }).encode()
    last_error = None
    for attempt in range(READ_RETRIES):
        try:
            request = urllib.request.Request(
                RPC, data=req_payload, headers={
                    "Content-Type": "application/json",
                    "User-Agent": "SparkAuditReadOnly386"
                }
            )
            with urllib.request.urlopen(request, timeout=TIMEOUT) as res:
                decoded = json.load(res)
            if "error" in decoded:
                raise RuntimeError(str(decoded["error"])[:360])
            result = decoded.get("result")
            if not isinstance(result, str) or not result.startswith("0x"):
                raise ValueError("RPC returned invalid hex data")
            return bytes.fromhex(result[2:]), None
        except (urllib.error.URLError, RuntimeError, ValueError, TimeoutError) as ex:
            last_error = str(ex)[:360]
            if attempt + 1 < READ_RETRIES:
                time.sleep(0.4 + 0.6 * attempt)
    RPC_ERRORS.append({"label": label, "address": to, "error": last_error})
    return None, last_error

def read_u256(to, signature, args, label):
    data, err = rpc_eth_call(to, abi_data(signature, *args), label)
    if err:
        return None, err
    values = decode_words(data)
    if len(values) != 1:
        return None, "Unexpected 32-byte ABI response"
    return values[0], None

def read_tuple(to, signature, args, size, label):
    data, err = rpc_eth_call(to, abi_data(signature, *args), label)
    if err:
        return None, err, None
    values = decode_words(data)
    if len(values) != size:
        return None, f"Expected {size} ABI words; received {len(values)}", None
    return values, None, data

def keccak_hex(encoded):
    return run_cast("keccak", "0x" + encoded.hex()).lower()

def event_ids():
    """Unused helper retained from Passo 386; NEVER CALLED in this script."""
    topic = run_cast("keccak", "UniswapV4TickLimitsSet(bytes32,int24,int24,uint24)").lower()
    ids, cursor, visited = {}, {}, set()
    error = None
    complete = False
    for _ in range(MAX_PAGES):
        marker = json.dumps(cursor, sort_keys=True)
        if marker in visited:
            error = "Repeated cursor"
            break
        visited.add(marker)
        params = {"topic": topic}
        params.update({k: v for k, v in cursor.items()
                       if v is not None and not isinstance(v, bool)
                       and k != "include_zero_value"})
        url = API + "/addresses/" + CONTROLLER + "/logs?" + urllib.parse.urlencode(params)
        try:
            req = urllib.request.Request(
                url, headers={
                    "Accept": "application/json",
                    "User-Agent": "SparkAuditReadOnly386"
                }
            )
            with urllib.request.urlopen(req, timeout=14) as res:
                payload = json.load(res)
            for row in payload.get("items") or []:
                topics = row.get("topics") or []
                if len(topics) < 2 or str(topics[0]).lower() != topic:
                    continue
                candidate = str(topics[1]).lower()
                if len(candidate) != 66 or not candidate.startswith("0x"):
                    continue
                ids.setdefault(candidate, []).append({
                    "block": row.get("block_number"),
                    "tx": row.get("transaction_hash")
                })
            next_cursor = payload.get("next_page_params")
            if not next_cursor:
                complete = True
                break
            cursor = {k: v for k, v in next_cursor.items()
                      if v is not None and not isinstance(v, bool)
                      and k != "include_zero_value"}
            if not cursor:
                error = "Empty cursor"
                break
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as ex:
            error = str(ex)[:320]
            break
    if not complete and error is None:
        error = "Page cap reached; event history may be incomplete"
    return ids, complete, error

def limit_for(root, pool_id, name):
    key = keccak_hex(bytes.fromhex(root[2:] + pool_id[2:]))
    values, err, _ = read_tuple(
        LIMITS, "getRateLimitData(bytes32)", [bytes.fromhex(key[2:])], 4,
        name + ":getRateLimitData"
    )
    available, av_err = read_u256(
        LIMITS, "getCurrentRateLimit(bytes32)", [bytes.fromhex(key[2:])],
        name + ":getCurrentRateLimit"
    )
    if err:
        return {"key": key, "error": err, "available": available, "available_error": av_err}
    return {
        "key": key,
        "maxAmount18": values[0],
        "slope18PerSecond": values[1],
        "lastAmount18": values[2],
        "lastUpdated": values[3],
        "available18": available,
        "available_error": av_err,
        "enabled": values[0] > 0
    }

def inspect_pool(pool_id, source, roots):
    pool_id = pool_id.lower()
    print("\nPOOL", pool_id, "|", source, flush=True)

    # Solidity: address(uint160(uint256(poolId))) = last 20 bytes.
    suffix = "0x" + pool_id[-40:]
    slippage, slip_err = read_u256(
        CONTROLLER, "maxSlippages(address)",
        [b"\x00" * 12 + bytes.fromhex(suffix[2:])],
        pool_id + ":maxSlippages"
    )
    ticks, tick_err, _ = read_tuple(
        CONTROLLER, "uniswapV4TickLimits(bytes32)",
        [bytes.fromhex(pool_id[2:])], 3, pool_id + ":tickLimits"
    )
    tick_info = {
        "tickLowerMin": signed24(ticks[0]),
        "tickUpperMax": signed24(ticks[1]),
        "maxTickSpacing": ticks[2],
    } if ticks else {"error": tick_err}
    print("  Slippage suffix:", suffix, "value:", slippage, "error:", slip_err, flush=True)
    print("  Tick config:", tick_info, flush=True)

    # Solidity: bytes25(poolId) = FIRST 25 bytes padded with 7 zero bytes.
    prefix25 = bytes.fromhex(pool_id[2:])[:25]
    key_words, key_err, returned_key_data = read_tuple(
        POSITION_MANAGER, "poolKeys(bytes25)",
        [prefix25 + b"\x00" * 7], 5, pool_id + ":PositionManager.poolKeys"
    )
    pool_key = None
    if key_words:
        pool_key = {
            "currency0": addr_from_word(key_words[0]),
            "currency1": addr_from_word(key_words[1]),
            "fee": key_words[2],
            "tickSpacing": signed24(key_words[3]),
            "hooks": addr_from_word(key_words[4]),
        }
        recovered_id = keccak_hex(returned_key_data)
        pool_key["recomputedFullPoolId"] = recovered_id
        pool_key["id_matches"] = recovered_id == pool_id
        pool_key["token0_name"] = TOKENS.get(pool_key["currency0"], "OTHER")
        pool_key["token1_name"] = TOKENS.get(pool_key["currency1"], "OTHER")
        print("  PoolKey currencies:", pool_key["token0_name"],
              pool_key["token1_name"], flush=True)
        print("  PoolKey full ID matches:", pool_key["id_matches"], flush=True)
        # Proxy's live balances on BOTH pool currencies, for economic prioritization.
        pool_key["proxy_token_balances"] = {}
        for token_label in ("currency0", "currency1"):
            token_address = pool_key[token_label]
            if token_address == "0x" + "0" * 40:
                pool_key["proxy_token_balances"][token_label] = {"type": "native ETH", "balance": None}
                continue
            token_balance, balance_error = read_u256(
                token_address, "balanceOf(address)",
                [b"\x00" * 12 + bytes.fromhex(PROXY[2:])],
                pool_id + ":" + token_label + ":proxy_balance"
            )
            pool_key["proxy_token_balances"][token_label] = {
                "symbol": TOKENS.get(token_address, "OTHER"),
                "balance_native": token_balance,
                "error": balance_error
            }
            print(" ", token_label, TOKENS.get(token_address, "OTHER"),
                  "ALMProxy balance native:", token_balance, "error:", balance_error,flush=True)
        if not pool_key["id_matches"]:
            print("  WARNING: No matching registered PoolKey; swaps will fail poolId match.",flush=True)
    else:
        print("  PositionManager PoolKey INCONCLUSIVE:", key_err, flush=True)

    onchain_limits = {}
    for label, root in roots.items():
        if root is None:
            onchain_limits[label] = {"error": "Cannot read limit root"}
        else:
            onchain_limits[label] = limit_for(root, pool_id, pool_id + ":" + label)
        entry = onchain_limits[label]
        maximum = entry.get("maxAmount18")
        print(" ", label, "maximum normalized:",
              maximum, "available:", entry.get("available18"),
              "error:", entry.get("error"),flush=True)

    slot, slot_err, _ = read_tuple(
        STATE_VIEW, "getSlot0(bytes32)",
        [bytes.fromhex(pool_id[2:])], 4, pool_id + ":StateView.slot0"
    )
    liquidity, liquidity_err = read_u256(
        STATE_VIEW, "getLiquidity(bytes32)",
        [bytes.fromhex(pool_id[2:])], pool_id + ":StateView.liquidity"
    )
    market = {
        "sqrtPriceX96": slot[0] if slot else None,
        "tick": signed24(slot[1]) if slot else None,
        "protocolFee": slot[2] if slot else None,
        "lpFee": slot[3] if slot else None,
        "liquidity": liquidity,
        "slot0_error": slot_err,
        "liquidity_error": liquidity_err
    }
    print("  StateView tick:", market["tick"],
          "liquidity:", market["liquidity"],
          "error:", slot_err or liquidity_err, flush=True)
    return {
        "id": pool_id, "source": source,
        "slippage_suffix": suffix,
        "slippage_1e18": slippage, "slippage_error": slip_err,
        "tick_limits": tick_info,
        "pool_key": pool_key, "pool_key_error": key_err,
        "rate_limits": onchain_limits,
        "market": market
    }

print("=== PASSO 387: PREVIOUSLY AUDITED V4 POOLS, CURRENT CONTROLLER ===",flush=True)
print("No Foundry fork, no Blockscout, no transaction broadcasting.",flush=True)
print("RPC:", RPC.split("?")[0],flush=True)
print("Retries per eth_call:",READ_RETRIES,flush=True)

# No Blockscout calls: source is the three full IDs saved in prior audits.
discover, complete, discovery_error = {}, None, "Not requested (avoids timed-out Blockscout API)"
pool_ids = dict(KNOWN_POOL_IDS)  # label -> full bytes32 poolId
all_pairs = list(pool_ids.items())
if len(all_pairs) > MAX_IDS:
    print("LIMITED: selected",MAX_IDS,"of",len(all_pairs),"pool IDs",flush=True)
    all_pairs = all_pairs[:MAX_IDS]

roots = {}
for label, getter in ROOT_LABELS.items():
    root_value, err = read_u256(CONTROLLER, getter + "()", [], label+":root")
    roots[label] = ("0x" + word(root_value).hex()) if root_value is not None else None
    print(label,"limit root:",roots[label],"error:",err,flush=True)

result = []
for source, pool_id in all_pairs:
    result.append(inspect_pool(pool_id, source, roots))

summary = {
    "pools_analyzed": len(result),
    "pool_keys_matching_full_id": sum(
        x["pool_key"] is not None and x["pool_key"]["id_matches"] for x in result
    ),
    "pools_with_positive_swap_limit": sum(
        x["rate_limits"]["SWAP"].get("enabled") is True for x in result
    ),
    "pools_with_positive_deposit_limit": sum(
        x["rate_limits"]["DEPOSIT"].get("enabled") is True for x in result
    ),
    "pools_with_positive_withdraw_limit": sum(
        x["rate_limits"]["WITHDRAW"].get("enabled") is True for x in result
    ),
    "rpc_errors": len(RPC_ERRORS),
}
Path("audit-output").mkdir(exist_ok=True)
output = "audit-output/pass387_historical_v4_pool_current_state.json"
with open(output,"w") as f:
    json.dump({
        "purpose": "Identify real full Uniswap V4 pool IDs and live route limits without fork",
        "controller": CONTROLLER, "position_manager": POSITION_MANAGER,
        "known_pool_sources": KNOWN_POOL_IDS, "event_scan_complete": complete,
        "event_scan_error": discovery_error, "event_pool_ids": discover,
        "rate_limit_roots": roots, "pools": result, "summary": summary,
        "rpc_errors": RPC_ERRORS,
        "limitations": [
            "RPC latest eth_call may return state from different blocks across requests.",
            "An RPC error is not evidence of contract vulnerability.",
            "Only three verified full pool IDs from prior Spark audits were queried.",
            "No Blockscout event discovery was attempted; other live pools may exist.",
            "Positive rate limits mean governance configuration; they do not confer RELAYER role.",
            "Historical trading or prior-controller permissions do not imply current-controller enablement.",
            "No transactions were sent or signed."
        ]
    }, f, indent=2, ensure_ascii=False)
print("\n=== SUMMARY ===", flush=True)
for k, v in summary.items():
    print(k,":",v,flush=True)
print("Report:",output,flush=True)
print("NO TRANSACTIONS SENT.",flush=True)
