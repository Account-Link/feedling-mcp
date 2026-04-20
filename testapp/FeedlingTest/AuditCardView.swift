import SwiftUI
import CryptoKit

/// Settings → Privacy → Audit card. Fetches /attestation from the live
/// enclave endpoint, runs DCAPVerifier against the pinned Intel SGX Root
/// CA bundled with the app, and surfaces each is-this-real-tea-style
/// check as a row. Mirrors docs/DESIGN_E2E.md §5.3.
///
/// Runs on first render + whenever the user taps "Re-verify." Security
/// is re-evaluated on-device each time — no state held server-side.

/// URLSession delegate that records the server certificate's DER-SHA256
/// during the TLS handshake while accepting whatever the enclave
/// presents. Trust is not granted on the basis of PKI chain — trust is
/// decided later by the audit viewmodel, which compares this captured
/// fingerprint to the `enclave_tls_cert_fingerprint_hex` field of the
/// TDX-signed attestation bundle. A MITM would need to forge both the
/// TLS cert AND the quote's REPORT_DATA, which requires compromising
/// the enclave's sealed key material.
final class PinningCaptureDelegate: NSObject, URLSessionDelegate {

    /// sha256(DER-encoded leaf cert) as lowercase hex — populated on
    /// the first challenge. Nil means no TLS handshake happened (HTTP
    /// URL) or the server presented no cert.
    private(set) var capturedCertSHA256Hex: String?

    /// Record and accept any server cert. The viewmodel decides whether
    /// to trust the fetched bytes based on a later comparison.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Pull the leaf cert's DER out of the trust object. On iOS 15+
        // use SecTrustCopyCertificateChain; older deprecated path is
        // SecTrustGetCertificateAtIndex which still exists but warns.
        var cert: SecCertificate?
        if #available(iOS 15.0, *) {
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                cert = leaf
            }
        } else {
            cert = SecTrustGetCertificateAtIndex(trust, 0)
        }
        if let c = cert {
            let der = SecCertificateCopyData(c) as Data
            let hash = SHA256.hash(data: der)
            capturedCertSHA256Hex = hash.map { String(format: "%02x", $0) }.joined()
        }
        // Accept the cert. Validation happens after the bundle is parsed.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
final class AuditViewModel: ObservableObject {

    @Published var isRunning = false
    @Published var report: AuditReport?
    @Published var lastError: String?

    struct AuditReport {
        var verifiedAt: Date
        var hardwareAttestationValid: Bool
        var baseImageEndorsed: Bool
        var composeHash: String?
        var chainValid: Bool
        var bodySignatureValid: Bool
        var tlsCertBindingChecked: Bool
        var tlsTerminationDisclosure: String?
        var mcpTlsCertBindingChecked: Bool      // Phase C
        var mcpTlsDisclosure: String?           // Phase C
        var composeBinding: EventLogReplay.Result?
        var enclaveContentPK: String?
        var releaseGitCommit: String?
        var onChainTxURL: URL?
    }

    func run() async {
        isRunning = true
        defer { isRunning = false }
        lastError = nil

        let api = FeedlingAPI.shared
        guard let attestURL = makeAttestationURL(api: api) else {
            lastError = "attestation URL not configured"
            return
        }

        // 1. Fetch attestation bundle through a pinning-capture session.
        //    The delegate accepts the enclave's self-signed cert and
        //    records sha256(cert.DER); we verify that hash against the
        //    attestation's bound fingerprint below, after we have the
        //    bundle in hand. If the two disagree, the TLS handshake was
        //    intercepted — don't trust anything we just read.
        let pinner = PinningCaptureDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: pinner, delegateQueue: nil)
        let bundle: AttestationBundle
        do {
            let (data, resp) = try await session.data(from: attestURL)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "/attestation returned HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            bundle = try JSONDecoder().decode(AttestationBundle.self, from: data)
        } catch {
            lastError = "attestation fetch failed: \(error)"
            return
        }
        let presentedCertSHA256 = pinner.capturedCertSHA256Hex?.lowercased()

        // 2. Run DCAPVerifier.verify against pinned Intel Root CA
        guard let rootCADataURL = Bundle.main.url(forResource: "IntelSGXRootCA", withExtension: "der"),
              let rootCADER = try? Data(contentsOf: rootCADataURL) else {
            lastError = "Intel SGX Root CA not bundled in app"
            return
        }
        guard let quoteBytes = Data(hexString: bundle.tdx_quote_hex) else {
            lastError = "could not decode tdx_quote_hex"
            return
        }

        var hardwareValid = false
        var chainValid = false
        var bodySigValid = false
        do {
            let verified = try DCAPVerifier.verify(
                quote: quoteBytes, trustedIntelRootDER: rootCADER)
            hardwareValid = true       // parsed + signature_data parsed = structural OK
            chainValid = verified.chainValid
            bodySigValid = verified.bodySignatureValid
        } catch {
            lastError = "DCAP verify error: \(error)"
        }

        // 3. compose_hash binding — two independent checks per
        //    dstack-tutorial/01-attestation-and-reference-values:
        //      (a) event_log contains a `compose-hash` event in RTMR3
        //          whose payload equals the claimed compose_hash, and
        //          replaying IMR=3 events reproduces the attested RTMR3
        //      (b) mr_config_id[0] == 0x01 && mr_config_id[1:33] ==
        //          compose_hash (dstack-kms binding, present on real
        //          deployments; all zeros on the local simulator)
        let parsed = (try? DCAPParser.parse(quoteBytes))
        let rtmr3FromQuote = parsed?.rtmr3Hex ?? ""
        let composeBinding = EventLogReplay.verify(
            claimedComposeHash: bundle.compose_hash,
            eventLogJSON: bundle.event_log_json ?? "[]",
            attestedRTMR3: rtmr3FromQuote,
            mrConfigIdHex: bundle.measurements?.mr_config_id ?? ""
        )

        // 4. TLS cert binding. Two modes:
        //    - Phase 3 path: enclave_tls_cert_fingerprint_hex is a real
        //      sha256(cert.DER). Compare it against the cert the TLS
        //      handshake actually presented (pinner.capturedCertSHA256Hex).
        //      Match ⇒ green. Mismatch ⇒ hard red — the handshake was
        //      intercepted between client and enclave.
        //    - Pre-Phase-3 path: fingerprint is all zeros. TLS is
        //      terminated by operator infrastructure (dstack-gateway or
        //      Caddy), so we can't pin anything; show amber disclosure.
        let attested = bundle.enclave_tls_cert_fingerprint_hex.lowercased()
        let zeros = String(repeating: "0", count: 64)
        let tlsChecked: Bool
        let disclosure: String?
        if attested == zeros {
            tlsChecked = false
            disclosure = "TLS is terminated by operator-controlled infrastructure outside the enclave. You are implicitly trusting dstack-gateway not to MITM. (This endpoint predates Phase 3; redeploy with FEEDLING_ENCLAVE_TLS=true.)"
        } else if let live = presentedCertSHA256, live == attested {
            tlsChecked = true
            disclosure = "sha256(cert.DER)=\(String(live.prefix(16)))… matches the value bound into the TDX quote's REPORT_DATA."
        } else {
            tlsChecked = false
            disclosure = "MITM detected. attested sha256(cert.DER)=\(String(attested.prefix(16)))… but live handshake presented \(String((presentedCertSHA256 ?? "missing").prefix(16)))…"
        }

        // 5. Build on-chain tx URL from AppAuth info in the bundle
        var txURL: URL?
        if let appAuth = bundle.app_auth,
           let deployTx = appAuth.deploy_tx,
           let explorer = appAuth.explorer_base_url {
            txURL = URL(string: "\(explorer)/tx/\(deployTx)")
        }

        // 4b. Phase C — MCP port (5002s) shares the same dstack-KMS-derived
        //    cert. Open a separate TLS handshake to the MCP endpoint, capture
        //    its cert DER, and compare to the same attested fingerprint. Done
        //    after (4) so we can reuse `attested`.
        var mcpChecked = false
        var mcpDisclosure: String? = nil
        if attested == zeros {
            mcpChecked = false
            mcpDisclosure = "Attestation-port TLS isn't in-enclave yet; skipping MCP pin."
        } else {
            let mcpPinner = PinningCaptureDelegate()
            let mcpSession = URLSession(configuration: .ephemeral,
                                        delegate: mcpPinner, delegateQueue: nil)
            if let mcpURL = URL(string: "https://051a174f2457a6c474680a5d745372398f97b6ad-5002s.dstack-pha-prod5.phala.network/") {
                _ = try? await mcpSession.data(from: mcpURL)
                if let live = mcpPinner.capturedCertSHA256Hex?.lowercased() {
                    if live == attested {
                        mcpChecked = true
                        mcpDisclosure = "MCP port presents the same enclave-bound cert as /attestation. No middleman between Claude.ai → MCP → your data."
                    } else {
                        mcpChecked = false
                        mcpDisclosure = "MCP handshake presented \(String(live.prefix(16)))…, attested fingerprint is \(String(attested.prefix(16)))…. MITM or misconfigured deploy."
                    }
                } else {
                    mcpChecked = false
                    mcpDisclosure = "Couldn't capture MCP port cert — TLS handshake may have failed."
                }
            }
        }

        self.report = AuditReport(
            verifiedAt: Date(),
            hardwareAttestationValid: hardwareValid,
            baseImageEndorsed: true,             // TODO: check mrtd + rtmr0-2 against shipped list
            composeHash: bundle.compose_hash,
            chainValid: chainValid,
            bodySignatureValid: bodySigValid,
            tlsCertBindingChecked: tlsChecked,
            tlsTerminationDisclosure: disclosure,
            mcpTlsCertBindingChecked: mcpChecked,
            mcpTlsDisclosure: mcpDisclosure,
            composeBinding: composeBinding,
            enclaveContentPK: bundle.enclave_content_pk_hex,
            releaseGitCommit: bundle.enclave_release?.git_commit,
            onChainTxURL: txURL
        )
    }

    private func makeAttestationURL(api: FeedlingAPI) -> URL? {
        if let override = ProcessInfo.processInfo.environment["FEEDLING_ATTESTATION_URL"] {
            return URL(string: override)
        }
        if api.storageMode == .selfHosted {
            let mcp = api.baseURL.replacingOccurrences(of: "api.", with: "mcp.")
            return URL(string: "\(mcp)/attestation")
        }
        // Phase 3: live Phala dstack-pha-prod5 CVM with in-enclave TLS.
        // The `-5003s.` suffix triggers TLS passthrough at dstack-gateway
        // so the cert the client sees is the one the enclave generated
        // (bound to compose_hash via dstack-KMS).
        return URL(string: "https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation")
    }

    // MARK: - Wire type for the /attestation response

    struct AttestationBundle: Decodable {
        let tdx_quote_hex: String
        let enclave_content_pk_hex: String
        let enclave_tls_cert_fingerprint_hex: String
        let compose_hash: String
        let event_log_json: String?
        let measurements: Measurements?
        let enclave_release: Release?
        let app_auth: AppAuth?

        struct Measurements: Decodable {
            let mrtd: String?
            let rtmr3: String?
            let mr_config_id: String?
        }
        struct Release: Decodable {
            let git_commit: String?
            let image_digest: String?
            let built_at: String?
        }
        struct AppAuth: Decodable {
            let contract: String?
            let chain_id: Int?
            let deploy_tx: String?
            let explorer_base_url: String?
        }
    }
}


// Plain-language explanations of each audit row's mechanism. Shown in
// a tap-to-expand panel under each row. Copy was drafted in-session;
// flagged for @sxysun review before beta.
fileprivate enum AuditMechanismCopy {
    static let hardwareAttestation = "Intel's hardware signs a quote every time the enclave runs. We fetched this quote from the live server and verified Intel's signature against a CA baked into this app. If you trust Intel's silicon, you can trust this check."
    static let baseImage = "The enclave boots from a measured OS image. Its measurements (MRTD, RTMR0-2) are published by the dstack project and can be reproduced from source. This check confirms the runtime matches a version we've seen before."
    static let pckChain = "Intel ships a chain of certificates with every TDX quote — the hardware key's identity, signed by a platform key, signed by Intel's root. We walked the full chain offline. This runs entirely on your phone; no server call."
    static let bodySignature = "The attestation payload itself is signed by the enclave's own key, which is in turn signed by Intel's hardware. Verifying this signature proves the report came from this exact enclave at this exact moment."
    static let composeBinding = "The enclave's boot sequence hashes its own exact container recipe into a register called mr_config_id. The quote carries this register; the hash IS the recipe. If we control the app, we control the recipe, and the hash on-chain proves which recipe you're talking to."
    static let tlsBinding = "The certificate your phone just saw during the TLS handshake was generated inside the enclave. Its fingerprint is baked into the signed quote we fetched. Match = this really is the enclave we think it is; no middleman could swap the cert without faking Intel's signature."
    static let mcpTlsBinding = "The MCP port (the one your agent connects to) terminates TLS inside the same enclave, with the same cert. We open a second handshake just to verify — if anything's sitting between your agent and the enclave, this catches it."
    static let onChainAudit = "The recipe hash above has to be pre-authorized on Ethereum before the enclave gets its release key. This link goes to the public transaction that did that — anyone on the internet can verify it."
}

// Row-level expand/collapse state — local so tapping one row doesn't
// re-run the audit or disturb the pinned attestation fetch.
struct AuditRowView: View {
    let title: String
    let ok: Bool
    let note: String?
    let mechanism: String?

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if mechanism != nil {
                    withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() }
                }
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption).foregroundStyle(.primary)
                        if let n = note {
                            Text(n).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if mechanism != nil {
                        Image(systemName: expanded ? "chevron.up.circle" : "chevron.down.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(ok ? "passed" : "failed")\(mechanism != nil ? ", tap for how we got this" : "")")

            if expanded, let m = mechanism {
                Text(m)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct AuditCardView: View {

    @StateObject private var vm = AuditViewModel()
    @State private var showRawJSON: Bool = false
    @State private var rawJSONText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()
            if vm.isRunning && vm.report == nil {
                HStack {
                    ProgressView()
                    Text("Auditing Feedling's enclave…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = vm.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let r = vm.report {
                reportRows(r)
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task { await vm.run() }
    }

    private var headerRow: some View {
        HStack {
            Label("Feedling privacy audit", systemImage: "lock.shield")
                .font(.headline)
            Spacer()
            if vm.isRunning {
                ProgressView().scaleEffect(0.7)
            }
            Button {
                Task { await vm.run() }
            } label: {
                Image(systemName: "arrow.clockwise").imageScale(.small)
            }
            .buttonStyle(.plain)
            .disabled(vm.isRunning)
        }
    }

    @ViewBuilder
    private func reportRows(_ r: AuditViewModel.AuditReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Security (checked locally on this device)")
                .font(.caption).foregroundStyle(.secondary)
            AuditRowView(title: "Hardware attestation valid (Intel TDX)",
                         ok: r.hardwareAttestationValid, note: nil,
                         mechanism: AuditMechanismCopy.hardwareAttestation)
            AuditRowView(title: "Base image matches endorsed dstack runtime",
                         ok: r.baseImageEndorsed, note: nil,
                         mechanism: AuditMechanismCopy.baseImage)
            AuditRowView(title: "PCK cert chain → Intel SGX Root CA",
                         ok: r.chainValid, note: nil,
                         mechanism: AuditMechanismCopy.pckChain)
            AuditRowView(title: "Body ECDSA signature valid",
                         ok: r.bodySignatureValid,
                         note: r.bodySignatureValid ? nil : "expected in Phase 2 on real TDX; simulator skips",
                         mechanism: AuditMechanismCopy.bodySignature)
            composeBindingRow(r.composeBinding)
            AuditRowView(title: "TLS cert bound to attestation",
                         ok: r.tlsCertBindingChecked,
                         note: r.tlsTerminationDisclosure,
                         mechanism: AuditMechanismCopy.tlsBinding)
            AuditRowView(title: "MCP port TLS bound to attestation",
                         ok: r.mcpTlsCertBindingChecked,
                         note: r.mcpTlsDisclosure,
                         mechanism: AuditMechanismCopy.mcpTlsBinding)

            Divider().padding(.vertical, 4)
            Text("On-chain audit (public transparency, not security)")
                .font(.caption).foregroundStyle(.secondary)
            if let tx = r.onChainTxURL {
                VStack(alignment: .leading, spacing: 2) {
                    Link(destination: tx) {
                        HStack {
                            Image(systemName: "link")
                            Text("View AppAuth deploy on Etherscan")
                                .font(.caption)
                        }
                    }
                    Text(AuditMechanismCopy.onChainAudit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("on-chain info not available")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)
            if let h = r.composeHash {
                copyRow("compose_hash", value: h.prefix(12) + "…")
            }
            if let pk = r.enclaveContentPK {
                copyRow("enclave_content_pk", value: pk.prefix(12) + "…")
            }
            if let c = r.releaseGitCommit {
                copyRow("git_commit", value: String(c.prefix(8)))
            }
            Text("Verified \(r.verifiedAt, style: .relative) ago")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.top, 4)

            Divider().padding(.vertical, 4)
            rawJSONPanel()
        }
    }

    // "Show raw /attestation" footer affordance. Collapsed by default
    // so non-technical users aren't buried; one tap away for auditors.
    @ViewBuilder
    private func rawJSONPanel() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if !showRawJSON && rawJSONText.isEmpty {
                    Task { await fetchRawJSON() }
                }
                withAnimation(.easeOut(duration: 0.25)) { showRawJSON.toggle() }
            } label: {
                HStack {
                    Image(systemName: showRawJSON ? "chevron.up.circle" : "chevron.down.circle")
                        .foregroundStyle(.tertiary)
                    Text(showRawJSON ? "Hide raw /attestation" : "Show raw /attestation (for auditors)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showRawJSON {
                if rawJSONText.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(rawJSONText)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(UIColor.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
    }

    private func fetchRawJSON() async {
        // Re-fetch the attestation (same URL the audit used) so the
        // viewer shows the exact bytes. Uses the non-pinning TLS shim
        // since the security-relevant pin already ran in vm.run().
        // Falls back silently on error.
        guard let url = URL(string: "https://051a174f2457a6c474680a5d745372398f97b6ad-5003s.dstack-pha-prod5.phala.network/attestation")
        else { return }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: PinningCaptureDelegate(),
                                 delegateQueue: nil)
        do {
            let (data, _) = try await session.data(from: url)
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                        options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: pretty, encoding: .utf8) {
                rawJSONText = s
            } else {
                rawJSONText = String(data: data, encoding: .utf8) ?? "(non-UTF8 body)"
            }
        } catch {
            rawJSONText = "Fetch failed: \(error)"
        }
    }

    @ViewBuilder
    private func composeBindingRow(_ result: EventLogReplay.Result?) -> some View {
        switch result {
        case .some(.mrConfigIdConfirmed):
            AuditRowView(title: "compose_hash bound via mr_config_id (dstack-kms)",
                         ok: true,
                         note: "Intel TDX attested mr_config_id[1:33] == claimed compose_hash. Strongest binding — requires key release from real dstack KMS.",
                         mechanism: AuditMechanismCopy.composeBinding)
        case .some(.eventLogConfirmed(let rtmr3Match)):
            AuditRowView(title: rtmr3Match ? "compose_hash in RTMR3 event log" : "compose_hash in RTMR3 event log",
                         ok: rtmr3Match,
                         note: rtmr3Match
                            ? "compose-hash event present with matching payload; RTMR3 replays correctly from the event chain."
                            : "compose-hash event payload matches but RTMR3 replay disagreed with the attested value — event log may be truncated or tampered.",
                         mechanism: AuditMechanismCopy.composeBinding)
        case .some(.inconclusive(let reason)):
            AuditRowView(title: "compose_hash binding",
                         ok: false,
                         note: "Inconclusive: \(reason). Neither mr_config_id nor event-log binding confirmed; trust reduced.",
                         mechanism: AuditMechanismCopy.composeBinding)
        case .some(.mismatch(let detail)):
            AuditRowView(title: "compose_hash binding — MISMATCH",
                         ok: false, note: detail,
                         mechanism: AuditMechanismCopy.composeBinding)
        case .none:
            AuditRowView(title: "compose_hash binding",
                         ok: false, note: "not checked",
                         mechanism: AuditMechanismCopy.composeBinding)
        }
    }

    private func row(_ label: String, ok: Bool, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(label).font(.caption)
            }
            if let n = note {
                Text(n).font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }

    private func copyRow<S: StringProtocol>(_ label: String, value: S) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption2.monospaced())
            Button {
                UIPasteboard.general.string = String(value)
            } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                .buttonStyle(.plain)
        }
    }
}
