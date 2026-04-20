import CryptoKit
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

    /// Load user_content_sk from Keychain once per poll cycle. iOS has it
    /// locally so we can decrypt v1 envelopes client-side without going
    /// through the enclave.
    private func contentSK() -> Curve25519.KeyAgreement.PrivateKey? {
        do {
            return try ContentKeyStore.shared.loadPrivateKey()
        } catch {
            return nil
        }
    }

    private func decryptBatch(_ msgs: [ChatMessage]) -> [ChatMessage] {
        guard let sk = contentSK() else { return msgs }
        return msgs.map { $0.decryptedIfNeeded(withUserSK: sk) }
    }

    func loadHistory() async {
        // Pull a larger initial window so user messages are not drowned by
        // assistant-only bursts (e.g. replayed auto-replies).
        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/chat/history",
            queryItems: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "200")]
        ) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            messages = decryptBatch(resp.messages)
            latestTs = messages.last?.ts ?? 0
            let roleCounts = Dictionary(grouping: messages, by: { $0.role }).mapValues { $0.count }
            print("[chat] loadHistory count=\(messages.count) roles=\(roleCounts)")
        } catch {
            print("[chat] loadHistory error: \(error)")
        }
    }

    private func fetchNewMessages() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/chat/history",
            queryItems: [URLQueryItem(name: "since", value: String(latestTs))]
        ) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let rawResp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            let resp = ChatHistoryResponse(messages: decryptBatch(rawResp.messages), total: rawResp.total)
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
            source: "chat",
            v: nil, body_ct: nil, nonce: nil,
            K_user: nil, K_enclave: nil,
            visibility: nil, owner_user_id: nil
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

        // All writes are v1 ciphertext envelopes. The backend rejects
        // plaintext bodies with 400 post-v0 strip, so bail out loudly if
        // crypto material isn't ready yet (fresh install before the first
        // attestation sync).
        let api = FeedlingAPI.shared
        guard let userPK = api.userContentPublicKey,
              let enclavePK = api.enclaveContentPublicKey,
              !api.userId.isEmpty
        else {
            print("[chat] skipping send — content keypair not ready")
            isSending = false
            return
        }
        let body: Data?
        do {
            let env = try ContentEncryption.envelope(
                plaintext: Data(text.utf8),
                ownerUserID: api.userId,
                userContentPK: userPK,
                enclaveContentPK: enclavePK,
                visibility: .shared
            )
            body = try JSONSerialization.data(withJSONObject: env.jsonBody())
            print("[chat] sending v1 envelope id=\(env.id)")
        } catch {
            print("[chat] envelope build failed: \(error)")
            isSending = false
            return
        }

        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/chat/message",
            method: "POST",
            body: body
        ) else {
            isSending = false; return
        }
        _ = try? await URLSession.shared.data(for: req)
        isSending = false
    }
}

// MARK: - Decodable helpers

private struct ChatHistoryResponse: Decodable {
    let messages: [ChatMessage]
    let total: Int
}
