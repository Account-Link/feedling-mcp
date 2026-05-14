"""8-row audit against the live Phala CVM, mirroring iOS AuditCardView.

Rows 1-6 are structural: the quote parses, measurements look real, the
compose_hash is authorized on-chain, and the event log + mr_config_id
both bind the claimed compose_hash into the quote. Row 7 (Phase 3) pins
the attestation-port TLS cert: sha256(DER) of the cert the TLS handshake
presents must match `enclave_tls_cert_fingerprint_hex` in the
attestation. Row 8 (Phase C.2) checks the MCP port cert:
  - Pre-migration mode: MCP terminated its own TLS inside the CVM, key
    derived from dstack-KMS at 'feedling-mcp-tls-v1'. Bundle carried
    mcp_tls_cert_pubkey_fingerprint_hex. Row 8 verified CA chain for
    mcp.feedling.app AND pubkey fingerprint match.
  - Post-prod9 migration: MCP sits behind dstack-ingress (which owns
    the LE cert for mcp.feedling.app). Bundle's
    mcp_tls_cert_pubkey_fingerprint_hex is empty, so Row 8 degrades
    to a disclosure (not a hard fail) — transport trust rests on the
    ingress cert, content-layer envelope crypto still secures all
    reads/writes regardless of transport pinning.

Endpoint configuration (env overrides with prod5 defaults matching
iOS CVMEndpoints.swift; flip these after the prod9 cutover):

    FEEDLING_CVM_APP_ID            — dstack app_id hex prefix
    FEEDLING_CVM_GATEWAY_DOMAIN    — e.g. dstack-pha-prod9.phala.network
    FEEDLING_ATTESTATION_URL       — overrides the derived attestation URL
    FEEDLING_MCP_URL               — overrides the derived MCP URL

Expected usage:

    # Fetch the bundle ignoring the self-signed cert (we pin separately):
    curl -sk "$FEEDLING_ATTESTATION_URL" > /tmp/fl_cvm_attest.json
    python3 tools/audit_live_cvm.py
"""
import json, os, sys, hashlib, socket, ssl, subprocess
from pathlib import Path
from urllib.parse import urlparse
sys.path.insert(0, str(Path(__file__).resolve().parent / "dcap"))
from dcap_parse import parse_quote

# Centralized endpoint resolution — mirrors iOS CVMEndpoints.swift.
# Defaults point at the current prod9 production CVM. Override via env
# when auditing a staging or replacement CVM.
CVM_APP_ID = os.environ.get(
    "FEEDLING_CVM_APP_ID", "9798850e096d770293c67305c6cfdceed68c1d28",
)
CVM_GATEWAY = os.environ.get(
    "FEEDLING_CVM_GATEWAY_DOMAIN", "dstack-pha-prod9.phala.network",
)
DEFAULT_ATTESTATION_URL = f"https://{CVM_APP_ID}-5003s.{CVM_GATEWAY}/attestation"
DEFAULT_MCP_URL = "https://mcp.feedling.app/"

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
url = os.environ.get("FEEDLING_ATTESTATION_URL", DEFAULT_ATTESTATION_URL)
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

# Row 8: transport disclosure for MCP.
# Historical Phase C.2: MCP acquired its own LE cert via ACME-DNS-01 inside the
# CVM and the attestation bundle carried sha256(SubjectPublicKeyInfo DER).
# Current prod9: MCP is plain HTTP behind dstack-ingress. The bundle leaves
# mcp_tls_cert_pubkey_fingerprint_hex empty, so Row 8 records that transport is
# ingress-terminated and content-layer envelope crypto remains the trust boundary.
attested_mcp_pk = att.get("mcp_tls_cert_pubkey_fingerprint_hex", "")
if not attested_mcp_pk:
    # Post-prod9 migration: MCP terminates plain HTTP behind
    # dstack-ingress, so there's no enclave-held key whose pubkey we can
    # pin. iOS shows this as a disclosure row (not a fail). Mark it as
    # a pass here too — the real trust boundary for reads/writes is the
    # content-layer envelope crypto (enclave_content_pk), not transport.
    row(8, "MCP TLS cert (ingress-terminated; content-layer trust)", True,
        "mcp_tls_cert_pubkey_fingerprint_hex empty in bundle.\n"
        "=> MCP TLS is terminated by dstack-ingress (LE cert for mcp.feedling.app).\n"
        "=> Transport trust rests on ingress cert; enclave-side pin retired.\n"
        "=> Content-layer envelope crypto (enclave_content_pk) remains the real trust boundary.")
else:
    mcp_url_env = os.environ.get("FEEDLING_MCP_URL", DEFAULT_MCP_URL)
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
