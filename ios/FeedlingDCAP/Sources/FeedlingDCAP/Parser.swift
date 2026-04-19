// Parser.swift
// Swift port of tools/dcap/dcap_parse.py. Same structural-only parser —
// signature-chain verification lives in Verifier.swift (Phase 1E).
//
// Field layout from Intel TDX Attestation Quote v4 spec:
//   Header      48 bytes
//   Report Body 584 bytes
//   Sig Data    4 bytes (u32 length) + variable

import Foundation

/// Errors thrown by the parser. Intentionally narrow so callers can render
/// them directly in the iOS audit card's "❌ reason" row.
public enum DCAPParseError: Error, Equatable {
    case tooShort(got: Int, need: Int)
    case unexpectedVersion(got: Int, expected: Int)
    case notTDX(teeType: UInt32)
    case signatureOverrunsBuffer(sigLen: UInt32, bufferSize: Int)
}

/// The 48-byte quote header.
public struct TDXQuoteHeader: Equatable {
    public let version: UInt16
    public let attKeyType: UInt16
    public let teeType: UInt32
    public let reserved: Data       // 4
    public let vendorID: Data       // 16
    public let userData: Data       // 20
}

/// The 584-byte TEE report. All fields kept as raw Data; callers convert
/// to hex as needed.
public struct TDXReportBody: Equatable {
    public let teeTcbSvn: Data      // 16
    public let mrseam: Data         // 48
    public let mrsignerseam: Data   // 48
    public let seamAttr: Data       // 8
    public let tdAttr: Data         // 8
    public let xfam: Data           // 8
    public let mrtd: Data           // 48 — the MRTD we audit
    public let mrConfigID: Data     // 48
    public let mrOwner: Data        // 48
    public let mrOwnerConfig: Data  // 48
    public let rtmr0: Data          // 48
    public let rtmr1: Data          // 48
    public let rtmr2: Data          // 48
    public let rtmr3: Data          // 48 — contains compose_hash for dstack apps
    public let reportData: Data     // 64 — our custom binding payload
}

/// A parsed, NOT-yet-verified TDX quote.
///
/// Use `DCAPVerifier.verify(...)` (Phase 1E) to get a `VerifiedQuote` —
/// consuming this struct plus the Intel SGX PCK cert chain and the
/// ECDSA signature chain. Callers that only need structural fields for
/// display can use a `ParsedQuote` directly.
public struct ParsedQuote: Equatable {
    public let header: TDXQuoteHeader
    public let body: TDXReportBody
    public let signatureData: Data

    public var mrtdHex: String { body.mrtd.hexString }
    public var rtmr3Hex: String { body.rtmr3.hexString }
    public var reportDataHex: String { body.reportData.hexString }
}

public enum DCAPParser {
    public static let headerSize = 48
    public static let reportBodySize = 584
    public static let minimumQuoteSize = headerSize + reportBodySize + 4

    /// Parse a raw TDX quote. Throws on malformed input. Does NOT verify
    /// signatures — see `DCAPVerifier` for that.
    public static func parse(_ bytes: Data) throws -> ParsedQuote {
        guard bytes.count >= minimumQuoteSize else {
            throw DCAPParseError.tooShort(got: bytes.count, need: minimumQuoteSize)
        }

        // --- Header ---
        let version = bytes.readU16LE(at: 0)
        guard version == 4 else {
            throw DCAPParseError.unexpectedVersion(got: Int(version), expected: 4)
        }
        let attKeyType = bytes.readU16LE(at: 2)
        let teeType = bytes.readU32LE(at: 4)
        guard teeType == 0x81 else {
            throw DCAPParseError.notTDX(teeType: teeType)
        }
        let header = TDXQuoteHeader(
            version: version,
            attKeyType: attKeyType,
            teeType: teeType,
            reserved: bytes.sub(8, 4),
            vendorID: bytes.sub(12, 16),
            userData: bytes.sub(28, 20)
        )

        // --- Report Body ---
        let b = headerSize
        let body = TDXReportBody(
            teeTcbSvn:     bytes.sub(b,        16),
            mrseam:        bytes.sub(b + 16,   48),
            mrsignerseam:  bytes.sub(b + 64,   48),
            seamAttr:      bytes.sub(b + 112,   8),
            tdAttr:        bytes.sub(b + 120,   8),
            xfam:          bytes.sub(b + 128,   8),
            mrtd:          bytes.sub(b + 136,  48),
            mrConfigID:    bytes.sub(b + 184,  48),
            mrOwner:       bytes.sub(b + 232,  48),
            mrOwnerConfig: bytes.sub(b + 280,  48),
            rtmr0:         bytes.sub(b + 328,  48),
            rtmr1:         bytes.sub(b + 376,  48),
            rtmr2:         bytes.sub(b + 424,  48),
            rtmr3:         bytes.sub(b + 472,  48),
            reportData:    bytes.sub(b + 520,  64)
        )

        // --- Signature Data ---
        let sigOffset = headerSize + reportBodySize
        let sigLen = bytes.readU32LE(at: sigOffset)
        let sigStart = sigOffset + 4
        let sigEnd = sigStart + Int(sigLen)
        guard sigEnd <= bytes.count else {
            throw DCAPParseError.signatureOverrunsBuffer(sigLen: sigLen, bufferSize: bytes.count)
        }
        let signatureData = bytes.sub(sigStart, Int(sigLen))

        return ParsedQuote(header: header, body: body, signatureData: signatureData)
    }

    /// Hex-string in, parsed quote out.
    public static func parse(hex: String) throws -> ParsedQuote {
        guard let data = Data(hexString: hex) else {
            throw DCAPParseError.tooShort(got: 0, need: minimumQuoteSize)
        }
        return try parse(data)
    }
}


// MARK: - Data helpers (internal but public so tests can use them)

public extension Data {
    /// Safely extract a sub-slice as a fresh Data. Relies on caller having
    /// bounds-checked via `count >= minimumQuoteSize`.
    func sub(_ offset: Int, _ length: Int) -> Data {
        return subdata(in: offset..<(offset + length))
    }

    func readU16LE(at offset: Int) -> UInt16 {
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readU32LE(at offset: Int) -> UInt32 {
        return UInt32(self[offset])
             | (UInt32(self[offset + 1]) << 8)
             | (UInt32(self[offset + 2]) << 16)
             | (UInt32(self[offset + 3]) << 24)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
