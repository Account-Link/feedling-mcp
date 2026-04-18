import Foundation

struct IdentityCard: Codable {
    let agentName: String
    let selfIntroduction: String
    let dimensions: [Dimension]
    let createdAt: String
    let updatedAt: String

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

    func loadIdentity() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(path: "/v1/identity/get") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Response: Codable {
                let identity: IdentityCard?
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let newIdentity = decoded.identity
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
