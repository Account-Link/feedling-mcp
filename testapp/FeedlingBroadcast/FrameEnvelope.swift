import CryptoKit
import Foundation

/// Frame-ingest E2E envelope builder for the broadcast extension.
///
/// Mirrors the wire format produced by
/// `FeedlingTest/ContentEncryption.swift` (chat/memory/identity path) so
/// the backend can apply the same decryption logic to frames as it does
/// to other content types. We re-implement the primitives here because
/// ContentEncryption.swift is in the main app target and adding it to
/// the broadcast extension's Sources build phase would bloat the 50 MB
/// memory-limited process with unrelated code (ContentEncryption carries
/// chat/memory decoders).
///
/// Wire format (matches ContentEncryption.Envelope.jsonBody):
///
///   {"envelope":{
///      "v":1,
///      "id": 16-byte hex,
///      "body_ct": base64(ChaCha20-Poly1305(K, nonce, frame_json, aad)),
///      "nonce":   base64(12-byte nonce),
///      "K_user":     base64(BoxSeal(K, user_content_pk)),
///      "K_enclave":  base64(BoxSeal(K, enclave_content_pk)),
///      "visibility": "shared",
///      "owner_user_id": <user_id>,
///      "enclave_pk_fpr": <hex fingerprint or "">
///   }}
///
/// Where AEAD AAD = "owner_user_id|v|id".utf8 — matches server.
/// Where BoxSeal = ek_pub(32) || ChaChaPoly(HKDF-SHA256(salt=empty,
///                                                     info="feedling-box-seal-v1"),
///                                         nonce=SHA256(ek_pub||recipient_pk)[:12], K)
enum FrameEnvelope {

    /// Read the three inputs we need from the App Group UserDefaults
    /// (written by the main app via FeedlingAPI.publishEnclaveKeysToAppGroup).
    /// Returns nil if any input is missing — caller should drop the
    /// frame in that case (backend rejects non-v1 ingest).
    struct Context {
        let userID: String
        let userContentPK: Curve25519.KeyAgreement.PublicKey
        let enclaveContentPK: Curve25519.KeyAgreement.PublicKey
    }

    static func loadContext() -> Context? {
        guard let defaults = UserDefaults(suiteName: SharedConfig.appGroupIdentifier) else { return nil }
        guard let userID = defaults.string(forKey: "feedling.userID"), !userID.isEmpty else { return nil }
        guard let userPKB64 = defaults.string(forKey: "feedling.userContentPublicKey"),
              let userPKData = Data(base64Encoded: userPKB64),
              let userPK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: userPKData) else { return nil }
        guard let enclavePKB64 = defaults.string(forKey: "feedling.enclaveContentPublicKey"),
              let enclavePKData = Data(base64Encoded: enclavePKB64),
              let enclavePK = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: enclavePKData) else { return nil }
        return Context(userID: userID, userContentPK: userPK, enclaveContentPK: enclavePK)
    }

    /// Build the `{"envelope": {...}}` dictionary suitable for
    /// `JSONSerialization.data(withJSONObject:)`. `plaintext` is
    /// typically `JSONEncoder().encode(IngestFramePayload)`.
    static func wrap(plaintext: Data, ctx: Context) -> [String: Any]? {
        let itemID = randomHexID(bytes: 16)
        var keyBytes = Data(count: 32)
        let ok = keyBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard ok == errSecSuccess else { return nil }
        let K = SymmetricKey(data: keyBytes)

        var nonceBytes = Data(count: 12)
        let nok = nonceBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
        guard nok == errSecSuccess else { return nil }
        let nonce = try? ChaChaPoly.Nonce(data: nonceBytes)
        guard let nonce = nonce else { return nil }

        let aad = "\(ctx.userID)|1|\(itemID)".data(using: .utf8) ?? Data()
        guard let box = try? ChaChaPoly.seal(plaintext, using: K, nonce: nonce, authenticating: aad) else { return nil }
        let bodyCT = box.ciphertext + box.tag

        guard let kUser = boxSeal(payload: keyBytes, recipientPK: ctx.userContentPK) else { return nil }
        guard let kEnclave = boxSeal(payload: keyBytes, recipientPK: ctx.enclaveContentPK) else { return nil }

        let env: [String: Any] = [
            "v": 1,
            "id": itemID,
            "body_ct": bodyCT.base64EncodedString(),
            "nonce": nonceBytes.base64EncodedString(),
            "K_user": kUser.base64EncodedString(),
            "K_enclave": kEnclave.base64EncodedString(),
            "visibility": "shared",
            "owner_user_id": ctx.userID,
            "enclave_pk_fpr": "",
        ]
        return ["envelope": env]
    }

    // MARK: - primitives

    /// HKDF-SHA256 + ChaChaPoly "box seal" — matches ContentEncryption.BoxSeal
    /// and backend enclave_app._box_seal_open_hkdf. Parameters:
    ///   salt  = empty
    ///   info  = "feedling-box-seal-v1"
    ///   nonce = first 12 bytes of SHA256(ek_pub || recipient_pub)
    /// Returns ek_pub(32) || ct || tag(16).
    private static func boxSeal(payload: Data, recipientPK: Curve25519.KeyAgreement.PublicKey) -> Data? {
        let ek = Curve25519.KeyAgreement.PrivateKey()
        let ekPub = ek.publicKey.rawRepresentation
        let recipientRaw = recipientPK.rawRepresentation
        guard let shared = try? ek.sharedSecretFromKeyAgreement(with: recipientPK) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("feedling-box-seal-v1".utf8),
            outputByteCount: 32
        )
        let nonceBytes = Data(SHA256.hash(data: ekPub + recipientRaw)).prefix(12)
        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes) else { return nil }
        guard let box = try? ChaChaPoly.seal(payload, using: key, nonce: nonce) else { return nil }
        return ekPub + box.ciphertext + box.tag
    }

    private static func randomHexID(bytes: Int) -> String {
        var b = Data(count: bytes)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
