import CryptoKit
import Foundation

/// A chat message — text by default, optionally an image. Per server spec,
/// `content_type` is plaintext metadata: it tells the renderer whether the
/// decrypted bytes are UTF-8 text or a JPEG image. The envelope itself is
/// the same opaque bytes either way.
enum ChatContentType: String, Codable {
    case text
    case image
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String       // "openclaw" | "user"
    var content: String    // plaintext text after decrypt; empty for images
    /// Decrypted JPEG bytes when content_type == .image. Populated client-side
    /// by `decryptedIfNeeded`; never sent over the wire.
    var imageData: Data? = nil
    let ts: Double
    let source: String?    // "live_activity" | "chat" | "heartbeat"
    /// Plaintext server-supplied tag. Defaults to .text for legacy messages
    /// that pre-date the field.
    var contentType: ChatContentType = .text

    // Derived client-side: true when the agent sent this unprompted
    // (an assistant message preceded by another assistant message, or
    // the very first message in the thread if it's from the agent).
    var isProactive: Bool = false

    // Envelope fields — populated by the server for v1 items. We decrypt
    // them client-side via ContentEncryption and write the result back
    // into `content` (text) or `imageData` (image) before display.
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
        case contentType = "content_type"
        // isProactive, imageData are derived client-side, never from server JSON
    }

    init(
        id: String,
        role: String,
        content: String,
        ts: Double,
        source: String?,
        contentType: ChatContentType = .text,
        imageData: Data? = nil,
        v: Int? = nil,
        body_ct: String? = nil,
        nonce: String? = nil,
        K_user: String? = nil,
        K_enclave: String? = nil,
        visibility: String? = nil,
        owner_user_id: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.ts = ts
        self.source = source
        self.contentType = contentType
        self.imageData = imageData
        self.v = v
        self.body_ct = body_ct
        self.nonce = nonce
        self.K_user = K_user
        self.K_enclave = K_enclave
        self.visibility = visibility
        self.owner_user_id = owner_user_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self, forKey: .id)
        role          = try c.decode(String.self, forKey: .role)
        content       = (try? c.decode(String.self, forKey: .content)) ?? ""
        ts            = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        source        = try? c.decode(String.self, forKey: .source)
        contentType   = (try? c.decode(ChatContentType.self, forKey: .contentType)) ?? .text
        v             = try? c.decode(Int.self, forKey: .v)
        body_ct       = try? c.decode(String.self, forKey: .body_ct)
        nonce         = try? c.decode(String.self, forKey: .nonce)
        K_user        = try? c.decode(String.self, forKey: .K_user)
        K_enclave     = try? c.decode(String.self, forKey: .K_enclave)
        visibility    = try? c.decode(String.self, forKey: .visibility)
        owner_user_id = try? c.decode(String.self, forKey: .owner_user_id)
        imageData = nil
    }

    /// True when the server stored this as a v1 ciphertext envelope that
    /// we haven't decrypted yet (content still empty AND no image cached).
    var isEncryptedEnvelope: Bool {
        let hasV1Envelope = (v ?? 0) >= 1 && body_ct != nil
        let hasNothingDecrypted = content.isEmpty && imageData == nil
        return hasV1Envelope && hasNothingDecrypted
    }

    /// Rebuild this message with plaintext content filled in by unsealing
    /// the envelope with the user's content private key.
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
            var copy = self
            switch contentType {
            case .image:
                // Keep raw JPEG bytes — UI builds UIImage on demand.
                copy.imageData = plaintext
                copy.content = ""
            case .text:
                copy.content = String(data: plaintext, encoding: .utf8) ?? ""
            }
            return copy
        } catch {
            print("[chat] unseal failed for id=\(id) type=\(contentType): \(error)")
            var copy = self
            copy.content = "[encrypted — decrypt failed]"
            return copy
        }
    }
}
