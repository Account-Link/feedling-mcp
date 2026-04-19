import CryptoKit
import Foundation

struct IdentityCard: Codable {
    var agentName: String
    var selfIntroduction: String
    var dimensions: [Dimension]
    let createdAt: String
    let updatedAt: String

    // v1 envelope fields (present when server stored ciphertext)
    let v: Int?
    let body_ct: String?
    let nonce: String?
    let K_user: String?
    let K_enclave: String?
    let visibility: String?
    let owner_user_id: String?
    let id: String?

    struct Dimension: Codable, Identifiable {
        let name: String
        let value: Int
        let description: String
        let lastNudgeReason: String?

        var id: String { name }
        var normalizedValue: Double { Double(max(0, min(100, value))) / 100.0 }

        enum CodingKeys: String, CodingKey {
            case name, value, description
            case lastNudgeReason = "last_nudge_reason"
        }
    }

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case selfIntroduction = "self_introduction"
        case dimensions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case v, body_ct, nonce, K_user, K_enclave, visibility, owner_user_id, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentName        = (try? c.decode(String.self, forKey: .agentName)) ?? ""
        selfIntroduction = (try? c.decode(String.self, forKey: .selfIntroduction)) ?? ""
        dimensions       = (try? c.decode([Dimension].self, forKey: .dimensions)) ?? []
        createdAt        = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt        = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        v               = try? c.decode(Int.self, forKey: .v)
        body_ct         = try? c.decode(String.self, forKey: .body_ct)
        nonce           = try? c.decode(String.self, forKey: .nonce)
        K_user          = try? c.decode(String.self, forKey: .K_user)
        K_enclave       = try? c.decode(String.self, forKey: .K_enclave)
        visibility      = try? c.decode(String.self, forKey: .visibility)
        owner_user_id   = try? c.decode(String.self, forKey: .owner_user_id)
        id              = try? c.decode(String.self, forKey: .id)
    }

    var isEncryptedEnvelope: Bool {
        (v ?? 0) >= 1 && body_ct != nil && agentName.isEmpty
    }

    func decryptedIfNeeded(withUserSK sk: Curve25519.KeyAgreement.PrivateKey) -> IdentityCard {
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
            id: id ?? "", v: v ?? 1,
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
                let agent_name: String?
                let self_introduction: String?
                let dimensions: [Dimension]?
            }
            let inner = try JSONDecoder().decode(Inner.self, from: pt)
            var copy = self
            copy.agentName = inner.agent_name ?? ""
            copy.selfIntroduction = inner.self_introduction ?? ""
            copy.dimensions = inner.dimensions ?? []
            return copy
        } catch {
            print("[identity] unseal failed: \(error)")
            var copy = self
            copy.agentName = "[encrypted — decrypt failed]"
            return copy
        }
    }
}

@MainActor
class IdentityViewModel: ObservableObject {
    @Published var identity: IdentityCard? = nil
    @Published var isLoading = false
    @Published var didJustBootstrap = false

    private var timer: Timer?
    private var wasNil = true

    func startPolling() {
        Task { await loadIdentity() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.loadIdentity() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func contentSK() -> Curve25519.KeyAgreement.PrivateKey? {
        do { return try ContentKeyStore.shared.loadPrivateKey() } catch { return nil }
    }

    func loadIdentity() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(path: "/v1/identity/get") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Response: Codable {
                let identity: IdentityCard?
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            var newIdentity = decoded.identity
            if let sk = contentSK(), var id = newIdentity {
                newIdentity = id.decryptedIfNeeded(withUserSK: sk)
                _ = id
            }
            if wasNil && newIdentity != nil {
                didJustBootstrap = true
            }
            wasNil = newIdentity == nil
            identity = newIdentity
        } catch {
            print("[IdentityVM] load error: \(error)")
        }
    }
}
