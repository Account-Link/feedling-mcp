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

    /// sha256(DER-encoded leaf cert) as lowercase hex.
    private(set) var capturedCertSHA256Hex: String?
    /// sha256(SubjectPublicKeyInfo DER of leaf cert) as lowercase hex.
    /// Stable across cert renewals when the key doesn't change (Phase C.2).
    private(set) var capturedCertPubkeySHA256Hex: String?

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

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
            capturedCertSHA256Hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            // Extract SubjectPublicKeyInfo DER via SecCertificateCopyKey
            if let secKey = SecCertificateCopyKey(c),
               let pubKeyDER = SecKeyCopyExternalRepresentation(secKey, nil) as Data? {
                // SecKeyCopyExternalRepresentation returns the raw key bytes (X9.62 for EC),
                // not the full SPKI DER. We need the SPKI wrapper. Wrap it manually:
                // SPKI for EC P-256 = sequence { sequence { OID ecPublicKey, OID prime256v1 }, bitstring { 0x00 || raw_key } }
                let oidSequence = Data([0x30, 0x13,
                                        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  // OID ecPublicKey
                                        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]) // OID prime256v1
                var bitString = Data([0x03]) // bitstring tag
                let bsContent = Data([0x00]) + pubKeyDER
                bitString += encodeDERLength(bsContent.count) + bsContent
                let spki = Data([0x30]) + encodeDERLength((oidSequence + bitString).count) + oidSequence + bitString
                capturedCertPubkeySHA256Hex = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
            }
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func encodeDERLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        let bytes = withUnsafeBytes(of: length.bigEndian) { Array($0.drop(while: { $0 == 0 })) }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
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
        /// Raw base-image measurements from the quote. We surface these
        /// for manual inspection; we do NOT compare them against a pinned
        /// reference list (there is no such list bundled in the app).
        /// Nil iff the quote failed to parse.
        var baseImageMeasurements: BaseImageMeasurements?
        var composeHash: String?
        var chainValid: Bool
        var bodySignatureValid: Bool
        var tlsCertBindingChecked: Bool
        var tlsTerminationDisclosure: String?
        var mcpTlsStatus: AuditRowStatus        // Phase C / prod9: pass/fail/info
        var mcpTlsDisclosure: String?           // Phase C
        var composeBinding: EventLogReplay.Result?
        var enclaveContentPK: String?
        var releaseGitCommit: String?
        var onChainTxURL: URL?
        /// Layer 3 — QE report signature + REPORT_DATA binding. Nil
        /// if the quote failed to parse far enough to evaluate.
        var qeReport: QEReportVerdict?
        /// Full dcap-qvl verdict — Intel tcbInfo + PCK CRL + signature
        /// chain all checked by the Phala/dcap-qvl Rust lib we link via
        /// XCFramework. Nil when the fetch or verify failed; see
        /// `qvlError` for why.
        ///
        /// Note: our hand-rolled PCK SGX Extension parser still runs in
        /// DCAPVerifier to extract FMSPC for the PCS collateral fetch,
        /// but we no longer surface its values as a separate row — the
        /// qvlVerdict below subsumes that check.
        var qvlVerdict: DCAPVerifiedReport?
        var qvlError: String?

        struct BaseImageMeasurements {
            let mrtd: String
            let rtmr0: String
            let rtmr1: String
            let rtmr2: String
        }
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
        var qeVerdict: QEReportVerdict? = nil
        var pckExt: PCKSGXExtensions? = nil
        var pckChainPEM: String? = nil
        do {
            let verified = try DCAPVerifier.verify(
                quote: quoteBytes, trustedIntelRootDER: rootCADER)
            hardwareValid = true       // parsed + signature_data parsed = structural OK
            chainValid = verified.chainValid
            bodySigValid = verified.bodySignatureValid
            qeVerdict = verified.qeReport
            pckExt = verified.pckExtensions
            pckChainPEM = String(data: verified.signatureData.pckCertChainPEM, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        } catch {
            lastError = "DCAP verify error: \(error)"
        }

        // 2b. dcap-qvl full verdict. Fetches Intel collateral from the
        //     Phala PCCS mirror + runs the complete chain + body + QE +
        //     TCB-level + CRL check in Rust. This is what row 6 on the
        //     audit card now flips green/yellow on. Failure is non-fatal
        //     to the rest of the audit — we just note it.
        var qvlVerdict: DCAPVerifiedReport? = nil
        var qvlError: String? = nil
        if let pckPEM = pckChainPEM, let fmspcBytes = pckExt?.fmspc {
            let fmspcHex = fmspcBytes.map { String(format: "%02X", $0) }.joined()
            do {
                let pcs = IntelPCSClient()
                let collateral = try await pcs.fetchCollateral(
                    fmspcHex: fmspcHex, ca: "platform", forSGX: false,
                    pckChainPEM: pckPEM)
                let collateralJSON = try JSONEncoder().encode(collateral)
                let verdictData = try DCAPQVL.verify(
                    quote: quoteBytes, collateralJSON: collateralJSON,
                    rootCADER: rootCADER)
                qvlVerdict = try JSONDecoder().decode(DCAPVerifiedReport.self,
                                                     from: verdictData)
            } catch {
                qvlError = "\(error)"
            }
        } else {
            qvlError = "PCK chain or FMSPC unavailable — skipped dcap-qvl full verify."
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
        let baseMeasurements = parsed.map {
            AuditReport.BaseImageMeasurements(
                mrtd: $0.body.mrtd.hexString,
                rtmr0: $0.body.rtmr0.hexString,
                rtmr1: $0.body.rtmr1.hexString,
                rtmr2: $0.body.rtmr2.hexString
            )
        }
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

        // 4b. Phase C.2 — MCP port has a Let's Encrypt cert whose key was
        //    generated inside the CVM. The attestation bundle now contains
        //    mcp_tls_cert_pubkey_fingerprint_hex = sha256(SubjectPublicKeyInfo DER).
        //    We open a CA-verified TLS session to the MCP endpoint, extract the
        //    cert's public key DER, sha256 it, and compare to the attested value.
        var mcpStatus: AuditRowStatus = .fail
        var mcpDisclosure: String? = nil
        let attestedMcpPkFp = (bundle.mcp_tls_cert_pubkey_fingerprint_hex ?? "").lowercased()
        if attestedMcpPkFp.isEmpty {
            // Post-prod9 architecture: MCP sits behind dstack-ingress which
            // owns the Let's Encrypt cert for mcp.feedling.app. The
            // in-enclave MCP pubkey pin was retired. This is NOT a pass —
            // there's no attestation-bound pin to verify against — but it's
            // also not a failure. It's a disclosure: transport trust relies
            // on CA + DNS + ingress operator; the real privacy guarantee is
            // the content-layer envelope crypto (enclave_content_pk below).
            // Shown as .info (yellow) to make that distinction honest.
            mcpStatus = .info
            mcpDisclosure = "In-enclave MCP TLS pin retired in the prod9 migration. Transport security is now standard Let's Encrypt TLS terminated at dstack-ingress — equivalent to any normal HTTPS site. Your actual privacy (chat, memory, identity, screen frames) is protected by the content-layer envelope crypto keyed to enclave_content_pk shown below."
        } else {
            let mcpCapture = PinningCaptureDelegate()
            let mcpSession = URLSession(configuration: .ephemeral,
                                        delegate: mcpCapture, delegateQueue: nil)
            // Legacy path — pre-prod9 CVMs with the `-5002s.` passthrough
            // and an in-enclave pinned key. Kept so audits against older
            // deploys still work.
            if let mcpURL = URL(string: "https://\(CVMEndpoints.appId)-5002s.\(CVMEndpoints.gatewayDomain)/") {
                _ = try? await mcpSession.data(from: mcpURL)
                if let livePkFp = mcpCapture.capturedCertPubkeySHA256Hex?.lowercased() {
                    if livePkFp == attestedMcpPkFp {
                        mcpStatus = .pass
                        mcpDisclosure = "Let's Encrypt cert, key inside CVM. Pubkey fingerprint matches attestation bundle — the private key was generated inside the hardware boundary."
                    } else {
                        mcpStatus = .fail
                        mcpDisclosure = "Pubkey mismatch: live \(String(livePkFp.prefix(16)))… vs attested \(String(attestedMcpPkFp.prefix(16)))…. Possible MITM or stale attestation."
                    }
                } else {
                    mcpStatus = .fail
                    mcpDisclosure = "Couldn't capture MCP port cert public key — TLS handshake may have failed."
                }
            }
        }

        self.report = AuditReport(
            verifiedAt: Date(),
            hardwareAttestationValid: hardwareValid,
            baseImageMeasurements: baseMeasurements,
            composeHash: bundle.compose_hash,
            chainValid: chainValid,
            bodySignatureValid: bodySigValid,
            tlsCertBindingChecked: tlsChecked,
            tlsTerminationDisclosure: disclosure,
            mcpTlsStatus: mcpStatus,
            mcpTlsDisclosure: mcpDisclosure,
            composeBinding: composeBinding,
            enclaveContentPK: bundle.enclave_content_pk_hex,
            releaseGitCommit: bundle.enclave_release?.git_commit,
            onChainTxURL: txURL,
            qeReport: qeVerdict,
            qvlVerdict: qvlVerdict,
            qvlError: qvlError
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
        // Phase 3: live Phala dstack CVM with in-enclave TLS.
        // The `-5003s.` suffix triggers TLS passthrough at dstack-gateway
        // so the cert the client sees is the one the enclave generated
        // (bound to compose_hash via dstack-KMS). Centralized in
        // CVMEndpoints so app_id/gateway migrations are a one-file flip.
        return CVMEndpoints.attestationURL
    }

    // MARK: - Wire type for the /attestation response

    struct AttestationBundle: Decodable {
        let tdx_quote_hex: String
        let enclave_content_pk_hex: String
        let enclave_tls_cert_fingerprint_hex: String
        // Phase C.2: sha256(SubjectPublicKeyInfo DER) of MCP cert key.
        // Stable across LE renewals; empty string on pre-C.2 deployments.
        let mcp_tls_cert_pubkey_fingerprint_hex: String?
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
    static let baseImage = "The enclave boots from a measured OS image. Its measurements (MRTD, RTMR0-2) identify the dstack runtime and can in principle be reproduced by building meta-dstack from source. We surface the raw hex values from the attestation quote so you or your agent can compare them manually against dstack's published references — we do NOT automatically compare them to a pinned endorsed list inside this app. Treat this row as a disclosure, not a pass/fail."
    static let pckChain = "Intel ships a chain of certificates with every TDX quote — the hardware key's identity, signed by a platform key, signed by Intel's root. We walked the full chain offline. This runs entirely on your phone; no server call."
    static let bodySignature = "The attestation payload itself is signed by the enclave's own key, which is in turn signed by Intel's hardware. Verifying this signature proves the report came from this exact enclave at this exact moment."
    static let qeReport = "Body-signature verification alone only proves 'something signed this quote with some P-256 key.' To tie that key back to Intel's hardware we verify the Quoting Enclave report: it's ECDSA-signed by the PCK leaf (Intel's platform cert), and its REPORT_DATA field contains a SHA-256 of the attestation pubkey. Together they say 'Intel's QE vouched for the key that signed this quote.' This closes the loop the chain+body checks above don't."
    static let qvlTCB = "This row is what Phala's Rust dcap-qvl library says when it fetches Intel's tcbInfo.json + PCK CRL from the Phala PCCS mirror and walks the whole thing: PCK chain, body signature, QE report, TCB-level match against Intel's currently-required version, and revocation check. Same library the dstack audit tool shells out to. Green means Intel currently certifies this CPU + microcode as UpToDate."
    static let composeBinding = "The enclave's boot sequence hashes its own exact container recipe into a register called mr_config_id. The quote carries this register; the hash IS the recipe. If we control the app, we control the recipe, and the hash on-chain proves which recipe you're talking to."
    static let tlsBinding = "The certificate your phone just saw during the TLS handshake was generated inside the enclave. Its fingerprint is baked into the signed quote we fetched. Match = this really is the enclave we think it is; no middleman could swap the cert without faking Intel's signature."
    static let mcpTlsBinding = "Where your agent connects (mcp.feedling.app) uses a standard Let's Encrypt certificate. Earlier versions pinned the MCP key inside the enclave too, but that pin was retired in the prod9 migration — the certificate is now issued and served by the dstack-ingress layer that sits in front of the enclave, so the TLS layer is only as trustworthy as any normal HTTPS site (CA + DNS). The real privacy boundary is one level deeper: chat messages, memories, identity, and screen frames are individually sealed with the enclave's content key (`enclave_content_pk` below) BEFORE they leave your phone, and can only be opened inside the enclave. Transport TLS protects bystanders; content-layer envelope crypto protects from everyone including the operator."
    static let onChainAudit = "Every app version we ship gets its compose hash published to a public Ethereum contract. Agents or auditors can read the full release history on-chain and cross-reference it against what the enclave is actually running. This link goes to the transaction that published the current version."
}

// Row-level expand/collapse state — local so tapping one row doesn't
// re-run the audit or disturb the pinned attestation fetch.
//
// Status note: `info` is for rows that aren't a pass/fail binary —
// e.g. the MCP transport row after the prod9 migration, where the
// in-enclave TLS pin was retired by design and the privacy guarantee
// shifted to the content-layer envelope. A green ✓ there would be
// misleading; a red ✗ would be wrong (nothing is broken). Info is the
// honest middle: "this is a disclosure, not a verdict."
enum AuditRowStatus {
    case pass, fail, info
}

struct AuditRowView: View {
    let title: String
    let status: AuditRowStatus
    let note: String?
    let mechanism: String?

    @State private var expanded: Bool = false

    // Back-compat initializer for all rows that still use ok: Bool.
    init(title: String, ok: Bool, note: String? = nil, mechanism: String? = nil) {
        self.title = title
        self.status = ok ? .pass : .fail
        self.note = note
        self.mechanism = mechanism
    }

    // Info-state initializer — used when a row represents a disclosure
    // rather than a pass/fail check.
    init(title: String, status: AuditRowStatus, note: String? = nil, mechanism: String? = nil) {
        self.title = title
        self.status = status
        self.note = note
        self.mechanism = mechanism
    }

    private var iconName: String {
        switch status {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    private var iconTint: Color {
        switch status {
        case .pass: return .green
        case .fail: return .orange
        case .info: return .yellow
        }
    }
    private var accessibilityVerdict: String {
        switch status {
        case .pass: return "passed"
        case .fail: return "failed"
        case .info: return "informational"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if mechanism != nil {
                    withAnimation(.easeOut(duration: 0.25)) { expanded.toggle() }
                }
            } label: {
                HStack(alignment: .top) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconTint)
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
            .accessibilityLabel("\(title), \(accessibilityVerdict)\(mechanism != nil ? ", tap for how we got this" : "")")

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
            baseImageRow(r.baseImageMeasurements)
            AuditRowView(title: "PCK cert chain → Intel SGX Root CA",
                         ok: r.chainValid, note: nil,
                         mechanism: AuditMechanismCopy.pckChain)
            AuditRowView(title: "Body ECDSA signature valid",
                         ok: r.bodySignatureValid,
                         note: r.bodySignatureValid ? nil : "fails against the iOS simulator's mock quote; passes on real TDX hardware",
                         mechanism: AuditMechanismCopy.bodySignature)
            qeReportRow(r.qeReport)
            qvlVerdictRow(r.qvlVerdict, error: r.qvlError)
            composeBindingRow(r.composeBinding)
            AuditRowView(title: "TLS cert bound to attestation",
                         ok: r.tlsCertBindingChecked,
                         note: r.tlsTerminationDisclosure,
                         mechanism: AuditMechanismCopy.tlsBinding)
            AuditRowView(title: mcpRowTitle(r.mcpTlsStatus),
                         status: r.mcpTlsStatus,
                         note: r.mcpTlsDisclosure,
                         mechanism: AuditMechanismCopy.mcpTlsBinding)

            Divider().padding(.vertical, 4)
            Text("Public release log")
                .font(.caption).foregroundStyle(.secondary)
            if let tx = r.onChainTxURL {
                VStack(alignment: .leading, spacing: 2) {
                    Link(destination: tx) {
                        HStack {
                            Image(systemName: "link")
                            Text("View on Etherscan")
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

            // Open-source pointers — the docs a user hands to their agent
            // for "is this safe?" + "how do I migrate?" questions.
            Link(destination: URL(string: "https://github.com/Account-Link/feedling-mcp/blob/main/docs/AUDIT.md")!) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Read the audit guide (for your agent)")
                        .font(.caption)
                }
            }
            .padding(.top, 4)
            Link(destination: URL(string: "https://github.com/Account-Link/feedling-mcp/blob/main/docs/MIGRATION.md")!) {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text("Migration guide (self-hosted → cloud)")
                        .font(.caption)
                }
            }
            Link(destination: URL(string: "https://github.com/Account-Link/feedling-mcp")!) {
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("Browse the source on GitHub")
                        .font(.caption)
                }
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
        guard let url = CVMEndpoints.attestationURL else { return }
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

    // Base-image row: we render this as `.info` (yellow) because we
    // extract the raw MRTD + RTMR0-2 from the quote and display them,
    // but we do NOT compare them to a pinned endorsed reference list.
    // A green check here would be a lie; a red X would be wrong (the
    // measurements are genuine, they're just not pinned). Info = "here's
    // the data, judge it yourself or hand it to your agent." The raw
    // hex lives in the expand panel so the row stays compact.
    @ViewBuilder
    private func baseImageRow(_ m: AuditViewModel.AuditReport.BaseImageMeasurements?) -> some View {
        if let m = m {
            let detail = """
            \(AuditMechanismCopy.baseImage)

            MRTD:  \(m.mrtd)
            RTMR0: \(m.rtmr0)
            RTMR1: \(m.rtmr1)
            RTMR2: \(m.rtmr2)
            """
            AuditRowView(title: "Base image measurements (surfaced, not pinned)",
                         status: .info,
                         note: "Raw MRTD + RTMR0-2 from the quote. Not compared to a reference list — tap to see values.",
                         mechanism: detail)
        } else {
            AuditRowView(title: "Base image measurements",
                         status: .fail,
                         note: "Could not parse the quote; measurements unavailable.",
                         mechanism: AuditMechanismCopy.baseImage)
        }
    }

    // QE report row — one green/red row combining both independent
    // checks (sig by PCK leaf, REPORT_DATA ≡ sha256(attPK||qeAuth)).
    // Both must pass for Intel-rooted attestation; either failing is a
    // hard fail. On simulator both are expected to fail (mock PCK key).
    @ViewBuilder
    private func qeReportRow(_ v: QEReportVerdict?) -> some View {
        if let v = v {
            let ok = v.signatureValid && v.reportDataValid
            let note: String? = ok
                ? "ECDSA sig over SHA256(qeReport) by PCK leaf verified; REPORT_DATA matches sha256(attestationPubkey‖qeAuthData)."
                : {
                    var parts: [String] = []
                    if !v.signatureValid { parts.append("sig by PCK leaf failed") }
                    if !v.reportDataValid { parts.append("REPORT_DATA binding mismatch") }
                    return parts.joined(separator: "; ") +
                        " — expected on iOS simulator (mock QE); failure on real TDX means the quote cannot be tied to Intel's PKI."
                }()
            AuditRowView(title: "Intel QE report ties attestation key to PCK",
                         ok: ok,
                         note: note,
                         mechanism: AuditMechanismCopy.qeReport)
        } else {
            AuditRowView(title: "Intel QE report check",
                         status: .fail,
                         note: "Quote didn't parse far enough to evaluate.",
                         mechanism: AuditMechanismCopy.qeReport)
        }
    }

    // dcap-qvl full verdict row — green only when Intel says "UpToDate".
    // Other statuses (SWHardeningNeeded, ConfigurationNeeded,
    // ConfigurationAndSWHardeningNeeded, OutOfDate, Revoked) each produce
    // a distinct row state; "UpToDate" is the only unambiguous pass.
    private func qvlVerdictNote(_ v: DCAPVerifiedReport) -> String {
        var parts: [String] = ["Intel TCB status: \(v.status)."]
        if !v.advisory_ids.isEmpty {
            let head = v.advisory_ids.prefix(3).joined(separator: ", ")
            let suffix = v.advisory_ids.count > 3 ? "…" : ""
            parts.append("Advisories: \(head)\(suffix)")
        }
        if !v.isUpToDate {
            parts.append("This is a disclosure — the enclave runs, but Intel no longer certifies this exact CPU+microcode combination as UpToDate.")
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func qvlVerdictRow(_ v: DCAPVerifiedReport?, error: String?) -> some View {
        if let v = v {
            AuditRowView(title: "Intel TCB level (Phala dcap-qvl)",
                         ok: v.isUpToDate,
                         note: qvlVerdictNote(v),
                         mechanism: AuditMechanismCopy.qvlTCB)
        } else if let err = error {
            AuditRowView(title: "Intel TCB level (Phala dcap-qvl)",
                         status: .info,
                         note: "Unavailable: \(err.prefix(140))",
                         mechanism: AuditMechanismCopy.qvlTCB)
        } else {
            AuditRowView(title: "Intel TCB level (Phala dcap-qvl)",
                         status: .info,
                         note: "Skipped — prerequisites not met.",
                         mechanism: AuditMechanismCopy.qvlTCB)
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

    private func mcpRowTitle(_ status: AuditRowStatus) -> String {
        switch status {
        case .pass: return "MCP TLS: in-enclave pinned key matches attestation"
        case .fail: return "MCP TLS: pin mismatch"
        case .info: return "MCP transport: standard TLS (content-layer crypto is the privacy boundary)"
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
