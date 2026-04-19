// SignatureData.swift
// Parse the nested signature_data section of an Intel TDX v4 quote.
//
// Outer layout of signatureData (already extracted by Parser.swift):
//     ECDSA body signature         64 bytes (r || s)
//     ECDSA attestation public key  64 bytes (raw P-256 x || y)
//     QE certification data:
//         qe_cert_data_type         u16 little-endian
//         qe_cert_data_size         u32 little-endian
//         qe_cert_data              qe_cert_data_size bytes
//
// We only support type=6 — "PCK cert chain with QE report" — which is what
// Intel TDX platforms and Phala's dstack simulator actually produce.
//
// Inner layout of type=6 qe_cert_data:
//     QE Report                     384 bytes (SGX report from the Quoting Enclave)
//     QE Report Signature           64 bytes
//     QE Auth Data:
//         qe_auth_data_size         u16 little-endian
//         qe_auth_data              qe_auth_data_size bytes
//     Inner certification data:
//         inner_cert_data_type      u16 little-endian
//         inner_cert_data_size      u32 little-endian
//         inner_cert_data           PEM-encoded PCK cert chain (leaf → intermediate → root)

import Foundation

/// The inner, parsed signature-data of a TDX v4 quote.
public struct TDXSignatureData: Equatable {
    public let bodyECDSASignature: Data          // 64 bytes, r || s
    public let attestationPubkey: Data            // 64 bytes raw P-256 x || y
    public let qeCertDataType: UInt16             // expected: 6
    public let qeReport: Data                     // 384 bytes
    public let qeReportSignature: Data            // 64 bytes
    public let qeAuthData: Data                   // variable
    public let innerCertDataType: UInt16          // expected: 5 (PEM chain)
    public let pckCertChainPEM: Data              // PEM bytes — potentially null-padded

    /// All certificates parsed from the embedded PEM blob, leaf first.
    /// Expected order: PCK cert → SGX PCK Platform CA → SGX Root CA.
    public var pemCertStrings: [String] {
        guard let text = String(data: pckCertChainPEM, encoding: .utf8) else { return [] }
        let pattern = "-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}


public enum DCAPSignatureParseError: Error, Equatable {
    case shortSignatureData(got: Int, minimum: Int)
    case unsupportedCertDataType(UInt16)
    case qeCertDataOverflow(claimed: UInt32, have: Int)
    case qeAuthOverflow(claimed: UInt16, have: Int)
    case innerCertOverflow(claimed: UInt32, have: Int)
}


public enum SignatureDataParser {

    private static let SIG_SIZE: Int = 64
    private static let KEY_SIZE: Int = 64
    private static let QE_REPORT_SIZE: Int = 384
    private static let QE_SIG_SIZE: Int = 64

    /// Outer layout minimum: 64 + 64 + 2 + 4 = 134 bytes before qe_cert_data.
    private static let outerMinimum: Int = SIG_SIZE + KEY_SIZE + 2 + 4
    /// Inner layout minimum (for cert_data_type == 6):
    /// 384 + 64 + 2 + 0 + 2 + 4 = 456.
    private static let innerMinimum: Int = QE_REPORT_SIZE + QE_SIG_SIZE + 2 + 2 + 4

    public static func parse(_ signatureData: Data) throws -> TDXSignatureData {
        guard signatureData.count >= outerMinimum else {
            throw DCAPSignatureParseError.shortSignatureData(
                got: signatureData.count, minimum: outerMinimum)
        }

        var p = 0
        let bodySig = signatureData.sub(p, SIG_SIZE); p += SIG_SIZE
        let attPK = signatureData.sub(p, KEY_SIZE); p += KEY_SIZE
        let qeCertType = signatureData.readU16LE(at: p); p += 2
        let qeCertSize = signatureData.readU32LE(at: p); p += 4

        guard Int(qeCertSize) + p <= signatureData.count else {
            throw DCAPSignatureParseError.qeCertDataOverflow(
                claimed: qeCertSize, have: signatureData.count - p)
        }
        let qeCertBlob = signatureData.sub(p, Int(qeCertSize))

        guard qeCertType == 6 else {
            throw DCAPSignatureParseError.unsupportedCertDataType(qeCertType)
        }

        // Now parse the inner layout of qeCertBlob:
        guard qeCertBlob.count >= innerMinimum else {
            throw DCAPSignatureParseError.shortSignatureData(
                got: qeCertBlob.count, minimum: innerMinimum)
        }
        var i = 0
        let qeReport = qeCertBlob.sub(i, QE_REPORT_SIZE); i += QE_REPORT_SIZE
        let qeSig = qeCertBlob.sub(i, QE_SIG_SIZE); i += QE_SIG_SIZE
        let authSize = qeCertBlob.readU16LE(at: i); i += 2
        guard i + Int(authSize) + 2 + 4 <= qeCertBlob.count else {
            throw DCAPSignatureParseError.qeAuthOverflow(
                claimed: authSize, have: qeCertBlob.count - i)
        }
        let authData = qeCertBlob.sub(i, Int(authSize)); i += Int(authSize)
        let innerType = qeCertBlob.readU16LE(at: i); i += 2
        let innerSize = qeCertBlob.readU32LE(at: i); i += 4
        guard i + Int(innerSize) <= qeCertBlob.count else {
            throw DCAPSignatureParseError.innerCertOverflow(
                claimed: innerSize, have: qeCertBlob.count - i)
        }
        let pemBlob = qeCertBlob.sub(i, Int(innerSize))

        return TDXSignatureData(
            bodyECDSASignature: bodySig,
            attestationPubkey: attPK,
            qeCertDataType: qeCertType,
            qeReport: qeReport,
            qeReportSignature: qeSig,
            qeAuthData: authData,
            innerCertDataType: innerType,
            pckCertChainPEM: pemBlob
        )
    }
}
