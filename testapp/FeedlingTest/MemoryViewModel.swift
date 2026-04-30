import CryptoKit
import Foundation

/// A memory garden moment. Decodes server responses that may be either v0
/// (plaintext title/description/type) or v1 (envelope with body_ct wrapping
/// {title, description, type} as JSON). iOS decrypts v1 client-side using
/// the user's content private key.
struct MemoryMoment: Codable, Identifiable, Hashable {
    let id: String
    var type: String
    var title: String
    var description: String
    let occurredAt: String
    let createdAt: String
    let source: String

    // Optional display fields — written by the agent into the encrypted body
    var herQuote: String?           // exact words spoken that night
    var context: String?            // e.g. "late-night work"
    var linkedDimension: String?    // e.g. "克制 ↑"
    var quotedInChat: Int?          // how many times this card was quoted in chat

    // v1 envelope fields — present when the server stored ciphertext.
    let v: Int?
    let body_ct: String?
    let nonce: String?
    let K_user: String?
    let K_enclave: String?
    let visibility: String?
    let owner_user_id: String?

    // True when this moment was created today
    var isFresh: Bool {
        guard let date = occurredDate else { return false }
        return Calendar.current.isDateInToday(date)
    }

    // Month label for grouping in the garden list, e.g. "April 2026"
    var monthGroup: String {
        guard let date = occurredDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, description, source
        case herQuote = "her_quote"
        case context
        case linkedDimension = "linked_dimension"
        case quotedInChat = "quoted_in_chat"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
        case v, body_ct, nonce, K_user, K_enclave, visibility, owner_user_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(String.self, forKey: .id)
        type             = (try? c.decode(String.self, forKey: .type)) ?? ""
        title            = (try? c.decode(String.self, forKey: .title)) ?? ""
        description      = (try? c.decode(String.self, forKey: .description)) ?? ""
        occurredAt       = try c.decode(String.self, forKey: .occurredAt)
        createdAt        = try c.decode(String.self, forKey: .createdAt)
        source           = (try? c.decode(String.self, forKey: .source)) ?? ""
        herQuote         = try? c.decode(String.self, forKey: .herQuote)
        context          = try? c.decode(String.self, forKey: .context)
        linkedDimension  = try? c.decode(String.self, forKey: .linkedDimension)
        quotedInChat     = try? c.decode(Int.self, forKey: .quotedInChat)
        v                = try? c.decode(Int.self, forKey: .v)
        body_ct          = try? c.decode(String.self, forKey: .body_ct)
        nonce            = try? c.decode(String.self, forKey: .nonce)
        K_user           = try? c.decode(String.self, forKey: .K_user)
        K_enclave        = try? c.decode(String.self, forKey: .K_enclave)
        visibility       = try? c.decode(String.self, forKey: .visibility)
        owner_user_id    = try? c.decode(String.self, forKey: .owner_user_id)
    }

    var occurredDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: occurredAt) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: occurredAt)
    }

    var relativeOccurredAt: String {
        guard let date = occurredDate else { return occurredAt }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var isEncryptedEnvelope: Bool {
        (v ?? 0) >= 1 && body_ct != nil && title.isEmpty
    }

    func decryptedIfNeeded(withUserSK sk: Curve25519.KeyAgreement.PrivateKey) -> MemoryMoment {
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
            let pt = try ContentEncryption.unseal(envelope, withUserSK: sk)
            struct Inner: Decodable {
                let title: String?; let description: String?; let type: String?
                let her_quote: String?; let context: String?
                let linked_dimension: String?; let quoted_in_chat: Int?
            }
            let inner = try JSONDecoder().decode(Inner.self, from: pt)
            var copy = self
            copy.title           = inner.title ?? ""
            copy.description     = inner.description ?? ""
            copy.type            = inner.type ?? ""
            copy.herQuote        = inner.her_quote
            copy.context         = inner.context
            copy.linkedDimension = inner.linked_dimension
            copy.quotedInChat    = inner.quoted_in_chat
            return copy
        } catch {
            print("[memory] unseal failed id=\(id): \(error)")
            var copy = self
            copy.title = "[encrypted — decrypt failed]"
            return copy
        }
    }
}

@MainActor
class MemoryViewModel: ObservableObject {
    @Published var moments: [MemoryMoment] = []
    @Published var newMomentIds: Set<String> = []

    private var timer: Timer?
    private var knownIds: Set<String> = []

    func startPolling() {
        Task { await loadMoments() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.loadMoments() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func contentSK() -> Curve25519.KeyAgreement.PrivateKey? {
        do { return try ContentKeyStore.shared.loadPrivateKey() } catch { return nil }
    }

    func loadMoments() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/memory/list",
            queryItems: [URLQueryItem(name: "limit", value: "50")]
        ) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Response: Codable {
                let moments: [MemoryMoment]
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // Decrypt v1 items client-side with the user's content privkey.
            let incoming: [MemoryMoment]
            if let sk = contentSK() {
                incoming = decoded.moments.map { $0.decryptedIfNeeded(withUserSK: sk) }
            } else {
                incoming = decoded.moments
            }
            let incomingIds = Set(incoming.map { $0.id })
            let fresh = incomingIds.subtracting(knownIds)
            if !fresh.isEmpty {
                newMomentIds = newMomentIds.union(fresh)
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    newMomentIds = newMomentIds.subtracting(fresh)
                }
            }
            knownIds = incomingIds
            moments = incoming
        } catch {
            print("[MemoryVM] load error: \(error)")
        }
    }
}
