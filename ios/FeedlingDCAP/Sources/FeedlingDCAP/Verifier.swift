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
// DCAP verification of a TDX v4 quote. Four layers:
//
//   1. The PCK cert chain embedded in the quote's signature_data must
//      chain up to a pinned Intel SGX Root CA (leaf → platform CA → root).
//      Security.framework's SecTrust walks DER + chain building.
//
//   2. The body signature (64-byte ECDSA r||s, over the header + report
//      body) must verify using the attestation public key embedded in
//      signature_data. CryptoKit's P256.Signing.
//
//   3. The QE (Quoting Enclave) report signature must verify using the
//      PCK leaf's public key over SHA256(qeReport), AND the QE report's
//      REPORT_DATA[:32] must equal SHA256(attestationPubkey || qeAuthData).
//      This ties the attestation key into Intel's PKI — the loop layer 2
//      alone doesn't close: layer 2 proves "something signed this with
//      this key"; layer 3 proves "Intel's QE vouched for that key".
//
//   4. The PCK leaf's Intel SGX Extensions (OID 1.2.840.113741.1.13.1)
//      are parsed to extract FMSPC, PCE-SVN, and CPU-SVN. These are
//      surfaced for the audit card but NOT compared against Intel's
//      tcbInfo.json (see scope boundaries below).
//
// Scope boundaries — known gaps, NOT scheduled on any roadmap. Callers
// relying on this verifier for end-to-end assurance should treat each
// of these as an open trust assumption:
//   - We do NOT fetch Intel's tcbInfo.json from PCS and compare the PCK
//     TCB SVNs against it. FMSPC + SVNs are parsed and surfaced in the
//     audit card, but whether they meet Intel's current required TCB
//     level is an auditor's manual check. Not implemented.
//   - We do NOT check Intel's PCK CRL. Revoked PCK certs will still
//     evaluate as valid here. Not implemented.
//
// The tests under Tests/FeedlingDCAPTests/ use the simulator's actual
// quote — which, importantly, does carry a real Intel PCK chain — so
// the chain-to-root path exercises real Intel signatures.

import Foundation
import Security
import CryptoKit


// MARK: - Public result types

/// Parsed Intel SGX Extensions from a PCK leaf cert. Values are surfaced
/// for the audit card but not compared against Intel's tcbInfo.json.
public struct PCKSGXExtensions: Equatable {
    /// FMSPC — Family-Model-Stepping-Platform-CustomSKU, 6 bytes. This
    /// is the identifier passed to Intel PCS to fetch expected TCB
    /// levels for the platform.
    public let fmspc: Data?
    /// PCE-SVN — Provisioning Certification Enclave Security Version.
    public let pceSVN: Int?
    /// CPU-SVN — 16-byte opaque CPU-level security version components.
    public let cpuSVN: Data?
}

/// Outcome of verifying the Quoting Enclave's report inside a TDX quote.
public struct QEReportVerdict: Equatable {
    /// ECDSA sig over SHA256(qeReport) by the PCK leaf's pubkey.
    public let signatureValid: Bool
    /// qeReport.REPORT_DATA[0:32] == SHA256(attestationPubkey || qeAuthData).
    public let reportDataValid: Bool
}

public struct VerifiedQuote: Equatable {
    public let parsed: ParsedQuote
    public let signatureData: TDXSignatureData
    public let chainValid: Bool              // chain built to pinned Intel root
    public let bodySignatureValid: Bool      // P256 body sig verified
    public let qeReport: QEReportVerdict     // layer 3
    public let pckExtensions: PCKSGXExtensions?  // layer 4 (nil if absent/malformed)
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
    /// Intel SGX Root CA (DER-encoded); on iOS / macOS embed the cert
    /// from `assets/IntelSGXRootCA.der` into the app bundle and pass
    /// its contents here.
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

        // 5. Grab the PCK leaf DER for layer 3 + layer 4. We keep both
        //    the raw DER (for our own extension walker) and a
        //    SecCertificate (for CryptoKit pubkey extraction).
        let pckLeafDER: Data? = pemCerts(in: sigData.pckCertChainPEM).first
            .flatMap { derFromPEM($0) }
        let pckLeaf: SecCertificate? = pckLeafDER
            .flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }

        // 6. QE report signature + REPORT_DATA binding.
        let qeReportVerdict = verifyQEReport(
            qeReport: sigData.qeReport,
            qeReportSignature: sigData.qeReportSignature,
            qeAuthData: sigData.qeAuthData,
            attestationPubkey: sigData.attestationPubkey,
            pckLeaf: pckLeaf
        )

        // 7. Intel SGX Extensions walked out of the PCK leaf DER.
        let pckExtensions = pckLeafDER.flatMap { parsePCKExtensions(pckLeafDER: $0) }

        return VerifiedQuote(
            parsed: parsed,
            signatureData: sigData,
            chainValid: chainValid,
            bodySignatureValid: bodySignatureValid,
            qeReport: qeReportVerdict,
            pckExtensions: pckExtensions,
            verifiedAt: now
        )
    }

    // MARK: - Chain validation (Security.framework)

    /// Parse each PEM cert, feed the chain into SecTrust with the Intel
    /// root anchored, and ask the platform to evaluate.
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
        _ = SecTrustSetAnchorCertificatesOnly(t, true)
        _ = SecTrustSetVerifyDate(t, evalDate as CFDate)

        var cfErr: CFError?
        let ok = SecTrustEvaluateWithError(t, &cfErr)
        if !ok {
            let reason = (cfErr as Error?)?.localizedDescription ?? "unknown"
            _ = reason
        }
        return ok
    }

    // MARK: - Body signature verification (CryptoKit)

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
            return false
        }
    }

    // MARK: - Layer 3: QE report signature + REPORT_DATA binding

    /// The QE is an SGX enclave Intel runs on every TDX platform. The
    /// report it issues has two pieces we need to verify:
    ///   1. REPORT_DATA[0:32] == SHA256(attestationPubkey || qeAuthData).
    ///      This binds the attestation key into the SGX-signed report.
    ///   2. The report is ECDSA-signed by the PCK leaf's key.
    ///
    /// Together: "Intel's PCK signed an SGX report that vouches for this
    /// attestation pubkey." Without this check, layer 2 alone only
    /// proves "something signed the body with *some* P-256 key." Layer
    /// 3 is what ties that key back to Intel's PKI.
    ///
    /// SGX report body layout (384 bytes, see SGX SDK headers):
    ///   cpuSvn[16] | miscSelect[4] | reserved1[28] | attributes[16]
    ///   mrEnclave[32] | reserved2[32] | mrSigner[32] | reserved3[96]
    ///   isvProdID[2] | isvSVN[2] | reserved4[60] | reportData[64]
    /// reportData sits at offset 320.
    static func verifyQEReport(
        qeReport: Data,
        qeReportSignature: Data,
        qeAuthData: Data,
        attestationPubkey: Data,
        pckLeaf: SecCertificate?
    ) -> QEReportVerdict {
        // REPORT_DATA check — independent of any cert.
        var reportDataValid = false
        if qeReport.count >= 320 + 32 {
            let s = qeReport.startIndex
            let reportData32 = qeReport.subdata(in: (s + 320)..<(s + 320 + 32))
            let expected = Data(SHA256.hash(data: attestationPubkey + qeAuthData))
            reportDataValid = (reportData32 == expected)
        }

        // ECDSA sig check — needs the PCK leaf's public key in X9.62 form.
        var signatureValid = false
        if let pckLeaf = pckLeaf,
           let secKey = SecCertificateCopyKey(pckLeaf),
           let keyData = SecKeyCopyExternalRepresentation(secKey, nil) as Data?,
           keyData.count == 65,
           keyData.first == 0x04,
           qeReportSignature.count == 64 {
            do {
                let pk = try P256.Signing.PublicKey(x963Representation: keyData)
                let sig = try P256.Signing.ECDSASignature(rawRepresentation: qeReportSignature)
                let digest = SHA256.hash(data: qeReport)
                signatureValid = pk.isValidSignature(sig, for: digest)
            } catch {
                signatureValid = false
            }
        }

        return QEReportVerdict(
            signatureValid: signatureValid,
            reportDataValid: reportDataValid
        )
    }

    // MARK: - Layer 4: Intel SGX Extensions on the PCK leaf
    //
    // Intel SGX Extensions OID 1.2.840.113741.1.13.1 — see "Intel SGX
    // PCK Certificate and Certificate Revocation List Profile
    // Specification" §3.5.

    /// Parse the Intel SGX Extensions from the PCK leaf's DER. Returns
    /// nil if the extension is absent or malformed. We only pull the
    /// three values the audit card surfaces — FMSPC, PCE-SVN, CPU-SVN.
    ///
    /// NB: iOS doesn't expose `SecCertificateCopyExtensionValue`, so we
    /// walk the cert's DER ourselves:
    ///     SEQUENCE (cert) → SEQUENCE (TBS) → find [3] EXPLICIT →
    ///     SEQUENCE (Extensions) → entries of SEQUENCE { OID, OCTET }.
    /// Match OID 1.2.840.113741.1.13.1, then parse its OCTET STRING
    /// contents as the SGX extension SEQUENCE.
    static func parsePCKExtensions(pckLeafDER: Data) -> PCKSGXExtensions? {
        guard let cert = parseDERElement(pckLeafDER, at: 0), cert.tag == 0x30,
              let tbs = walkDERSequence(cert.content).first, tbs.tag == 0x30
        else { return nil }

        // Find the [3] EXPLICIT Extensions tag (0xA3) inside TBS.
        var extensionsContent: Data? = nil
        for child in walkDERSequence(tbs.content) where child.tag == 0xA3 {
            if let inner = parseDERElement(child.content, at: 0), inner.tag == 0x30 {
                extensionsContent = inner.content
                break
            }
        }
        guard let extsContent = extensionsContent else { return nil }

        // Walk the extensions list for OID 1.2.840.113741.1.13.1.
        // Each extension is SEQUENCE { OID, [critical BOOLEAN OPT], OCTET STRING }.
        var sgxExtValue: Data? = nil
        for ext in walkDERSequence(extsContent) where ext.tag == 0x30 {
            let parts = walkDERSequence(ext.content)
            guard let first = parts.first, first.tag == 0x06 else { continue }
            if decodeOID(first.content) == [1, 2, 840, 113741, 1, 13, 1] {
                for p in parts.dropFirst() where p.tag == 0x04 {
                    sgxExtValue = p.content
                    break
                }
                break
            }
        }
        guard let sgxExt = sgxExtValue,
              let topSeq = parseDERElement(sgxExt, at: 0), topSeq.tag == 0x30
        else { return nil }
        let seqContent = topSeq.content

        var fmspc: Data? = nil
        var pceSVN: Int? = nil
        var cpuSVN: Data? = nil

        // Each child of the top SEQUENCE is SEQUENCE { OID, VALUE }.
        for child in walkDERSequence(seqContent) {
            guard child.tag == 0x30 else { continue }
            let parts = walkDERSequence(child.content)
            guard parts.count >= 2, parts[0].tag == 0x06 else { continue }
            let oid = decodeOID(parts[0].content)
            let value = parts[1]

            // FMSPC: .4 OCTET STRING
            if oid == [1, 2, 840, 113741, 1, 13, 1, 4], value.tag == 0x04 {
                fmspc = value.content
            }
            // TCB: .2 SEQUENCE — walk children for PCE-SVN + CPU-SVN
            if oid == [1, 2, 840, 113741, 1, 13, 1, 2], value.tag == 0x30 {
                for sub in walkDERSequence(value.content) {
                    guard sub.tag == 0x30 else { continue }
                    let subParts = walkDERSequence(sub.content)
                    guard subParts.count >= 2, subParts[0].tag == 0x06 else { continue }
                    let subOID = decodeOID(subParts[0].content)
                    let subValue = subParts[1]

                    // PCE-SVN: .2.17 INTEGER
                    if subOID == [1, 2, 840, 113741, 1, 13, 1, 2, 17], subValue.tag == 0x02 {
                        var v = 0
                        for b in subValue.content { v = (v << 8) | Int(b) }
                        pceSVN = v
                    }
                    // CPU-SVN: .2.18 OCTET STRING (16 bytes)
                    if subOID == [1, 2, 840, 113741, 1, 13, 1, 2, 18], subValue.tag == 0x04 {
                        cpuSVN = subValue.content
                    }
                }
            }
        }

        if fmspc == nil && pceSVN == nil && cpuSVN == nil { return nil }
        return PCKSGXExtensions(fmspc: fmspc, pceSVN: pceSVN, cpuSVN: cpuSVN)
    }

    // MARK: - Minimal DER/ASN.1 walker

    struct DERElement {
        let tag: UInt8
        let content: Data
        let totalSize: Int
    }

    /// Parse one TLV at `offset` into a DERElement. Short-form and
    /// long-form (≤ 4-byte) lengths supported. Returns nil on malformed
    /// or truncated input.
    static func parseDERElement(_ input: Data, at offset: Int) -> DERElement? {
        let data = Data(input)  // normalize startIndex to 0
        guard offset < data.count else { return nil }
        let tag = data[offset]
        let lenOffset = offset + 1
        guard lenOffset < data.count else { return nil }
        let firstLenByte = data[lenOffset]
        let length: Int
        let contentOffset: Int
        if firstLenByte & 0x80 == 0 {
            length = Int(firstLenByte)
            contentOffset = lenOffset + 1
        } else {
            let nLenBytes = Int(firstLenByte & 0x7F)
            guard nLenBytes > 0 && nLenBytes <= 4 else { return nil }
            guard lenOffset + nLenBytes < data.count else { return nil }
            var len = 0
            for i in 0..<nLenBytes {
                len = (len << 8) | Int(data[lenOffset + 1 + i])
            }
            length = len
            contentOffset = lenOffset + 1 + nLenBytes
        }
        guard contentOffset + length <= data.count else { return nil }
        let content = data.subdata(in: contentOffset..<(contentOffset + length))
        return DERElement(tag: tag, content: content, totalSize: contentOffset + length - offset)
    }

    /// Walk the elements of a SEQUENCE content blob.
    static func walkDERSequence(_ input: Data) -> [DERElement] {
        let content = Data(input)
        var result: [DERElement] = []
        var offset = 0
        while offset < content.count {
            guard let elem = parseDERElement(content, at: offset) else { break }
            result.append(elem)
            offset += elem.totalSize
        }
        return result
    }

    /// Decode an ASN.1 OID byte string into a dotted-int array.
    static func decodeOID(_ bytes: Data) -> [Int] {
        let b = Data(bytes)
        guard !b.isEmpty else { return [] }
        var result: [Int] = []
        let first = Int(b[0])
        result.append(first / 40)
        result.append(first % 40)
        var accum = 0
        for i in 1..<b.count {
            let byte = b[i]
            accum = (accum << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                result.append(accum)
                accum = 0
            }
        }
        return result
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
