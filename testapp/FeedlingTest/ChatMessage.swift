import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String       // "openclaw" | "user"
    let content: String
    let ts: Double
    let source: String?    // "live_activity" | "chat" | "heartbeat"

    var isFromOpenClaw: Bool { role == "openclaw" }
    var isFromLiveActivity: Bool { source == "live_activity" }
    var date: Date { Date(timeIntervalSince1970: ts) }
}
