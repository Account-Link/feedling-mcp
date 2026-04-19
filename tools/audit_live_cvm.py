"""6-row audit against the live Phala CVM, mirroring iOS AuditCardView."""
import json, os, sys, hashlib, subprocess
sys.path.insert(0, "/Users/sxysun/Desktop/suapp/feedling-mcp-v1/tools/dcap")
from dcap_parse import parse_quote

att = json.load(open("/tmp/fl_cvm_attest.json"))
rows = {}

def row(n, title, ok, detail=""):
    mark = "✓" if ok else "✗"
    rows[n] = ok
    print(f"Row {n} [{mark}] {title}")
    if detail:
        for line in detail.strip().split("\n"):
            print(f"       {line}")

# Row 1: /attestation reachable
row(1, "/attestation reachable + valid JSON",
    bool(att.get("tdx_quote_hex") and att.get("event_log_json")),
    f"quote_hex={len(att.get('tdx_quote_hex',''))} chars, event_log={len(att.get('event_log_json',''))} chars")

# Row 2: Quote parses as TDX v4
try:
    q = parse_quote(bytes.fromhex(att["tdx_quote_hex"]))
    row(2, "TDX quote parses (v4, tee_type=0x81)",
        q.header.version == 4 and q.header.tee_type == 0x81,
        f"version={q.header.version} tee_type=0x{q.header.tee_type:x}\nmrtd={q.body.mrtd.hex()[:32]}...\nrtmr3={q.body.rtmr3.hex()[:32]}...")
except Exception as e:
    row(2, "TDX quote parses", False, str(e))

# Row 3: measurements look real
meas = att["measurements"]
mrtd = meas["mrtd"]; rtmr3 = meas["rtmr3"]; mrcfg = meas.get("mr_config_id","")
row(3, "measurements non-zero + mr_config_id flag set",
    mrtd != "0"*96 and rtmr3 != "0"*96 and mrcfg.startswith("01"),
    f"mrtd={mrtd[:32]}... rtmr3={rtmr3[:32]}...\nmr_config_id[0]=0x{mrcfg[:2]} (dstack compose-binding flag)")

# Row 4: compose_hash authorized on-chain
compose_hash = att["compose_hash"]
r = subprocess.run(["cast","call","--rpc-url",os.environ["ETH_SEPOLIA_RPC_URL"],
    os.environ["FEEDLING_APP_AUTH_CONTRACT"],
    "isAppAllowed(bytes32)(bool)", f"0x{compose_hash}"], capture_output=True, text=True, timeout=15)
row(4, "compose_hash authorized on FeedlingAppAuth (Eth Sepolia)",
    r.stdout.strip() == "true",
    f"isAppAllowed(0x{compose_hash[:16]}...) = {r.stdout.strip()}\ncontract = {os.environ['FEEDLING_APP_AUTH_CONTRACT']}")

# Row 5: mr_config_id binds THIS compose_hash into the quote
# dstack format: mr_config_id = 0x01 || compose_hash || zero-padding
if mrcfg.startswith("01") and len(mrcfg) >= 2+64:
    bound = mrcfg[2:2+64].lower() == compose_hash.lower()
    row(5, "mr_config_id binds this compose_hash directly",
        bound,
        f"mr_config_id[1:33] = {mrcfg[2:2+64]}\ncompose_hash       = {compose_hash}")
else:
    row(5, "mr_config_id binds this compose_hash directly", False, f"mrcfg={mrcfg}")

# Row 6: event_log contains matching compose-hash event (consistency check)
event_log = json.loads(att["event_log_json"])
hits = [e for e in event_log if e.get("event")=="compose-hash"]
payload = hits[0].get("event_payload","").lower() if hits else ""
row(6, "event_log contains compose-hash event with this compose_hash",
    compose_hash.lower() in payload,
    f"event_payload = {payload}")

# Summary
passed = sum(1 for v in rows.values() if v)
print()
print(f"===== {passed}/6 rows green — {'ALL PASS' if passed==6 else 'FAILED: '+str([n for n,v in rows.items() if not v])} =====")
sys.exit(0 if passed==6 else 1)
