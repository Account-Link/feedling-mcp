import CryptoKit
import Foundation
import Security

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
        self.apiKey = ProcessInfo.processInfo.environment["FEEDLING_API_KEY"]
            ?? defaults.string(forKey: Keys.apiKey)
            ?? ""
        self.userId = defaults.string(forKey: Keys.userId) ?? ""
        self.storageMode = StorageMode(rawValue: defaults.string(forKey: Keys.storageMode) ?? "") ?? .cloud
        syncToAppGroup()
    }

    // MARK: - Public config

    /// Point the app at a self-hosted server. Clears any previously stored
    /// cloud-registration api_key — the user provides their own.
    func configureSelfHosted(url: String, apiKey: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        self.storageMode = .selfHosted
        self.baseURL = cleanedURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userId = ""
        UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
        persist()
    }

    /// Go back to Feedling cloud. Triggers registration on next launch if we
    /// don't already hold cloud credentials.
    func configureCloud() {
        self.storageMode = .cloud
        self.baseURL = Self.defaultCloudURL
        self.apiKey = ""
        self.userId = ""
        UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
        persist()
    }

    /// Overwrite credentials with a fresh (user_id, api_key) — used after `register()`.
    fileprivate func setCredentials(userId: String, apiKey: String) {
        self.userId = userId
        self.apiKey = apiKey
        UserDefaults.standard.set(true, forKey: Keys.hasRegistered)
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: Keys.baseURL)
        d.set(apiKey, forKey: Keys.apiKey)
        d.set(userId, forKey: Keys.userId)
        d.set(storageMode.rawValue, forKey: Keys.storageMode)
        syncToAppGroup()
    }

    private func syncToAppGroup() {
        guard let shared = UserDefaults(suiteName: Self.appGroup) else { return }
        shared.set(baseURL, forKey: Keys.baseURL)
        shared.set(apiKey, forKey: Keys.apiKey)
        shared.set(userId, forKey: Keys.userId)
        // The broadcast extension uses `ingestToken` as a WebSocket Bearer.
        shared.set(apiKey, forKey: "ingest_ws_token")
    }

    // MARK: - Registration

    /// Multi-tenant cloud registration. Generates a P-256 keypair, stores the
    /// private key in Keychain, uploads the public key, and captures the
    /// returned (user_id, api_key). Idempotent: if already registered, no-ops.
    func ensureRegisteredIfCloud() async {
        guard storageMode == .cloud else { return }
        guard apiKey.isEmpty else { return }                                  // already have creds
        if UserDefaults.standard.bool(forKey: Keys.registrationFailed) { return }  // backoff: try again on next manual toggle

        do {
            let pubB64 = try KeyStore.shared.ensureKeypairAndReturnPublicKeyBase64()
            let body: [String: Any] = ["public_key": pubB64]
            let data = try JSONSerialization.data(withJSONObject: body)

            guard let url = URL(string: "\(baseURL)/v1/users/register") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data

            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }

            if http.statusCode == 403 {
                // Single-user backend — no registration needed. Treat empty apiKey as OK.
                print("[register] backend is single-user; skipping registration")
                UserDefaults.standard.set(true, forKey: Keys.hasRegistered)
                return
            }
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

    /// If we have an api_key but no user_id (e.g. the key was injected via
    /// env/config rather than created by register()), populate user_id by
    /// hitting /v1/users/whoami. Idempotent.
    func ensureUserIdIfNeeded() async {
        guard !apiKey.isEmpty, userId.isEmpty else { return }
        guard let req = authorizedRequest(path: "/v1/users/whoami") else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            struct Who: Decodable { let user_id: String }
            let w = try JSONDecoder().decode(Who.self, from: data)
            if !w.user_id.isEmpty {
                self.userId = w.user_id
                UserDefaults.standard.set(w.user_id, forKey: Keys.userId)
                syncToAppGroup()
                print("[whoami] resolved user_id=\(w.user_id)")
            }
        } catch {
            print("[whoami] failed: \(error)")
        }
    }

    /// Discard current credentials and regenerate. Asks server to register fresh.
    func regenerateCredentials() async {
        self.apiKey = ""
        self.userId = ""
        UserDefaults.standard.set(false, forKey: Keys.hasRegistered)
        UserDefaults.standard.set(false, forKey: Keys.registrationFailed)
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

    /// URL for the /attestation endpoint. Defaults to the cloud MCP host;
    /// in self-hosted mode it swaps to the user's own.
    private var attestationURL: URL? {
        if let override = ProcessInfo.processInfo.environment["FEEDLING_ATTESTATION_URL"],
           let u = URL(string: override) {
            return u
        }
        if storageMode == .selfHosted {
            let mcp = baseURL.replacingOccurrences(of: "api.", with: "mcp.")
            return URL(string: "\(mcp)/attestation")
        }
        // Phase 3: Phala dstack-pha-prod5 CVM with in-enclave TLS.
        // The `-5003s.` suffix tells dstack-gateway to pass TLS through
        // to the CVM instead of terminating — the TLS cert presented to
        // the client originates inside the enclave and is bound to
        // compose_hash via REPORT_DATA. See deploy/DEPLOYMENTS.md §Phase 3.
        return URL(string: "https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation")
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

    /// Silently migrate any pre-existing v0 plaintext chat messages +
    /// memory moments into v1 envelopes. Runs on the first app launch
    /// after the Phase A update. Idempotent: the UserDefaults flag
    /// prevents re-runs, and the server-side endpoint no-ops items
    /// already in v1 state.
    ///
    /// Identity is intentionally skipped — `identity.nudge` can't
    /// mutate a v1 card until Phase C (MCP in TEE adds
    /// decrypt-mutate-rewrap). Migrating identity before nudge supports
    /// v1 would trap users who already ran `feedling.identity.init`.
    ///
    /// Non-blocking: called from the app-startup `.task`; nothing on
    /// the UI depends on its completion. If it fails transiently, the
    /// flag stays false and the next launch retries.
    func runSilentV1MigrationIfNeeded() async {
        let defaultsKey = "feedling.migrationV0toV1Done.2026-04-20"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        // Need all three to build envelopes for other-authored v0 items.
        guard let userPK = userContentPublicKey,
              let enclavePK = enclaveContentPublicKey,
              !userId.isEmpty else {
            print("[migration] skipping: crypto material not ready yet")
            return
        }

        var items: [[String: Any]] = []
        do {
            items.append(contentsOf: try await collectV0ChatEnvelopes(userPK: userPK, enclavePK: enclavePK))
            items.append(contentsOf: try await collectV0MemoryEnvelopes(userPK: userPK, enclavePK: enclavePK))
        } catch {
            print("[migration] collection failed: \(error)")
            return
        }
        if items.isEmpty {
            // Nothing to migrate — set flag so future launches skip immediately.
            UserDefaults.standard.set(true, forKey: defaultsKey)
            print("[migration] no v0 items to re-wrap; marked done")
            return
        }

        // Send in batches of 100 so servers + clients don't hold giant bodies.
        let batchSize = 100
        var allOk = true
        var totals = (ok: 0, alreadyV1: 0, notFound: 0, error: 0)
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batch = Array(items[batchStart..<min(batchStart + batchSize, items.count)])
            let result = await postRewrap(items: batch)
            switch result {
            case .failure(let err):
                print("[migration] batch \(batchStart) failed: \(err)")
                allOk = false
            case .success(let summary):
                totals.ok += summary.ok
                totals.alreadyV1 += summary.alreadyV1
                totals.notFound += summary.notFound
                totals.error += summary.error
                if summary.error > 0 { allOk = false }
            }
        }
        print("[migration] done ok=\(totals.ok) already_v1=\(totals.alreadyV1) not_found=\(totals.notFound) error=\(totals.error)")
        if allOk {
            UserDefaults.standard.set(true, forKey: defaultsKey)
        }
    }

    private struct RewrapSummary { let ok, alreadyV1, notFound, error: Int }

    private func collectV0ChatEnvelopes(
        userPK: Curve25519.KeyAgreement.PublicKey,
        enclavePK: Curve25519.KeyAgreement.PublicKey
    ) async throws -> [[String: Any]] {
        guard let req = authorizedRequest(
            path: "/v1/chat/history",
            queryItems: [URLQueryItem(name: "since", value: "0"), URLQueryItem(name: "limit", value: "500")])
        else { return [] }
        let (data, _) = try await URLSession.shared.data(for: req)
        struct History: Decodable {
            let messages: [Row]
            struct Row: Decodable {
                let id: String
                let content: String?
                let v: Int?
            }
        }
        let hist = try JSONDecoder().decode(History.self, from: data)
        var out: [[String: Any]] = []
        for row in hist.messages {
            let version = row.v ?? 0
            guard version == 0, let content = row.content, !content.isEmpty else { continue }
            do {
                let env = try ContentEncryption.envelope(
                    plaintext: Data(content.utf8),
                    ownerUserID: userId,
                    userContentPK: userPK,
                    enclaveContentPK: enclavePK,
                    visibility: .shared,
                    itemID: row.id)
                out.append(["type": "chat", "id": row.id, "envelope": env.jsonBody()["envelope"] as Any])
            } catch {
                print("[migration] skip chat id=\(row.id): \(error)")
            }
        }
        return out
    }

    private func collectV0MemoryEnvelopes(
        userPK: Curve25519.KeyAgreement.PublicKey,
        enclavePK: Curve25519.KeyAgreement.PublicKey
    ) async throws -> [[String: Any]] {
        guard let req = authorizedRequest(
            path: "/v1/memory/list",
            queryItems: [URLQueryItem(name: "limit", value: "200")])
        else { return [] }
        let (data, _) = try await URLSession.shared.data(for: req)
        struct MemList: Decodable {
            let moments: [Row]
            struct Row: Decodable {
                let id: String
                let title: String?
                let description: String?
                let type: String?
                let v: Int?
            }
        }
        let list = try JSONDecoder().decode(MemList.self, from: data)
        var out: [[String: Any]] = []
        for row in list.moments {
            let version = row.v ?? 0
            guard version == 0 else { continue }
            let inner: [String: String] = [
                "title": row.title ?? "",
                "description": row.description ?? "",
                "type": row.type ?? "",
            ]
            guard let innerData = try? JSONSerialization.data(withJSONObject: inner) else { continue }
            do {
                let env = try ContentEncryption.envelope(
                    plaintext: innerData,
                    ownerUserID: userId,
                    userContentPK: userPK,
                    enclaveContentPK: enclavePK,
                    visibility: .shared,
                    itemID: row.id)
                out.append(["type": "memory", "id": row.id, "envelope": env.jsonBody()["envelope"] as Any])
            } catch {
                print("[migration] skip memory id=\(row.id): \(error)")
            }
        }
        return out
    }

    private func postRewrap(items: [[String: Any]]) async -> Result<RewrapSummary, Error> {
        do {
            let body = try JSONSerialization.data(withJSONObject: ["items": items])
            guard let req = authorizedRequest(path: "/v1/content/rewrap", method: "POST", body: body) else {
                return .failure(NSError(domain: "Migration", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "could not build request"]))
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(NSError(domain: "Migration", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                                        userInfo: [NSLocalizedDescriptionKey: "rewrap HTTP error"]))
            }
            struct Resp: Decodable {
                let summary: Summary
                struct Summary: Decodable { let ok: Int; let already_v1: Int; let not_found: Int; let error: Int }
            }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            return .success(RewrapSummary(
                ok: decoded.summary.ok,
                alreadyV1: decoded.summary.already_v1,
                notFound: decoded.summary.not_found,
                error: decoded.summary.error))
        } catch {
            return .failure(error)
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
