"""8-row audit against the live Phala CVM, mirroring iOS AuditCardView.

Rows 1-6 are structural: the quote parses, measurements look real, the
compose_hash is authorized on-chain, and the event log + mr_config_id
both bind the claimed compose_hash into the quote. Row 7 (Phase 3) pins
the attestation-port TLS cert: sha256(DER) of the cert the TLS handshake
presents must match `enclave_tls_cert_fingerprint_hex` in the
attestation. Row 8 (Phase C.2) checks the MCP port cert:
  - The MCP server presents a Let's Encrypt cert for mcp.feedling.app.
  - The cert was signed using a key derived from dstack-KMS at
    'feedling-mcp-tls-v1' inside the CVM.
  - The attestation bundle now includes mcp_tls_cert_pubkey_fingerprint_hex
    = sha256(SubjectPublicKeyInfo DER of that key).
  - We verify: cert is CA-valid for mcp.feedling.app AND its pubkey
    fingerprint matches the attested value.
  - Fingerprint is STABLE across LE renewals (key doesn't change, cert does).

Expected usage:

    FEEDLING_ATTESTATION_URL=https://<app-id>-5003s.dstack-pha-prod5.phala.network/attestation
    # Fetch the bundle ignoring the self-signed cert (we pin separately):
    curl -sk "$FEEDLING_ATTESTATION_URL" > /tmp/fl_cvm_attest.json
    python3 tools/audit_live_cvm.py
"""
import json, os, sys, hashlib, socket, ssl, subprocess
from urllib.parse import urlparse
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

# Row 7: TLS cert presented by the endpoint is bound to the attestation.
# sha256(DER) of the cert returned by the live TLS handshake must equal
# `enclave_tls_cert_fingerprint_hex` in the bundle. If the bundle still
# carries the all-zeros placeholder, TLS is terminated outside the
# enclave (pre-Phase-3 deploy) and we surface that explicitly — it's
# not a pass, it's a disclosure.
attested_tls = att.get("enclave_tls_cert_fingerprint_hex", "").lower()
zeros = "0" * 64
url = os.environ.get(
    "FEEDLING_ATTESTATION_URL",
    "https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation",
)
if attested_tls == zeros:
    row(7, "TLS cert bound to attestation", False,
        f"enclave_tls_cert_fingerprint_hex = all zeros\n"
        f"=> TLS terminated by dstack-gateway, not the enclave.\n"
        f"=> Trust model requires trusting the gateway operator.")
else:
    try:
        parsed = urlparse(url)
        host, port = parsed.hostname, parsed.port or 443
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # we pin, we don't CA-verify
        with socket.create_connection((host, port), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                der = s.getpeercert(binary_form=True)
        live_sha = hashlib.sha256(der).hexdigest()
        match = live_sha == attested_tls
        row(7, "TLS cert bound to attestation",
            match,
            f"attested sha256(cert.DER) = {attested_tls[:32]}…\n"
            f"live     sha256(cert.DER) = {live_sha[:32]}…\n"
            f"=> {'MATCH: TLS handshake reached the attested enclave, no MITM.' if match else 'MISMATCH: handshake was intercepted between you and the enclave.'}")
    except Exception as e:
        row(7, "TLS cert bound to attestation", False, f"TLS fetch failed: {e}")

# Row 8: MCP port (5002) has a Let's Encrypt cert whose key is bound to attestation.
# Phase C.2: MCP acquires an LE cert via ACME-DNS-01 inside the CVM.
# The cert key is derived from dstack-KMS at 'feedling-mcp-tls-v1' — stable key,
# only the CA-signed wrapper changes on renewal. The attestation bundle includes
# mcp_tls_cert_pubkey_fingerprint_hex = sha256(SubjectPublicKeyInfo DER of that key).
# We verify: (a) cert is CA-valid for mcp.feedling.app; (b) pubkey fingerprint matches.
attested_mcp_pk = att.get("mcp_tls_cert_pubkey_fingerprint_hex", "")
if not attested_mcp_pk:
    row(8, "MCP TLS cert (Let's Encrypt, key in CVM)", False,
        "skipped — mcp_tls_cert_pubkey_fingerprint_hex not in attestation bundle "
        "(pre-Phase-C.2 deployment)")
else:
    mcp_url_env = os.environ.get(
        "FEEDLING_MCP_URL",
        "https://051a174f2457a6c474680a5d745372398f97b6ad-5002s.dstack-pha-prod5.phala.network/",
    )
    try:
        parsed = urlparse(mcp_url_env)
        host, port = parsed.hostname, parsed.port or 443
        # Phala's dstack-gateway routes based on SNI: the SNI must match
        # the CVM's own `-PORTs.*.phala.network` hostname or the gateway
        # drops the TCP connection before the TLS handshake reaches the
        # CVM. So we fetch the cert chain via `openssl s_client` using
        # `host` as the SNI (gateway-friendly), then verify the leaf
        # manually against mcp.feedling.app with the system CA bundle.
        proc = subprocess.run(
            ["openssl", "s_client", "-servername", host, "-showcerts",
             "-connect", f"{host}:{port}"],
            input="", capture_output=True, text=True, timeout=20,
        )
        out = proc.stdout
        # Extract all PEM certs in the order the server sent them.
        pem_blocks = []
        in_block = False; cur = []
        for ln in out.splitlines():
            if "BEGIN CERTIFICATE" in ln:
                in_block = True; cur = [ln]
            elif "END CERTIFICATE" in ln and in_block:
                cur.append(ln); pem_blocks.append("\n".join(cur) + "\n"); in_block = False
            elif in_block:
                cur.append(ln)
        if not pem_blocks:
            raise RuntimeError(f"no certs in openssl output: {proc.stderr[:400]}")
        from cryptography import x509 as _x509
        from cryptography.hazmat.primitives import serialization as _ser
        from cryptography.x509.verification import PolicyBuilder, Store
        import datetime as _dt
        chain = [_x509.load_pem_x509_certificate(p.encode()) for p in pem_blocks]
        leaf = chain[0]; intermediates = chain[1:]
        der = leaf.public_bytes(_ser.Encoding.DER)
        # Build trust store from certifi if present, else openssl's default.
        try:
            import certifi as _certifi
            ca_path = _certifi.where()
        except ImportError:
            ca_path = ssl.get_default_verify_paths().cafile
        with open(ca_path, "rb") as f:
            trust_roots = _x509.load_pem_x509_certificates(f.read())
        store = Store(trust_roots)
        builder = PolicyBuilder().store(store).time(_dt.datetime.now(_dt.timezone.utc))
        verifier = builder.build_server_verifier(_x509.DNSName("mcp.feedling.app"))
        verifier.verify(leaf, intermediates)  # raises VerificationError on failure
        pub_der = leaf.public_key().public_bytes(_ser.Encoding.DER, _ser.PublicFormat.SubjectPublicKeyInfo)
        live_pk_fp = hashlib.sha256(pub_der).hexdigest()
        pk_match = live_pk_fp == attested_mcp_pk
        row(8, "MCP TLS cert (Let's Encrypt, key in CVM)",
            pk_match,
            f"attested pubkey fp = {attested_mcp_pk[:32]}…\n"
            f"live     pubkey fp = {live_pk_fp[:32]}…\n"
            f"cert CA-verified for mcp.feedling.app: yes (Let's Encrypt chain)\n"
            f"=> {'MATCH: LE cert key is inside the attested CVM.' if pk_match else 'MISMATCH: pubkey fingerprint differs from attested.'}")
    except Exception as e:
        etype = type(e).__name__
        if "Verification" in etype:
            row(8, "MCP TLS cert (Let's Encrypt, key in CVM)", False,
                f"CA verification failed: {e}\n"
                f"=> MCP cert is not a valid Let's Encrypt cert for mcp.feedling.app")
        else:
            row(8, "MCP TLS cert (Let's Encrypt, key in CVM)", False,
                f"TLS fetch failed: {etype}: {e}")

# Summary
passed = sum(1 for v in rows.values() if v)
total = len(rows)
print()
print(f"===== {passed}/{total} rows green — {'ALL PASS' if passed==total else 'FAILED: '+str([n for n,v in rows.items() if not v])} =====")
sys.exit(0 if passed==total else 1)
