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
    private var resetObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    init() {
        // Drop in-memory chat when credentials are wiped, so the UI flips to
        // ChatEmptyStateView immediately rather than showing stale messages
        // from the old account until the next poll cycle overwrites them.
        resetObserver = NotificationCenter.default.addObserver(
            forName: .feedlingCredentialsReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetForFreshAccount()
            }
        }
    }

    deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    private func resetForFreshAccount() {
        messages = []
        inputText = ""
        isSending = false
        isWaitingForReply = false
        latestTs = 0
        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = nil
        // Polling task keeps running — once new credentials register, it
        // naturally polls the new (empty) account and stays empty.
    }

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

    // Walk a sorted message list and stamp isProactive on agent messages
    // that arrived without a preceding user turn (pure unsolicited messages).
    // Only the FIRST agent message in a consecutive run is marked proactive;
    // subsequent bubbles in the same run are not, so they don't each get
    // a "SHE REACHED OUT" divider.
    private func stampProactive(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var result = msgs
        var prevWasAgent = false
        var prevWasUser  = false
        for i in result.indices {
            if result[i].isFromAgent {
                result[i].isProactive = !prevWasAgent && !prevWasUser
                prevWasAgent = true
                prevWasUser  = false
            } else {
                result[i].isProactive = false
                prevWasAgent = false
                prevWasUser  = true
            }
        }
        return result
    }

    func loadHistory() async {
        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/chat/history",
            queryItems: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "200")]
        ) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
            messages = stampProactive(decryptBatch(resp.messages))
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
            let newFromAgent = resp.messages.filter { m in
                m.ts > latestTs && m.isFromAgent
            }
            guard !newFromAgent.isEmpty else { return }
            let existingIds = Set(messages.map { $0.id })
            let toAppend = newFromAgent.filter { !existingIds.contains($0.id) }
            if !toAppend.isEmpty {
                // Re-stamp the full thread so newly appended messages get correct isProactive
                let combined = stampProactive(messages + toAppend)
                messages = combined
                latestTs = newFromAgent.last!.ts
                isWaitingForReply = false
                waitingTimeoutTask?.cancel()
            }
        } catch {
            print("[chat] fetchNew error: \(error)")
        }
    }

    // MARK: - Quote a memory card in chat

    /// Formats a memory card as a quoted reference and pre-fills the input
    /// field so the user can send it (with or without additional text).
    func quoteInChat(moment: MemoryMoment) {
        let header = "[\(moment.type.uppercased())] \(moment.title)"
        let body = moment.description.isEmpty ? "" : "\n\(moment.description)"
        inputText = header + body
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

        // Auto-cancel the typing indicator after 5 min if no reply arrives.
        // Was 60s, but real agent latency post-bootstrap can be 1–3 min and
        // testers were seeing the dots vanish mid-think. 5 min is generous
        // for any healthy agent and still bounded so a fully stuck loop
        // eventually clears the indicator.
        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
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

    /// Send a single image as its own chat message. Image and text messages
    /// are separate in the wire protocol (`content_type` plaintext metadata
    /// distinguishes them); the user sends one or the other per send.
    ///
    /// `jpegData` should already be compressed to a sane size (≤ 400 KB).
    /// View layer is responsible for that — this method just encrypts and POSTs.
    func sendImage(_ jpegData: Data) async {
        guard !isSending else { return }
        guard !jpegData.isEmpty else {
            print("[chat] sendImage called with empty data")
            return
        }
        isSending = true
        defer { isSending = false }

        let optimistic = ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: "",
            ts: Date().timeIntervalSince1970,
            source: "chat",
            contentType: .image,
            imageData: jpegData
        )
        messages.append(optimistic)
        latestTs = optimistic.ts
        isWaitingForReply = true

        waitingTimeoutTask?.cancel()
        waitingTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            if !Task.isCancelled { isWaitingForReply = false }
        }

        let api = FeedlingAPI.shared
        guard let userPK = api.userContentPublicKey,
              let enclavePK = api.enclaveContentPublicKey,
              !api.userId.isEmpty
        else {
            print("[chat] sendImage skipped — content keypair not ready")
            return
        }

        let body: Data?
        do {
            let env = try ContentEncryption.envelope(
                plaintext: jpegData,
                ownerUserID: api.userId,
                userContentPK: userPK,
                enclaveContentPK: enclavePK,
                visibility: .shared
            )
            // jsonBody() already returns {"envelope": {...}}; we add the
            // content_type tag at the same outer level (plaintext metadata,
            // server uses it to mark the row as image vs text).
            var outer = env.jsonBody()
            outer["content_type"] = "image"
            body = try JSONSerialization.data(withJSONObject: outer)
            print("[chat] sending v1 image envelope id=\(env.id) bytes=\(jpegData.count)")
        } catch {
            print("[chat] image envelope build failed: \(error)")
            return
        }

        guard let req = FeedlingAPI.shared.authorizedRequest(
            path: "/v1/chat/message",
            method: "POST",
            body: body
        ) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Decodable helpers

private struct ChatHistoryResponse: Decodable {
    let messages: [ChatMessage]
    let total: Int
}
