import CryptoKit
import Foundation
import Network
import Security
import SwiftUI
import UIKit

/// Central HTTP client + credentials store for the Feedling iOS app.
///
/// Credentials are persisted in UserDefaults AND mirrored to an app-group
/// UserDefaults so the broadcast extension (screen recording) can pick up the
/// API key as a WebSocket `Bearer` token.
@MainActor
final class FeedlingAPI: ObservableObject {
    static let shared = FeedlingAPI()

    // MARK: - Persistence keys

    private enum Keys {
        static let baseURL = "feedling.baseURL"
        static let apiKey = "feedling.apiKey"
        static let userId = "feedling.userId"
        static let storageMode = "feedling.storageMode"       // "cloud" or "self_hosted"
        static let hasRegistered = "feedling.hasRegistered"
        static let registrationFailed = "feedling.registrationFailed"
        static let cloudApiKey = "feedling.cloudApiKey"
        static let cloudUserId = "feedling.cloudUserId"
    }

    enum StorageMode: String {
        case cloud
        case selfHosted = "self_hosted"
    }

    private static let appGroup = "group.com.feedling.mcp"
    private static let defaultCloudURL = "https://api.feedling.app"

    // MARK: - Published credentials (drives UI)

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published var userId: String
    @Published var storageMode: StorageMode {
        didSet { persist() }
    }

    // Legacy static access used by existing view-model code.
    // Keeps call sites like `FeedlingAPI.baseURL` unchanged while we roll out the ObservableObject.
    static var baseURL: String {
        if let env = ProcessInfo.processInfo.environment["FEEDLING_API_URL"], !env.isEmpty {
            return env
        }
        return UserDefaults.standard.string(forKey: Keys.baseURL) ?? defaultCloudURL
    }

    static var apiKey: String {
        if let env = ProcessInfo.processInfo.environment["FEEDLING_API_KEY"], !env.isEmpty {
            return env
        }
        if let stored = ApiKeyStore.shared.load(), !stored.isEmpty {
            return stored
        }
        return UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
    }

    static var userId: String {
        UserDefaults.standard.string(forKey: Keys.userId) ?? ""
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard
        self.baseURL = ProcessInfo.processInfo.environment["FEEDLING_API_URL"]
            ?? defaults.string(forKey: Keys.baseURL)
            ?? Self.defaultCloudURL

        // apiKey resolution order:
        //   1. FEEDLING_API_KEY env var (test/dev override)
        //   2. Keychain (durable across reinstalls and UserDefaults wipes)
        //   3. UserDefaults legacy value — migrated into Keychain on first read
        if let env = ProcessInfo.processInfo.environment["FEEDLING_API_KEY"], !env.isEmpty {
            self.apiKey = env
        } else if let stored = ApiKeyStore.shared.load(), !stored.isEmpty {
            self.apiKey = stored
        } else if let legacy = defaults.string(forKey: Keys.apiKey), !legacy.isEmpty {
            // One-time migration: pull existing UserDefaults key into Keychain.
            self.apiKey = legacy
            ApiKeyStore.shared.save(legacy)
        } else {
            self.apiKey = ""
        }

        self.userId = defaults.string(forKey: Keys.userId) ?? ""
        self.storageMode = StorageMode(rawValue: defaults.string(forKey: Keys.storageMode) ?? "") ?? .cloud
        // Mirror the resolved apiKey back to UserDefaults so the App Group +
        // broadcast extension see the migrated value immediately.
        defaults.set(apiKey, forKey: Keys.apiKey)
        syncToAppGroup()
    }

    // MARK: - Public config

    /// Point the app at a self-hosted server. Saves any cloud credentials before switching away.
    func configureSelfHosted(url: String, apiKey: String) {
        if storageMode == .cloud && !self.apiKey.isEmpty {
            UserDefaults.standard.set(self.apiKey, forKey: Keys.cloudApiKey)
            UserDefaults.standard.set(self.userId, forKey: Keys.cloudUserId)
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        self.storageMode = .selfHosted
        self.baseURL = cleanedURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userId = ""
        UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
        persist()
    }

    /// Switch to self-hosted mode, preserving cloud credentials so they can be restored later.
    func enterSelfHostedMode() {
        if storageMode == .cloud && !apiKey.isEmpty {
            UserDefaults.standard.set(apiKey, forKey: Keys.cloudApiKey)
            UserDefaults.standard.set(userId, forKey: Keys.cloudUserId)
        }
        storageMode = .selfHosted
        persist()
    }

    /// Go back to Feedling cloud. Restores previously saved cloud credentials if available.
    func configureCloud() {
        let savedKey = UserDefaults.standard.string(forKey: Keys.cloudApiKey) ?? ""
        let savedUserId = UserDefaults.standard.string(forKey: Keys.cloudUserId) ?? ""
        self.storageMode = .cloud
        self.baseURL = Self.defaultCloudURL
        if !savedKey.isEmpty {
            self.apiKey = savedKey
            self.userId = savedUserId
        } else {
            self.apiKey = ""
            self.userId = ""
            UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
            UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
        }
        persist()
    }

    /// Overwrite credentials with a fresh (user_id, api_key) — used after `register()`.
    fileprivate func setCredentials(userId: String, apiKey: String) {
        self.userId = userId
        self.apiKey = apiKey
        UserDefaults.standard.set(true, forKey: Keys.hasRegistered)
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
        persist()
        // Re-upload any tokens that were skipped because apiKey was empty at the time.
        Task { await LiveActivityManager.shared.retryPendingTokenUploads() }
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: Keys.baseURL)
        d.set(apiKey, forKey: Keys.apiKey)
        d.set(userId, forKey: Keys.userId)
        d.set(storageMode.rawValue, forKey: Keys.storageMode)
        // Mirror to Keychain so apiKey survives UserDefaults wipes; an empty
        // value here intentionally clears the Keychain entry too.
        ApiKeyStore.shared.save(apiKey)
        syncToAppGroup()
    }

    private func syncToAppGroup() {
        guard let shared = UserDefaults(suiteName: Self.appGroup) else { return }
        shared.set(baseURL, forKey: Keys.baseURL)
        shared.set(apiKey, forKey: Keys.apiKey)
        shared.set(userId, forKey: Keys.userId)
        // The broadcast extension uses `ingestToken` as a WebSocket Bearer.
        shared.set(apiKey, forKey: "ingest_ws_token")
        // Also sync the ingest endpoint so the extension doesn't rely on a
        // stale hard-coded host.
        shared.set(resolveIngestWSEndpoint(from: baseURL), forKey: "ingest_ws_endpoint")
    }

    private func resolveIngestWSEndpoint(from baseURL: String) -> String {
        guard let comps = URLComponents(string: baseURL), let host = comps.host, !host.isEmpty else {
            return CVMEndpoints.wsIngestURL
        }
        // Cloud API is behind dstack-ingress; the WS ingest on :9998 is NOT
        // in the ingress routing map (adding it would need another custom
        // domain). Use the dstack-gateway direct URL for cloud; self-hosted
        // falls back to the user's own host on :9998.
        if host == CVMEndpoints.apiHost {
            return CVMEndpoints.wsIngestURL
        }
        return "ws://\(host):9998/ingest"
    }

    // MARK: - Registration

    // Serializes concurrent callers. The `apiKey.isEmpty` guard passes
    // instantly but `setCredentials` only runs after the network round-trip,
    // so N parallel callers would all pass the guard and create N orphan
    // user_ids. Observed 2026-04-20: prod user's first launch post-wipe
    // fired 7 registers in 18 s during an onboarding retry, leaving 6
    // unreachable users on the backend.
    private var registrationTask: Task<Void, Never>?

    /// Multi-tenant cloud registration. Generates a P-256 keypair, stores the
    /// private key in Keychain, uploads the public key, and captures the
    /// returned (user_id, api_key). Idempotent: if already registered, no-ops.
    /// Concurrent callers await the same in-flight request.
    func ensureRegisteredIfCloud() async {
        guard storageMode == .cloud else { return }
        guard apiKey.isEmpty else { return }

        await waitForNetwork()

        // Clear any previous failure flag — network is now reachable.
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)

        if let existing = registrationTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.performRegistration()
        }
        registrationTask = task
        await task.value
        registrationTask = nil
    }

    // Suspends until NWPathMonitor reports a satisfied (reachable) path.
    private func waitForNetwork() async {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "feedling.network.monitor")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = LockBox(false)
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                guard box.setIfFalse() else { return }
                monitor.cancel()
                continuation.resume()
            }
            monitor.start(queue: queue)
        }
    }

    private func performRegistration() async {
        do {
            // Register the content-encryption public key (not the identity key).
            // Chat/Memory/Identity envelopes are wrapped to ContentKeyStore's keypair;
            // if registration uploads a different key, incoming assistant messages
            // become undecryptable (`[encrypted — decrypt failed]`).
            let contentSK = try ContentKeyStore.shared.ensureContentKeypair()
            let pubB64 = contentSK.publicKey.rawRepresentation.base64EncodedString()
            let body: [String: Any] = ["public_key": pubB64]
            let data = try JSONSerialization.data(withJSONObject: body)

            guard let url = URL(string: "\(baseURL)/v1/users/register") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data

            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }

            guard (200..<300).contains(http.statusCode) else {
                print("[register] HTTP \(http.statusCode): \(String(data: respData, encoding: .utf8) ?? "")")
                UserDefaults.standard.set(true, forKey: Keys.registrationFailed)
                return
            }

            struct RegResp: Decodable { let user_id: String; let api_key: String }
            let decoded = try JSONDecoder().decode(RegResp.self, from: respData)
            setCredentials(userId: decoded.user_id, apiKey: decoded.api_key)
            print("[register] got user_id=\(decoded.user_id)")
        } catch {
            print("[register] error: \(error)")
            UserDefaults.standard.set(true, forKey: Keys.registrationFailed)
        }
    }

    /// Resolve/refresh user_id and continuously self-heal server public_key via
    /// /v1/users/whoami. We intentionally run even when userId already exists,
    /// because legacy installs can have a stale/mismatched registered key that
    /// causes `[encrypted — decrypt failed]` for all incoming messages.
    func ensureUserIdIfNeeded() async {
        guard !apiKey.isEmpty else { return }
        guard let req = authorizedRequest(path: "/v1/users/whoami") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            struct Who: Decodable {
                let user_id: String
                let public_key: String?
            }
            let w = try JSONDecoder().decode(Who.self, from: data)
            if !w.user_id.isEmpty, w.user_id != self.userId {
                self.userId = w.user_id
                UserDefaults.standard.set(w.user_id, forKey: Keys.userId)
                syncToAppGroup()
                print("[whoami] resolved user_id=\(w.user_id)")
            }

            // Self-heal key drift: if the server's registered public_key differs
            // from this device's content-encryption public key, patch it so
            // incoming assistant messages are decryptable.
            let localContentPK = try ContentKeyStore.shared.ensureContentKeypair().publicKey.rawRepresentation.base64EncodedString()
            if let remotePK = w.public_key, !remotePK.isEmpty, remotePK != localContentPK {
                print("[whoami] public_key mismatch detected; syncing content key")
                let body = try JSONSerialization.data(withJSONObject: ["public_key": localContentPK])
                if let syncReq = authorizedRequest(path: "/v1/users/public-key", method: "POST", body: body) {
                    let (_, syncResp) = try await URLSession.shared.data(for: syncReq)
                    let code = (syncResp as? HTTPURLResponse)?.statusCode ?? -1
                    print("[whoami] public_key sync status=\(code)")
                }
            }
        } catch {
            print("[whoami] failed: \(error)")
        }
    }

    // MARK: - Phase B: compose-hash-change detection

    private enum PhaseBKeys {
        static let lastAcceptedComposeHash = "feedling.lastAcceptedComposeHash"
        static let onboardingCompletedV1 = "feedling.onboardingCompleted.v1"
        static let signedOutForComposeChange = "feedling.signedOutForComposeChange"
    }

    @Published var composeHashChangedRequiresConsent: Bool = false
    @Published var pendingComposeHashChange: (oldHash: String, newHash: String)? = nil

    /// Compare the latest fetched compose_hash against the last value the
    /// user explicitly accepted. If different (and we had a prior value),
    /// flag the app to show the consent modal.
    func evaluateComposeHashChange() {
        guard let current = enclaveComposeHash, !current.isEmpty else { return }
        let lastAccepted = UserDefaults.standard.string(forKey: PhaseBKeys.lastAcceptedComposeHash) ?? ""
        if lastAccepted.isEmpty {
            // First time we've seen one. Accept silently.
            UserDefaults.standard.set(current, forKey: PhaseBKeys.lastAcceptedComposeHash)
            return
        }
        if lastAccepted != current {
            pendingComposeHashChange = (oldHash: lastAccepted, newHash: current)
            composeHashChangedRequiresConsent = true
        }
    }

    func acceptComposeHashChange() {
        guard let pending = pendingComposeHashChange else { return }
        UserDefaults.standard.set(pending.newHash, forKey: PhaseBKeys.lastAcceptedComposeHash)
        UserDefaults.standard.set(false, forKey: PhaseBKeys.signedOutForComposeChange)
        pendingComposeHashChange = nil
        composeHashChangedRequiresConsent = false
    }

    func signOutForComposeChange() {
        UserDefaults.standard.set(true, forKey: PhaseBKeys.signedOutForComposeChange)
        composeHashChangedRequiresConsent = false
    }

    var isSignedOutForComposeChange: Bool {
        UserDefaults.standard.bool(forKey: PhaseBKeys.signedOutForComposeChange)
    }

    var hasCompletedOnboardingV1: Bool {
        get { UserDefaults.standard.bool(forKey: PhaseBKeys.onboardingCompletedV1) }
        set { UserDefaults.standard.set(newValue, forKey: PhaseBKeys.onboardingCompletedV1) }
    }

    // MARK: - Phase B wave-2: per-item visibility flip

    /// Flip the visibility of a single memory moment by re-wrapping its
    /// plaintext with a fresh envelope that either includes or omits
    /// `K_enclave`, then POSTing to `/v1/content/swap`. iOS holds the
    /// plaintext already (it's displayed in the UI), so no server trip
    /// for decryption is needed.
    ///
    /// - Parameter moment: the moment to flip. Its fields are used both
    ///   for the new envelope's plaintext body (title + description + type)
    ///   and for the AEAD AAD binding (`owner_user_id || v || id`).
    /// - Parameter toLocalOnly: true → `local_only` (K_enclave dropped,
    ///   agent can no longer read). false → `shared` (K_enclave re-added).
    /// - Throws: on missing pubkeys, serialization failure, or network
    ///   error. Caller is expected to surface the error in UI.
    func flipMemoryVisibility(
        moment: MemoryMoment,
        toLocalOnly: Bool
    ) async throws {
        guard let userPK = userContentPublicKey,
              let enclavePK = enclaveContentPublicKey,
              !userId.isEmpty
        else {
            throw NSError(domain: "VisibilityFlip", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Content keypair or enclave pubkey not ready — try again after the audit card verifies."])
        }

        // Build the plaintext body the same way MCP's memory.add_moment
        // does on the write path, so the AEAD binding is consistent.
        let inner: [String: String] = [
            "title": moment.title,
            "description": moment.description,
            "type": moment.type,
        ]
        let innerData = try JSONSerialization.data(withJSONObject: inner)

        let visibility: ContentEncryption.Visibility = toLocalOnly ? .localOnly : .shared
        let envelope = try ContentEncryption.envelope(
            plaintext: innerData,
            ownerUserID: userId,
            userContentPK: userPK,
            enclaveContentPK: toLocalOnly ? nil : enclavePK,
            visibility: visibility,
            itemID: moment.id
        )

        let items: [[String: Any]] = [[
            "type": "memory",
            "id": moment.id,
            "envelope": envelope.jsonBody()["envelope"] as Any
        ]]
        let body = try JSONSerialization.data(withJSONObject: ["items": items])
        guard let req = authorizedRequest(path: "/v1/content/swap",
                                          method: "POST", body: body) else {
            throw NSError(domain: "VisibilityFlip", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build request"])
        }
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "VisibilityFlip",
                          code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP failure"])
        }
    }

    func deleteMemory(id: String) async throws {
        guard var req = authorizedRequest(path: "/v1/memory/delete",
                                          queryItems: [URLQueryItem(name: "id", value: id)]) else {
            throw NSError(domain: "DeleteMemory", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build request"])
        }
        req.httpMethod = "DELETE"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "DeleteMemory",
                          code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP failure"])
        }
    }

    // MARK: - Phase B: export + delete

    struct ExportResult {
        let data: Data
        let suggestedFilename: String
    }

    /// Fetch the user's full content export as a JSON blob. iOS saves it
    /// locally; the server doesn't decrypt anything — ciphertext is in
    /// the blob and the user's content_sk (Keychain) decrypts it if they
    /// ever need to import.
    func exportMyData() async throws -> ExportResult {
        guard let req = authorizedRequest(path: "/v1/content/export") else {
            throw NSError(domain: "Export", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build request"])
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Export", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no response"])
        }
        if http.statusCode == 413 {
            throw NSError(domain: "Export", code: 413,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "Export too large; streaming is a Phase B follow-up."])
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "Export", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        // Parse Content-Disposition for suggested filename, else derive one.
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let filename: String
        if let range = disposition.range(of: "filename=\""),
           let end = disposition[range.upperBound...].firstIndex(of: "\"") {
            filename = String(disposition[range.upperBound..<end])
        } else {
            let ts = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            filename = "feedling-export-\(userId)-\(ts).json"
        }
        return ExportResult(data: data, suggestedFilename: filename)
    }

    /// Hard-delete the account on the server + wipe local credentials +
    /// Keychain content key. Resets onboarding so first-launch runs again.
    func deleteMyDataAndResetLocalState() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["confirm": "delete-all-data"])
        guard let req = authorizedRequest(path: "/v1/account/reset", method: "POST", body: body) else {
            throw NSError(domain: "Reset", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not build request"])
        }
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Reset", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "reset failed"])
        }

        // Wipe local state — credentials, Keychain entries, UserDefaults flags.
        self.userId = ""
        self.apiKey = ""
        persist()
        UserDefaults.standard.removeObject(forKey: Keys.userId)
        UserDefaults.standard.removeObject(forKey: Keys.apiKey)
        UserDefaults.standard.removeObject(forKey: PhaseBKeys.lastAcceptedComposeHash)
        UserDefaults.standard.removeObject(forKey: PhaseBKeys.onboardingCompletedV1)
        UserDefaults.standard.removeObject(forKey: PhaseBKeys.signedOutForComposeChange)
        UserDefaults.standard.removeObject(forKey: Keys.hasRegistered)

        // Wipe Keychain content + identity key + apiKey so a fresh register starts clean.
        _ = ContentKeyStore.shared.wipeKeypair()
        _ = KeyStore.shared.wipeKeypair()
        _ = ApiKeyStore.shared.wipe()
    }

    /// Discard current credentials and regenerate. Asks server to register fresh.
    /// Wipes the Keychain entry too so `init()` on next launch can't resurrect
    /// the old key — otherwise regenerate becomes a no-op.
    func regenerateCredentials() async {
        UserDefaults.standard.removeObject(forKey: Keys.cloudApiKey)
        UserDefaults.standard.removeObject(forKey: Keys.cloudUserId)
        self.apiKey = ""
        self.userId = ""
        UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
        _ = ApiKeyStore.shared.wipe()
        persist()
        await ensureRegisteredIfCloud()
    }

    // MARK: - HTTP helpers

    func authorizedRequest(path: String, method: String = "GET", body: Data? = nil, queryItems: [URLQueryItem]? = nil) -> URLRequest? {
        guard var comps = URLComponents(string: baseURL + path) else { return nil }
        if let queryItems, !queryItems.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + queryItems
        }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body { req.httpBody = body }
        return req
    }

    // MARK: - Display strings for Settings

    var mcpConnectionString: String {
        // In self-hosted mode the user's server likely isn't on mcp.feedling.app yet;
        // we still render a copy-paste-able string using their own baseURL's host.
        if storageMode == .selfHosted {
            let derivedMCP = baseURL
                .replacingOccurrences(of: ":5001", with: ":5002")
                .replacingOccurrences(of: "api.", with: "mcp.")
            return "claude mcp add feedling --transport sse \"\(derivedMCP)/sse?key=\(apiKey.isEmpty ? "<YOUR_KEY>" : apiKey)\""
        }
        let mcp = "https://mcp.feedling.app"
        return "claude mcp add feedling --transport sse \"\(mcp)/sse?key=\(apiKey.isEmpty ? "<registering…>" : apiKey)\""
    }

    var envExportBlock: String {
        return """
        FEEDLING_API_URL=\(baseURL)
        FEEDLING_API_KEY=\(apiKey.isEmpty ? "<registering…>" : apiKey)
        """
    }

    // MARK: - Content keypair + enclave pubkey

    /// The user's X25519 public key used to wrap content-item symmetric
    /// keys on the client side. Maintained here so ChatViewModel /
    /// MemoryViewModel etc. can pull it once.
    @Published private(set) var userContentPublicKey: Curve25519.KeyAgreement.PublicKey?

    /// The enclave's content X25519 public key, fetched from
    /// GET /attestation on mcp.feedling.app. Refreshed whenever
    /// audit verification runs. nil until first sync.
    @Published private(set) var enclaveContentPublicKey: Curve25519.KeyAgreement.PublicKey?

    /// Compose hash from the live enclave's attestation. nil before first sync.
    @Published private(set) var enclaveComposeHash: String?

    /// MRTD from the live enclave's attestation.
    @Published private(set) var enclaveMRTD: String?

    /// URL for the /attestation endpoint. Defaults to the cloud CVM's
    /// `-5003s.` TLS-passthrough route; in self-hosted mode swaps to the
    /// user's own host.
    private var attestationURL: URL? {
        if let override = ProcessInfo.processInfo.environment["FEEDLING_ATTESTATION_URL"],
           let u = URL(string: override) {
            return u
        }
        if storageMode == .selfHosted {
            let mcp = baseURL.replacingOccurrences(of: "api.", with: "mcp.")
            return URL(string: "\(mcp)/attestation")
        }
        // Phase 3: Phala dstack CVM with in-enclave TLS. The `-5003s.`
        // suffix tells dstack-gateway to pass TLS through to the CVM
        // instead of terminating — the cert the client sees is the one
        // the enclave generated (bound to compose_hash via REPORT_DATA).
        // See deploy/DEPLOYMENTS.md §Phase 3 and CVMEndpoints.swift.
        return CVMEndpoints.attestationURL
    }

    /// Load (or lazily generate) the user's long-lived content keypair.
    /// Backed by Keychain entries distinct from the identity keypair.
    func ensureContentKeypair() {
        if userContentPublicKey != nil {
            publishContentKeysToAppGroup()
            return
        }
        do {
            let sk = try ContentKeyStore.shared.ensureContentKeypair()
            userContentPublicKey = sk.publicKey
            publishContentKeysToAppGroup()
        } catch {
            print("[content-keypair] failed to load/generate: \(error)")
        }
    }

    /// Publish the content pubkeys + user_id to the shared App Group
    /// UserDefaults so the broadcast extension can build v1 envelopes
    /// around frame payloads. Only public info is shared — the user's
    /// content private key stays in the main app's Keychain.
    /// See FeedlingBroadcast/FrameEnvelope.swift for the reader side.
    func publishContentKeysToAppGroup() {
        guard let shared = UserDefaults(suiteName: "group.com.feedling.mcp") else { return }
        shared.set(userId, forKey: "feedling.userID")
        if let pk = userContentPublicKey {
            shared.set(pk.rawRepresentation.base64EncodedString(),
                       forKey: "feedling.userContentPublicKey")
        }
        if let pk = enclaveContentPublicKey {
            shared.set(pk.rawRepresentation.base64EncodedString(),
                       forKey: "feedling.enclaveContentPublicKey")
        }
    }

    /// Hit the enclave's /attestation endpoint, pull out the content pubkey,
    /// compose_hash, MRTD. Does NOT (yet) run the full DCAP verification —
    /// that's the audit card's job. This method is fire-and-forget from
    /// the app-startup hook.
    func refreshEnclaveAttestation() async {
        guard let url = attestationURL else { return }
        // Phase 3: the enclave presents a self-signed cert bound via
        // REPORT_DATA. URLSession.shared would reject it on CA grounds
        // — use a session whose delegate accepts the cert so the
        // startup-time metadata fetch still succeeds. Trust for this
        // data is downstream (AuditCardView runs the real pinning);
        // this path only populates the enclave_content_pk used for
        // wrapping ciphertext destined for the enclave.
        let session = URLSession(configuration: .ephemeral,
                                 delegate: AttestationTrustShim(),
                                 delegateQueue: nil)
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct Bundle: Decodable {
                let enclave_content_pk_hex: String
                let compose_hash: String?
                let measurements: Measurements?
                struct Measurements: Decodable { let mrtd: String? }
            }
            let b = try JSONDecoder().decode(Bundle.self, from: data)
            guard let pkBytes = Data(hexString: b.enclave_content_pk_hex) else { return }
            let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkBytes)
            self.enclaveContentPublicKey = pk
            self.enclaveComposeHash = b.compose_hash
            self.enclaveMRTD = b.measurements?.mrtd
            publishContentKeysToAppGroup()
            // Phase B: check whether the Feedling app version changed
            // between sessions. The meaningful signal is compose_hash —
            // platform-layer measurements (MRTD, RTMR0-2) change for
            // reasons unrelated to our app, per dstack-tutorial §1.
            evaluateComposeHashChange()
            print("[attestation] refreshed: compose_hash=\(b.compose_hash?.prefix(16) ?? "nil")…")
        } catch {
            print("[attestation] refresh failed: \(error)")
        }
    }
}

// MARK: - Content keypair storage
// (Data(hexString:) is already defined on Data by FeedlingDCAP's Parser.swift.)


/// Keychain-backed X25519 keypair dedicated to content encryption
/// (distinct from the identity keypair held by KeyStore).
///
/// Stored with `kSecAttrSynchronizable = true` so the key follows the
/// user across devices via iCloud Keychain — otherwise deleting the app
/// (or losing the phone) would orphan every v1 envelope ever written
/// with this key. iCloud Keychain is itself end-to-end encrypted under
/// the user's device-tied iCloud Security Code; Apple cannot recover it.
/// See docs/DESIGN_E2E.md §5.3 (key lifecycle).
final class ContentKeyStore {
    static let shared = ContentKeyStore()

    private static let service = "com.feedling.mcp"
    private static let account = "content_private_key"

    private init() {}

    /// Delete the content private key from Keychain (both synced +
    /// device-local variants). Used by Phase B's reset flow.
    func wipeKeypair() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func ensureContentKeypair() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = try loadPrivateKey() { return existing }
        let pk = Curve25519.KeyAgreement.PrivateKey()
        try save(privateKey: pk)
        return pk
    }

    func loadPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        // Match both synchronizable and device-local entries so we can
        // migrate a v0 local-only key forward without losing access.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    private func save(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        let data = privateKey.rawRepresentation
        // Wipe any prior entry (synced or device-local) so we don't leave
        // a stale shadow key that later resurfaces via iCloud.
        let wipeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(wipeQuery as CFDictionary)

        // Prefer iCloud-synced storage so a phone loss doesn't orphan the
        // user's encrypted history. Fall back to device-local if the host
        // rejects sync (simulator without signed entitlements, MDM policy,
        // iCloud Keychain disabled, …).
        let syncedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(syncedQuery as CFDictionary, nil)
        if status != errSecSuccess {
            let localQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ]
            status = SecItemAdd(localQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "ContentKeyStore", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain write failed"])
        }
    }
}

// MARK: - API key storage (Keychain)

/// Stores the cloud `api_key` in Keychain so it survives UserDefaults wipes
/// (app reinstall, iOS storage pressure, etc.). Without this, an emptied
/// UserDefaults triggers `ensureRegisteredIfCloud()` to register a fresh key,
/// silently rotating the user's identity and breaking any external clients
/// (Agent, MCP) configured with the old key.
final class ApiKeyStore {
    static let shared = ApiKeyStore()

    private static let service = "com.feedling.mcp"
    private static let account = "api_key"

    private init() {}

    func wipe() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    /// Saves `key` to Keychain. Empty key is treated as a wipe so callers
    /// that go through `persist()` clear the stored key when they zero `apiKey`.
    func save(_ key: String) {
        if key.isEmpty {
            _ = wipe()
            return
        }
        let data = Data(key.utf8)

        // Wipe any prior entry so we don't leave a stale shadow.
        let wipeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(wipeQuery as CFDictionary)

        // Prefer iCloud-synced; fall back to device-local.
        let syncedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(syncedQuery as CFDictionary, nil)
        if status != errSecSuccess {
            let localQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ]
            _ = SecItemAdd(localQuery as CFDictionary, nil)
        }
    }
}

// MARK: - Keypair storage (Keychain)

/// Generates a P-256 Curve25519 keypair at first launch, stores the private
/// half in Keychain, and returns the public half (raw bytes, base64). The
/// public key is uploaded to the server so future features (E2E encryption of
/// user content) can use it; for now it's just registered and parked.
final class KeyStore {
    static let shared = KeyStore()

    private static let service = "com.feedling.mcp"
    private static let account = "identity_private_key"

    private init() {}

    /// Delete the identity private key from Keychain. Used by Phase B's
    /// reset flow.
    func wipeKeypair() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func ensureKeypairAndReturnPublicKeyBase64() throws -> String {
        if let existing = try loadPrivateKey() {
            return existing.publicKey.rawRepresentation.base64EncodedString()
        }
        let pk = Curve25519.KeyAgreement.PrivateKey()
        try save(privateKey: pk)
        return pk.publicKey.rawRepresentation.base64EncodedString()
    }

    private func save(privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        let data = privateKey.rawRepresentation
        let wipeQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(wipeQuery as CFDictionary)
        let syncedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(syncedQuery as CFDictionary, nil)
        if status != errSecSuccess {
            let localQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: Self.account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: data,
            ]
            status = SecItemAdd(localQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "KeyStore", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain write failed"])
        }
    }

    private func loadPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
}

// MARK: - Attestation fetch TLS shim

/// Accepts the enclave's self-signed TLS cert so the startup-time
/// attestation refresh can pull the enclave's content pubkey without
/// CA-chain validation. Trust is established downstream by
/// AuditCardView.PinningCaptureDelegate, which compares sha256(cert.DER)
/// to the fingerprint bound into REPORT_DATA.
final class AttestationTrustShim: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}


// ============================================================================
// Cinnabar design tokens — Feedling visual identity.
// Source of truth: DESIGN.md at the repo root.
// All UI files must import these tokens; no raw hex / raw font strings.
// ============================================================================

// MARK: - Color palette

extension Color {

    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    // Background — warm parchment
    static let cinBg          = Color(hex: "#f3eee2")
    // Primary ink — warm near-black
    static let cinFg          = Color(hex: "#1a1814")
    // Subdued text — warm mid-grey
    static let cinSub         = Color(hex: "#7a7065")
    // Hairline rules
    static let cinLine        = Color(hex: "#d6cfc0")
    // Accent 1 — 朱砂 cinnabar (agent messages, highlights)
    static let cinAccent1     = Color(hex: "#b8442e")
    // Accent 1 soft — warm tint for agent bubble fill
    static let cinAccent1Soft = Color(hex: "#f0e8df")
    // Accent 2 — 群青 indigo (user messages)
    static let cinAccent2     = Color(hex: "#2c4a6b")
    // Accent 2 soft — cool tint (reserved for user-side elements)
    static let cinAccent2Soft = Color(hex: "#dce4ee")
}

// MARK: - Typography

extension Font {
    static func newsreader(size: CGFloat, italic: Bool = false) -> Font {
        if italic {
            return Font.custom("Newsreader-Italic-VariableFont_opsz,wght", size: size)
        }
        return Font.custom("Newsreader-VariableFont_opsz,wght", size: size)
    }

    static func notoSerifSC(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium: return Font.custom("NotoSerifSC-Medium", size: size)
        default:      return Font.custom("NotoSerifSC-Regular", size: size)
        }
    }

    static func dmMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium: return Font.custom("DMMono-Medium", size: size)
        default:      return Font.custom("DMMono-Regular", size: size)
        }
    }

    static func interTight(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium: return Font.custom("InterTight-Medium", size: size)
        default:      return Font.custom("InterTight-Regular", size: size)
        }
    }
}

// MARK: - Spacing

enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 32
    static let xl2: CGFloat = 48
    static let xl3: CGFloat = 64
}

// MARK: - Button styles

struct CinPrimaryButtonStyle: ButtonStyle {
    var destructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dmMono(size: 10, weight: .medium))
            .kerning(2.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.cinBg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background((destructive ? Color.cinAccent2 : Color.cinFg).opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Rectangle())
    }
}

struct CinSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dmMono(size: 10))
            .kerning(2.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.cinFg)
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(Rectangle().stroke(Color.cinFg, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Motion

enum FeedlingMotion {
    static let micro:  Double = 0.1
    static let short:  Double = 0.25
    static let medium: Double = 0.35
    static let long:   Double = 0.5

    static let spring: Animation = .spring(response: 0.35, dampingFraction: 0.82)
    static let enter:  Animation = .easeOut(duration: 0.35)
    static let exit:   Animation = .easeIn(duration: 0.25)
}

// MARK: - Legacy token aliases (used by utility screens — do not use in new code)

extension Color {
    static var feedlingSage:    Color { .cinAccent1 }
    static var feedlingPaper:   Color { .cinBg }
    static var feedlingSurface: Color { .cinBg }
    static var feedlingInk:     Color { .cinFg }
    static var feedlingInkMuted:Color { .cinSub }
    static var feedlingDivider: Color { .cinLine }
}

extension Font {
    static func feedlingMono(size: CGFloat = 13) -> Font { .dmMono(size: size) }
}

typealias FeedlingPrimaryButtonStyle   = CinPrimaryButtonStyle
typealias FeedlingSecondaryButtonStyle = CinSecondaryButtonStyle

// View modifiers used by onboarding + utility screens
enum FeedlingDisplaySize { case large, medium, small }

extension View {
    func feedlingBody() -> some View {
        self.font(.notoSerifSC(size: 14)).foregroundStyle(Color.cinFg)
    }
    func feedlingCaption() -> some View {
        self.font(.interTight(size: 11)).foregroundStyle(Color.cinSub)
    }
    @ViewBuilder
    func feedlingDisplay(_ size: FeedlingDisplaySize = .medium) -> some View {
        switch size {
        case .large:  self.font(.newsreader(size: 34)).foregroundStyle(Color.cinFg)
        case .medium: self.font(.newsreader(size: 28)).foregroundStyle(Color.cinFg)
        case .small:  self.font(.newsreader(size: 22)).foregroundStyle(Color.cinFg)
        }
    }
}

// MARK: - Concurrency helpers

private final class LockBox: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    /// Sets value to true if currently false. Returns true if this call won the race.
    func setIfFalse() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }
}
