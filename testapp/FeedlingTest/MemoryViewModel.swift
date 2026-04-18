import Foundation

struct MemoryMoment: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let title: String
    let description: String
    let occurredAt: String
    let createdAt: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, type, title, description, source
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
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

    func loadMoments() async {
        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/memory/list?limit=50") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            struct Response: Codable {
                let moments: [MemoryMoment]
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let incoming = decoded.moments
            let incomingIds = Set(incoming.map { $0.id })
            let fresh = incomingIds.subtracting(knownIds)
            if !fresh.isEmpty {
                newMomentIds = newMomentIds.union(fresh)
                // Clear highlight after 3 seconds
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
