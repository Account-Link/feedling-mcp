// Verifier.swift
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │ A note for readers confused by "SGX" in a TDX verifier.             │
// │                                                                     │
// │ Feedling runs on TDX. But a TDX quote is SIGNED by Intel's Quoting  │
// │ Enclave (QE), which is itself an SGX enclave Intel chose to reuse   │
// │ for TDX attestation rather than build a second PKI. As a result,    │
// │ a genuine TDX v4 quote embeds a cert chain named:                   │
// │   Intel SGX PCK Certificate → Intel SGX PCK Platform CA → Intel SGX │
// │   Root CA                                                           │
// │ We pin the SGX Root CA. The quote BODY (MRTD, RTMR0-3, report_data) │
// │ is still TDX-specific — only the signer is SGX-rooted. See          │
// │ docs/DESIGN_E2E.md §5 for the long explanation.                     │
// └─────────────────────────────────────────────────────────────────────┘
//
// Full-ish DCAP verification of a TDX v4 quote. Two layers:
//
//   1. The PCK cert chain embedded in the quote's signature_data must
//      chain up to a pinned Intel SGX Root CA (leaf → platform CA → root).
//      We use Security.framework's SecTrust for this so the iOS / macOS
//      platform handles DER parsing, signature math, and chain building.
//
//   2. The body signature (64-byte ECDSA r||s, over the header + report
//      body) must verify using the attestation public key embedded in
//      signature_data. We use CryptoKit's P256.Signing.
//
// Scope boundaries (intentionally):
//   - We do NOT verify the QE report signature or the QE report itself.
//     For Phase 1 + simulator-level testing those are out of scope; for
//     production hardening we'll verify that chain too (QE report is
//     signed by the PCK cert, and its REPORT_DATA is sha256 of the
//     attestation pubkey — that closes the loop).
//   - We do NOT check Intel's CRL — revoked PCK certs are a Phase 2
//     hardening concern.
//   - We do NOT parse the PCK extensions to check TCB levels / FMSPC.
//     That requires Intel-specific OID parsing; also Phase 2.
//
// The tests under Tests/FeedlingDCAPTests/ use the simulator's actual
// quote — which, importantly, does carry a real Intel PCK chain — so
// the chain-to-root path exercises real Intel signatures.

import Foundation
import Security
import CryptoKit


// MARK: - Public result types

public struct VerifiedQuote: Equatable {
    public let parsed: ParsedQuote
    public let signatureData: TDXSignatureData
    public let chainValid: Bool              // true iff chain built to pinned Intel root
    public let bodySignatureValid: Bool      // true iff CryptoKit.P256 verified the body sig
    public let verifiedAt: Date
}


public enum DCAPVerifyError: Error, Equatable {
    case parseFailed(DCAPParseError)
    case signatureParseFailed(DCAPSignatureParseError)
    case noCertsInChain
    case failedToDecodeCert(index: Int)
    case chainBuildFailed(status: OSStatus)
    case chainNotTrusted(reason: String)
    case invalidAttestationPubkey
    case bodySignatureMalformed
    case bodySignatureRejected
    case platformAPIError(OSStatus)
}


// MARK: - Verifier entry point

public enum DCAPVerifier {

    /// Verify a TDX v4 quote end to end. Caller supplies the trusted
    /// Intel SGX Root CA (DER-encoded bytes); on iOS / macOS, embed the
    /// cert from `assets/IntelSGXRootCA.der` into the app bundle and
    /// pass its contents here.
    ///
    /// Returns a `VerifiedQuote` with structured results for each check.
    /// The caller renders them into the user-facing audit card per
    /// `docs/DESIGN_E2E.md §5.3`.
    public static func verify(
        quote quoteBytes: Data,
        trustedIntelRootDER: Data,
        now: Date = Date()
    ) throws -> VerifiedQuote {
        // 1. Structural parse of the quote.
        let parsed: ParsedQuote
        do {
            parsed = try DCAPParser.parse(quoteBytes)
        } catch let e as DCAPParseError {
            throw DCAPVerifyError.parseFailed(e)
        }

        // 2. Parse signature_data (ECDSA bits + embedded PCK chain).
        let sigData: TDXSignatureData
        do {
            sigData = try SignatureDataParser.parse(parsed.signatureData)
        } catch let e as DCAPSignatureParseError {
            throw DCAPVerifyError.signatureParseFailed(e)
        }

        // 3. Validate PCK chain against pinned Intel root.
        let chainValid = try validateChain(
            pemBlob: sigData.pckCertChainPEM,
            intelRootDER: trustedIntelRootDER,
            at: now
        )

        // 4. Verify the ECDSA body signature.
        let bodySignatureValid = try verifyBodySignature(
            headerAndBody: quoteBytes.sub(0, DCAPParser.headerSize + DCAPParser.reportBodySize),
            rawPubkey: sigData.attestationPubkey,
            ieeeRS: sigData.bodyECDSASignature
        )

        return VerifiedQuote(
            parsed: parsed,
            signatureData: sigData,
            chainValid: chainValid,
            bodySignatureValid: bodySignatureValid,
            verifiedAt: now
        )
    }

    // MARK: - Chain validation (Security.framework)

    /// Parse each PEM cert, feed the chain into SecTrust with the
    /// Intel root anchored, and ask the platform to evaluate.
    static func validateChain(
        pemBlob: Data,
        intelRootDER: Data,
        at evalDate: Date
    ) throws -> Bool {
        let pems = pemCerts(in: pemBlob)
        guard !pems.isEmpty else { throw DCAPVerifyError.noCertsInChain }

        var secCerts: [SecCertificate] = []
        for (idx, pem) in pems.enumerated() {
            guard let der = derFromPEM(pem) else {
                throw DCAPVerifyError.failedToDecodeCert(index: idx)
            }
            guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                throw DCAPVerifyError.failedToDecodeCert(index: idx)
            }
            secCerts.append(cert)
        }

        guard let anchor = SecCertificateCreateWithData(nil, intelRootDER as CFData) else {
            throw DCAPVerifyError.failedToDecodeCert(index: -1)
        }

        // SecTrust wants the leaf at index 0. The embedded blob is leaf-first.
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let createStatus = SecTrustCreateWithCertificates(secCerts as CFArray, policy, &trust)
        guard createStatus == errSecSuccess, let t = trust else {
            throw DCAPVerifyError.chainBuildFailed(status: createStatus)
        }
        let anchorStatus = SecTrustSetAnchorCertificates(t, [anchor] as CFArray)
        guard anchorStatus == errSecSuccess else {
            throw DCAPVerifyError.platformAPIError(anchorStatus)
        }
        // Don't augment with system trust store — we want to pin Intel only.
        _ = SecTrustSetAnchorCertificatesOnly(t, true)
        _ = SecTrustSetVerifyDate(t, evalDate as CFDate)

        var cfErr: CFError?
        let ok = SecTrustEvaluateWithError(t, &cfErr)
        if !ok {
            let reason = (cfErr as Error?)?.localizedDescription ?? "unknown"
            // Not thrown — return false so the audit card can surface it.
            // Kept reason as a log-only note.
            _ = reason
        }
        return ok
    }

    // MARK: - Body signature verification (CryptoKit)

    /// The attestation public key in the signature_data is 64 raw bytes
    /// (x || y on P-256). CryptoKit's `P256.Signing.PublicKey` accepts
    /// that directly via `rawRepresentation:`.
    /// The body signature is 64 bytes (r || s), which CryptoKit calls
    /// "rawRepresentation" for ECDSASignature too. We sign/verify over
    /// the SHA-256 digest of the quote header + report body.
    static func verifyBodySignature(
        headerAndBody: Data,
        rawPubkey: Data,
        ieeeRS: Data
    ) throws -> Bool {
        guard rawPubkey.count == 64 else { throw DCAPVerifyError.invalidAttestationPubkey }
        guard ieeeRS.count == 64 else { throw DCAPVerifyError.bodySignatureMalformed }

        do {
            let pk = try P256.Signing.PublicKey(rawRepresentation: rawPubkey)
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: ieeeRS)
            let digest = SHA256.hash(data: headerAndBody)
            return pk.isValidSignature(sig, for: digest)
        } catch {
            // Malformed pubkey / sig shape — surface as rejected rather than thrown
            // so the audit card can show "body signature invalid" cleanly.
            return false
        }
    }

    // MARK: - PEM helpers

    static func pemCerts(in blob: Data) -> [String] {
        guard let text = String(data: blob, encoding: .utf8) else { return [] }
        let pattern = "-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func derFromPEM(_ pem: String) -> Data? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: stripped)
    }
}
