import Foundation
import SwiftUI

@MainActor
class ChatViewModel: ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var isWaitingForReply: Bool = false

    private var pollingTask: Task<Void, Never>?
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
        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/chat/history?limit=50") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            messages = resp.messages
            latestTs = messages.last?.ts ?? 0
        } catch {
            print("[chat] loadHistory error: \(error)")
        }
    }

    private func fetchNewMessages() async {
        guard let url = URL(string: "\(FeedlingAPI.baseURL)/v1/chat/history?since=\(latestTs)") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            let newMsgs = resp.messages.filter { $0.ts > latestTs }
            guard !newMsgs.isEmpty else { return }
            // Remove optimistic duplicates (same content sent by user moments ago)
            let existingIds = Set(messages.map { $0.id })
            let toAppend = newMsgs.filter { !existingIds.contains($0.id) }
            if !toAppend.isEmpty {
                messages.append(contentsOf: toAppend)
                latestTs = newMsgs.last!.ts
            }
            if newMsgs.contains(where: { $0.isFromOpenClaw }) {
                isWaitingForReply = false
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
