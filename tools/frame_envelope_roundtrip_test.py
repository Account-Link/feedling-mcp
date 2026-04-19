"""Simulate what the broadcast extension does — send a v1 frame
envelope over the WebSocket ingest port, read it back via /v1/screen/frames/<n>
and verify the envelope stored with encrypted=true."""
import asyncio, base64, json, secrets, urllib.request
import websockets
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

# Register a test user
ident = X25519PrivateKey.generate()
idpk = base64.b64encode(ident.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
r = urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:5001/v1/users/register",
    data=json.dumps({"public_key": idpk, "platform": "test"}).encode(),
    headers={"Content-Type": "application/json"}, method="POST"))
d = json.loads(r.read())
user_id, api_key = d["user_id"], d["api_key"]
print("test user:", user_id)

# Enclave content pk (local)
att = json.loads(urllib.request.urlopen("http://127.0.0.1:5003/attestation").read())
enc_pk = X25519PublicKey.from_public_bytes(bytes.fromhex(att["enclave_content_pk_hex"]))

# User content keypair
user_sk = X25519PrivateKey.generate()
user_pk = user_sk.public_key()

# Plaintext = a mini "frame" JSON, simulating what iOS IngestFramePayload encodes to
frame_json = json.dumps({
    "type": "frame", "ts": 1776619999.0,
    "app": "com.apple.Safari", "ocr_text": "hello from an encrypted frame test",
    "image": base64.b64encode(b"FAKE_JPEG_BYTES").decode(),
    "w": 960, "h": 540
}).encode()

# Build v1 envelope (matches FrameEnvelope.swift format)
item_id = secrets.token_hex(16)
K = secrets.token_bytes(32)
nonce = secrets.token_bytes(12)
aad = f"{user_id}|1|{item_id}".encode()
body_ct = ChaCha20Poly1305(K).encrypt(nonce, frame_json, aad)

def box_seal(pt, rpk):
    ek = X25519PrivateKey.generate()
    ekp = ek.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    shared = ek.exchange(rpk)
    rraw = rpk.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=ekp+rraw,
               info=b"feedling-box-seal-v1").derive(shared)
    ct = ChaCha20Poly1305(key).encrypt(b"\x00"*12, pt, None)
    return ekp + ct

k_user = box_seal(K, user_pk)
k_enc = box_seal(K, enc_pk)

wire = {
    "type": "frame",
    "ts": 1776619999.0,
    "envelope": {
        "v": 1, "id": item_id,
        "body_ct": base64.b64encode(body_ct).decode(),
        "nonce": base64.b64encode(nonce).decode(),
        "K_user": base64.b64encode(k_user).decode(),
        "K_enclave": base64.b64encode(k_enc).decode(),
        "visibility": "shared",
        "owner_user_id": user_id,
        "enclave_pk_fpr": "",
    }
}

async def send_it():
    uri = "ws://127.0.0.1:9998/ingest"
    async with websockets.connect(uri, additional_headers={"Authorization": f"Bearer {api_key}"}) as ws:
        await ws.send(json.dumps(wire))
        await asyncio.sleep(1.0)
        print("sent. item_id=", item_id)

asyncio.run(send_it())

# Verify via list endpoint
r = urllib.request.urlopen(urllib.request.Request(
    "http://127.0.0.1:5001/v1/screen/frames",
    headers={"X-API-Key": api_key}))
frames = json.loads(r.read()).get("frames", [])
print("list returned", len(frames), "frame(s)")
match = [f for f in frames if f.get("id") == item_id or f.get("filename","").startswith(item_id)]
if match:
    f = match[0]
    print("✅ frame stored")
    print("    encrypted =", f.get("encrypted"))
    print("    filename =", f.get("filename"))
    print("    owner_user_id =", f.get("owner_user_id"))
else:
    print("✗ frame not found")
    print("raw:", json.dumps(frames[-1], indent=2) if frames else "no frames")
