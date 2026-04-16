import Foundation
import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var isWaitingForReply: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var waitingTimeoutTask: Task<Void, Never>?
    private var latestTs: Double = 0

    // MARK: - Lifecycle

    func startPolling() {
        guard pollingTask == nil || pollingTask!.isCancelled else { return }
        pollingTask = Task {
            await loadHistory()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await fetchNewMessages()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Fetch

    func loadHistory() async {
        // Pull a larger initial window so user messages are not drowned by
        // assistant-only bursts (e.g. replayed auto-replies).
        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/chat/history?since=0&limit=200") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            messages = resp.messages
            latestTs = messages.last?.ts ?? 0
            let roleCounts = Dictionary(grouping: messages, by: { $0.role }).mapValues { $0.count }
            print("[chat] loadHistory count=\(messages.count) roles=\(roleCounts)")
        } catch {
            print("[chat] loadHistory error: \(error)")
        }
    }

    private func fetchNewMessages() async {
        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/chat/history?since=\(latestTs)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            // Only process OpenClaw messages via polling.
            // User messages are inserted optimistically — ignoring server echoes prevents duplicates.
            let newFromOpenClaw = resp.messages.filter { m in
                m.ts > latestTs && (m.role == "openclaw" || m.role == "assistant")
            }
            guard !newFromOpenClaw.isEmpty else { return }
            let existingIds = Set(messages.map { $0.id })
            let toAppend = newFromOpenClaw.filter { !existingIds.contains($0.id) }
            if !toAppend.isEmpty {
                messages.append(contentsOf: toAppend)
                latestTs = newFromOpenClaw.last!.ts
                isWaitingForReply = false
                waitingTimeoutTask?.cancel()
            }
        } catch {
            print("[chat] fetchNew error: \(error)")
        }
    }

    // MARK: - Send

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        inputText = ""
        isSending = true

        // Optimistic insert
        let optimistic = ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: text,
            ts: Date().timeIntervalSince1970,
            source: "chat"
        )
        messages.append(optimistic)
        latestTs = optimistic.ts
        isWaitingForReply = true

        // Auto-cancel the loading indicator after 60s if no reply arrives
        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled { isWaitingForReply = false }
        }

        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/chat/message") else {
            isSending = false; return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["content": text])
        _ = try? await URLSession.shared.data(for: req)
        isSending = false
    }
}

// MARK: - Decodable helpers

private struct ChatHistoryResponse: Decodable {
    let messages: [ChatMessage]
    let total: Int
}
