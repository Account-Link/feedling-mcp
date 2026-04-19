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
    private static let defaultCloudURL = "http://54.209.126.4:5001"     // TODO: flip to https://api.feedling.app when HTTPS is live

    // MARK: - Published credentials (drives UI)

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published private(set) var userId: String
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
        // Phase 2: Phala dstack-pha-prod5 CVM feedling-enclave.
        // app_id = 051a174f2457a6c474680a5d745372398f97b6ad
        // compose_hash on-chain @ 0x6c8A6f1e3eD4180B2048B808f7C4b2874649b88F
        // (Eth Sepolia tx 0xdfbc0b8d…). See deploy/DEPLOYMENTS.md §Phase 2.
        return URL(string: "https://051a174f2457a6c474680a5d745372398f97b6ad-5003.dstack-pha-prod5.phala.network/attestation")
    }

    /// Load (or lazily generate) the user's long-lived content keypair.
    /// Backed by Keychain entries distinct from the identity keypair.
    func ensureContentKeypair() {
        if userContentPublicKey != nil { return }
        do {
            let sk = try ContentKeyStore.shared.ensureContentKeypair()
            userContentPublicKey = sk.publicKey
        } catch {
            print("[content-keypair] failed to load/generate: \(error)")
        }
    }

    /// Hit the enclave's /attestation endpoint, pull out the content pubkey,
    /// compose_hash, MRTD. Does NOT (yet) run the full DCAP verification —
    /// that's the audit card's job. This method is fire-and-forget from
    /// the app-startup hook.
    func refreshEnclaveAttestation() async {
        guard let url = attestationURL else { return }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
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
