// IntelPCSClient.swift — fetch DCAP collateral from a PCCS (or Intel
// PCS) and assemble the QuoteCollateralV3 JSON that dcap-qvl's
// verify-with-root-ca entry point consumes.
//
// We default to Phala's PCCS mirror (https://pccs.phala.network) for
// symmetry with the rest of the dstack ecosystem. The structure of the
// JSON we build matches `QuoteCollateralV3` in src/lib.rs of the
// upstream crate:
//
//     {
//       "pck_crl_issuer_chain":    "<PEM chain, URL-decoded>",
//       "root_ca_crl":             [<bytes of root CA CRL (DER)>],
//       "pck_crl":                 [<bytes of PCK CRL (DER)>],
//       "tcb_info_issuer_chain":   "<PEM chain>",
//       "tcb_info":                "<TCB info JSON (stringified body)>",
//       "tcb_info_signature":      [<bytes of tcb_info sig>],
//       "qe_identity_issuer_chain":"<PEM chain>",
//       "qe_identity":             "<QE identity JSON>",
//       "qe_identity_signature":   [<bytes of qe_identity sig>],
//       "pck_certificate_chain":   "<PEM of PCK leaf + intermediates>"
//     }
//
// The individual values here come from four HTTP GETs to the PCCS. All
// four must succeed to verify; the iOS path runs them concurrently.

import Foundation

public enum IntelPCSError: Swift.Error, CustomStringConvertible {
    case httpFailure(url: URL, status: Int)
    case missingHeader(url: URL, header: String)
    case malformedBody(url: URL, detail: String)
    case transport(url: URL, underlying: Swift.Error)

    public var description: String {
        switch self {
        case .httpFailure(let url, let status):
            return "HTTP \(status) from \(url)"
        case .missingHeader(let url, let header):
            return "missing response header '\(header)' from \(url)"
        case .malformedBody(let url, let detail):
            return "malformed body from \(url): \(detail)"
        case .transport(let url, let underlying):
            return "transport error from \(url): \(underlying)"
        }
    }
}

public struct IntelPCSClient {

    /// Phala's PCCS — same URL dstack's own attestation flow defaults to.
    /// Passing `https://api.trustedservices.intel.com` hits Intel directly.
    public static let phalaPCCS = URL(string: "https://pccs.phala.network")!

    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL = phalaPCCS, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private var isPCS: Bool {
        baseURL.host == "api.trustedservices.intel.com"
    }

    // MARK: - Assembled collateral

    /// Matches `QuoteCollateralV3` in dcap-qvl/src/lib.rs. The fields
    /// marked #[serde(with = "serde_bytes")] in Rust map to the
    /// `serde-human-bytes` crate, which encodes bytes as **lowercase
    /// hex strings** in JSON (not base64, which is Swift's default
    /// JSONEncoder strategy for Data). So we carry them as hex Strings
    /// on the Swift side and encode/decode via Data(hexString:) /
    /// hexString at the boundaries.
    public struct Collateral: Codable {
        public let pck_crl_issuer_chain: String
        public let root_ca_crl: String        // hex(DER)
        public let pck_crl: String            // hex(DER)
        public let tcb_info_issuer_chain: String
        public let tcb_info: String
        public let tcb_info_signature: String // hex(sig)
        public let qe_identity_issuer_chain: String
        public let qe_identity: String
        public let qe_identity_signature: String // hex(sig)
        public let pck_certificate_chain: String?
    }

    /// Fetch the four collateral items in parallel for a given FMSPC +
    /// CA type + TEE type. `fmspcHex` is the 12-char hex string returned
    /// by the PCK extension parser. `ca` is "platform" or "processor".
    /// `forSGX=false` means TDX (what Feedling runs).
    public func fetchCollateral(
        fmspcHex: String,
        ca: String,
        forSGX: Bool,
        pckChainPEM: String
    ) async throws -> Collateral {
        let tee = forSGX ? "sgx" : "tdx"

        async let (pckCRL, pckCRLChain): (Data, String) = fetchPCKCRL(ca: ca)
        async let (tcbInfoJSON, tcbInfoChain): (String, String) = fetchTCBInfo(tee: tee, fmspcHex: fmspcHex)
        async let (qeIdentityJSON, qeIdentityChain): (String, String) = fetchQEIdentity(tee: tee)
        async let rootCACRL: Data = fetchRootCACRL(qeIdentityChain: nil)

        let (crlBytes, crlChain) = try await (pckCRL, pckCRLChain)
        let (tcbBody, tcbChain) = try await (tcbInfoJSON, tcbInfoChain)
        let (qeBody, qeChain) = try await (qeIdentityJSON, qeIdentityChain)
        // root CA CRL fetch needs qe-identity chain as fallback for Intel PCS;
        // Phala PCCS serves it directly so the initial attempt wins.
        let rootCRL = try await rootCACRL

        // TCB + QE responses are envelopes: { <body>: {...}, "signature": "<hex>" }.
        // The signature is already hex — pass through verbatim instead of
        // round-tripping to Data (which would lose the hex form we want).
        let (tcbInfoStr, tcbSigHex) = try decodeEnvelope(json: tcbBody, innerKey: "tcbInfo")
        let (qeIdentityStr, qeSigHex) = try decodeEnvelope(json: qeBody, innerKey: "enclaveIdentity")

        return Collateral(
            pck_crl_issuer_chain: crlChain,
            root_ca_crl: rootCRL.hexString,
            pck_crl: crlBytes.hexString,
            tcb_info_issuer_chain: tcbChain,
            tcb_info: tcbInfoStr,
            tcb_info_signature: tcbSigHex,
            qe_identity_issuer_chain: qeChain,
            qe_identity: qeIdentityStr,
            qe_identity_signature: qeSigHex,
            pck_certificate_chain: pckChainPEM
        )
    }

    // MARK: - HTTP fetch helpers

    private func fetchPCKCRL(ca: String) async throws -> (body: Data, issuerChain: String) {
        let url = baseURL.appendingPathComponent("sgx/certification/v4/pckcrl")
            .appendingQueryItem("ca", ca)
            .appendingQueryItem("encoding", "der")
        return try await getWithIssuerHeader(url: url, headerName: "SGX-PCK-CRL-Issuer-Chain")
    }

    private func fetchTCBInfo(tee: String, fmspcHex: String) async throws -> (body: String, issuerChain: String) {
        let url = baseURL.appendingPathComponent("\(tee)/certification/v4/tcb")
            .appendingQueryItem("fmspc", fmspcHex)
        let (body, chain) = try await getWithIssuerHeader(
            url: url, headerName: "SGX-TCB-Info-Issuer-Chain", alt: "TCB-Info-Issuer-Chain")
        guard let str = String(data: body, encoding: .utf8) else {
            throw IntelPCSError.malformedBody(url: url, detail: "non-UTF8 body")
        }
        return (str, chain)
    }

    private func fetchQEIdentity(tee: String) async throws -> (body: String, issuerChain: String) {
        let url = baseURL.appendingPathComponent("\(tee)/certification/v4/qe/identity")
            .appendingQueryItem("update", "standard")
        let (body, chain) = try await getWithIssuerHeader(
            url: url, headerName: "SGX-Enclave-Identity-Issuer-Chain")
        guard let str = String(data: body, encoding: .utf8) else {
            throw IntelPCSError.malformedBody(url: url, detail: "non-UTF8 body")
        }
        return (str, chain)
    }

    /// Root CA CRL. Phala PCCS exposes it directly at a hex-encoded
    /// endpoint; Intel PCS requires dereferencing the CRL distribution
    /// point extracted from the root cert. We try the simple path first.
    private func fetchRootCACRL(qeIdentityChain: String?) async throws -> Data {
        let url = baseURL.appendingPathComponent("sgx/certification/v4/rootcacrl")
        let (body, _, _) = try await getRaw(url: url)
        // PCCS serves hex-encoded; Intel serves raw DER. Try hex first.
        if let asString = String(data: body, encoding: .utf8),
           let decoded = Data(hexString: asString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return decoded
        }
        return body
    }

    // MARK: - HTTP primitives

    private func getWithIssuerHeader(
        url: URL, headerName: String, alt: String? = nil
    ) async throws -> (Data, String) {
        let (body, response, _) = try await getRaw(url: url)
        let http = response as? HTTPURLResponse
        let chainRaw = http?.value(forHTTPHeaderField: headerName)
            ?? (alt.flatMap { http?.value(forHTTPHeaderField: $0) })
        guard let chain = chainRaw else {
            throw IntelPCSError.missingHeader(url: url, header: headerName)
        }
        let decoded = chain.removingPercentEncoding ?? chain
        return (body, decoded)
    }

    private func getRaw(url: URL) async throws -> (Data, URLResponse, HTTPURLResponse?) {
        do {
            let (body, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            if let http = http, !(200..<300).contains(http.statusCode) {
                throw IntelPCSError.httpFailure(url: url, status: http.statusCode)
            }
            return (body, response, http)
        } catch let e as IntelPCSError {
            throw e
        } catch {
            throw IntelPCSError.transport(url: url, underlying: error)
        }
    }

    // MARK: - JSON envelope decoding

    /// TCB / QE Identity responses look like
    /// `{"<innerKey>":{...inner...},"signature":"<hex>"}`.
    ///
    /// Critical: Intel signs the inner JSON as it was returned by the
    /// server — byte-for-byte, original key order. Round-tripping
    /// through `JSONSerialization` reorders keys and would break the
    /// downstream TCB signature verification. So we extract the inner
    /// object's bytes verbatim via brace matching, then pull the
    /// signature with a targeted regex.
    private func decodeEnvelope(json: String, innerKey: String) throws -> (inner: String, sigHex: String) {
        let prefix = "{\"\(innerKey)\":"
        guard json.hasPrefix(prefix) else {
            throw IntelPCSError.malformedBody(url: baseURL,
                detail: "envelope missing expected prefix \(prefix.prefix(30))")
        }
        let chars = Array(json)
        let innerStart = prefix.count
        guard innerStart < chars.count, chars[innerStart] == "{" else {
            throw IntelPCSError.malformedBody(url: baseURL,
                detail: "envelope: no inner object after prefix")
        }
        // Walk balanced braces, minding strings + escapes, to find the
        // matching close of the inner object.
        var depth = 0
        var inString = false
        var escape = false
        var innerEnd = -1
        var i = innerStart
        while i < chars.count {
            let c = chars[i]
            if escape { escape = false; i += 1; continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { innerEnd = i; break }
                }
            }
            i += 1
        }
        guard innerEnd > innerStart else {
            throw IntelPCSError.malformedBody(url: baseURL,
                detail: "envelope: unbalanced inner object braces")
        }
        let innerStr = String(chars[innerStart...innerEnd])

        // Signature is after the inner object: ,"signature":"<hex>"}
        let tail = String(chars[(innerEnd + 1)...])
        let pattern = #""signature"\s*:\s*"([0-9a-fA-F]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tail,
                                    range: NSRange(tail.startIndex..<tail.endIndex, in: tail)),
              let r = Range(m.range(at: 1), in: tail)
        else {
            throw IntelPCSError.malformedBody(url: baseURL,
                detail: "envelope: could not find 'signature' hex field")
        }
        return (innerStr, String(tail[r]))
    }
}

// MARK: - URL query helper

private extension URL {
    func appendingQueryItem(_ name: String, _ value: String) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url ?? self
    }
}
