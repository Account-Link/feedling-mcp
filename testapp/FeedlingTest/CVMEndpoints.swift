import Foundation

/// Centralized source of truth for every URL the iOS app constructs against
/// the Phala TDX CVM. A single appId + gatewayDomain pair drives every
/// derived URL so the migration to a new CVM (new app_id, new node) is a
/// one-place change — no grepping for hex strings.
///
/// Override order: ProcessInfo env var → UserDefaults → baked default.
/// The env-var hook exists so `SIMCTL_CHILD_FEEDLING_CVM_APP_ID=…` works in
/// simulator runs; UserDefaults lets a user flip endpoints in-app without a
/// rebuild; the default is what ships to the App Store.
///
/// Production runs on Phala prod9 with dstack-ingress multi-domain TXT
/// routing (prod5/prod7 don't support `_dstack-app-address.<domain>`
/// records, which is why we migrated off them). Defaults below point at
/// the live prod9 CVM. To test against a different CVM without a rebuild,
/// set `feedling.cvm.appId` / `feedling.cvm.gatewayDomain` in UserDefaults.
enum CVMEndpoints {

    // MARK: - Tunable defaults (update on each CVM migration)

    /// Phala dstack App ID of the production CVM. Appears as the hex prefix
    /// in dstack-gateway URLs (`<appId>-<port>s.<gatewayDomain>`).
    static let defaultAppId: String = "9798850e096d770293c67305c6cfdceed68c1d28"

    /// dstack-gateway cluster hostname. prod9 is the only public cluster
    /// that supports TXT-based custom-domain routing — required by
    /// dstack-ingress 2.2 multi-domain config.
    static let defaultGatewayDomain: String = "dstack-pha-prod9.phala.network"

    /// Public custom domain for the Flask API (routed via ingress).
    static let apiHost: String = "api.feedling.app"

    /// Public custom domain for the MCP SSE server (routed via ingress).
    static let mcpHost: String = "mcp.feedling.app"

    // MARK: - Override plumbing

    private enum Keys {
        static let appId = "feedling.cvm.appId"
        static let gatewayDomain = "feedling.cvm.gatewayDomain"
    }

    static var appId: String {
        if let env = ProcessInfo.processInfo.environment["FEEDLING_CVM_APP_ID"], !env.isEmpty {
            return env
        }
        if let override = UserDefaults.standard.string(forKey: Keys.appId), !override.isEmpty {
            return override
        }
        return defaultAppId
    }

    static var gatewayDomain: String {
        if let env = ProcessInfo.processInfo.environment["FEEDLING_CVM_GATEWAY_DOMAIN"], !env.isEmpty {
            return env
        }
        if let override = UserDefaults.standard.string(forKey: Keys.gatewayDomain), !override.isEmpty {
            return override
        }
        return defaultGatewayDomain
    }

    /// Call from Settings UI (or a launch-arg debug affordance) to flip the
    /// app at a newly-deployed CVM without a rebuild. Empty string = reset
    /// to default.
    static func setAppId(_ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.appId)
        } else {
            UserDefaults.standard.set(value, forKey: Keys.appId)
        }
    }

    static func setGatewayDomain(_ value: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.gatewayDomain)
        } else {
            UserDefaults.standard.set(value, forKey: Keys.gatewayDomain)
        }
    }

    // MARK: - Derived URLs

    /// `https://<appId>-5003s.<gateway>/attestation` — TLS-passthrough route;
    /// cert presented is the enclave's own, fingerprint bound via REPORT_DATA.
    static var attestationURL: URL? {
        URL(string: "https://\(appId)-5003s.\(gatewayDomain)/attestation")
    }

    /// `wss://<appId>-9998.<gateway>/ingest` — TLS-terminated at gateway; the
    /// ingest stream is app-layer encrypted (FrameEnvelope v1) so gateway
    /// TLS is sufficient for transport hygiene. Port 9998 intentionally not
    /// in the ingress routing map (would require another custom domain).
    static var wsIngestURL: String {
        "wss://\(appId)-9998.\(gatewayDomain)/ingest"
    }

    /// `https://api.feedling.app` — terminated by dstack-ingress inside the CVM.
    static var apiURL: String {
        "https://\(apiHost)"
    }

    /// `https://mcp.feedling.app` — terminated by dstack-ingress inside the CVM.
    static var mcpURL: String {
        "https://\(mcpHost)"
    }
}
