import CryptoKit
import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String       // "openclaw" | "user"
    var content: String    // plaintext after decrypt for v1; server's content for v0
    let ts: Double
    let source: String?    // "live_activity" | "chat" | "heartbeat"

    // Derived client-side: true when the agent sent this unprompted
    // (an assistant message preceded by another assistant message, or
    // the very first message in the thread if it's from the agent).
    var isProactive: Bool = false

    // Envelope fields — populated by the server for v1 items. We decrypt
    // them client-side via ContentEncryption and write the result back
    // into `content` before display.
    let v: Int?
    let body_ct: String?
    let nonce: String?
    let K_user: String?
    let K_enclave: String?
    let visibility: String?
    let owner_user_id: String?

    var isFromAgent: Bool { role == "openclaw" || role == "assistant" }
    var isFromOpenClaw: Bool { isFromAgent }  // backwards compat
    var isFromLiveActivity: Bool { source == "live_activity" }
    var date: Date { Date(timeIntervalSince1970: ts) }

    enum CodingKeys: String, CodingKey {
        case id, role, content, ts, source
        case v, body_ct, nonce, K_user, K_enclave, visibility, owner_user_id
        // isProactive is excluded — derived client-side, never from server JSON
    }

    /// True when the server stored this as a v1 ciphertext envelope that
    /// we haven't decrypted yet (content still empty).
    var isEncryptedEnvelope: Bool {
        (v ?? 0) >= 1 && body_ct != nil && content.isEmpty
    }

    /// Rebuild this message with plaintext `content` filled in by
    /// unsealing the envelope with the user's content private key.
    /// Returns `self` unchanged when this item isn't a v1 envelope.
    func decryptedIfNeeded(withUserSK sk: Curve25519.KeyAgreement.PrivateKey) -> ChatMessage {
        func fromB64(_ s: String?) -> Data? {
            guard let s = s else { return nil }
            return Data(base64Encoded: s)
        }
        guard isEncryptedEnvelope,
              let bodyCT = fromB64(body_ct),
              let nonceData = fromB64(nonce),
              let kUser = fromB64(K_user),
              let owner = owner_user_id
        else { return self }
        let envelope = ContentEncryption.Envelope(
            id: id, v: v ?? 1,
            ownerUserID: owner,
            visibility: (visibility == "local_only") ? .localOnly : .shared,
            bodyCT: bodyCT,
            nonce: nonceData,
            kUser: kUser,
            kEnclave: fromB64(K_enclave),
            enclavePKFingerprint: ""
        )
        do {
            let plaintext = try ContentEncryption.unseal(envelope, withUserSK: sk)
            let text = String(data: plaintext, encoding: .utf8) ?? ""
            var copy = self
            copy.content = text
            return copy
        } catch {
            print("[chat] unseal failed for id=\(id): \(error)")
            var copy = self
            copy.content = "[encrypted — decrypt failed]"
            return copy
        }
    }
}
