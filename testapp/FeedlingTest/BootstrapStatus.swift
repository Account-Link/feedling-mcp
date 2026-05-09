import Foundation

// MARK: - Server response shape

/// Mirrors `/v1/bootstrap/status` on the Flask backend.
struct BootstrapStatus: Codable, Equatable {
    let agentConnected: Bool
    let lastAgentActivity: String          // ISO timestamp, may be empty
    let identityWritten: Bool
    let relationshipAnchored: Bool
    let memoriesCount: Int
    let agentMessagesCount: Int
    let isComplete: Bool

    static let empty = BootstrapStatus(
        agentConnected: false,
        lastAgentActivity: "",
        identityWritten: false,
        relationshipAnchored: false,
        memoriesCount: 0,
        agentMessagesCount: 0,
        isComplete: false
    )

    enum CodingKeys: String, CodingKey {
        case agentConnected      = "agent_connected"
        case lastAgentActivity   = "last_agent_activity"
        case identityWritten     = "identity_written"
        case relationshipAnchored = "relationship_anchored"
        case memoriesCount       = "memories_count"
        case agentMessagesCount  = "agent_messages_count"
        case isComplete          = "is_complete"
    }

    /// Parses `last_agent_activity` and returns "12 min ago" / "刚刚" /
    /// "never" depending on locale. Empty string → nil.
    func lastActivityRelative(now: Date = Date()) -> String? {
        guard !lastAgentActivity.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date: Date? = fmt.date(from: lastAgentActivity) ?? {
            fmt.formatOptions = [.withInternetDateTime]
            return fmt.date(from: lastAgentActivity)
        }()
        guard let date else { return nil }
        let interval = now.timeIntervalSince(date)
        if interval < 60   { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600)) h ago" }
        return "\(Int(interval / 86400)) d ago"
    }
}

// MARK: - View model

@MainActor
final class BootstrapStatusViewModel: ObservableObject {
    @Published private(set) var status: BootstrapStatus = .empty
    @Published private(set) var lastFetchAt: Date? = nil

    private var pollTask: Task<Void, Never>?

    /// Polls /v1/bootstrap/status every `interval` seconds while running.
    /// The view layer starts polling on appear and cancels on disappear.
    func startPolling(interval: TimeInterval = 5) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(path: "/v1/bootstrap/status") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(BootstrapStatus.self, from: data)
            self.status = decoded
            self.lastFetchAt = Date()
        } catch {
            // Silent — empty-state UI just keeps showing "waiting"
            print("[bootstrap-status] fetch failed: \(error)")
        }
    }
}
