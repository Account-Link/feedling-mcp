// DCAPQVL.swift — Swift bridge over the Phala-Network/dcap-qvl C FFI.
//
// The underlying Rust lib is built from ios/vendor/dcap-qvl and linked as
// a static library via ios/vendor/dcap_qvl.xcframework. The FFI exports
// every function in a callback-return style (result bytes are written by
// invoking a caller-supplied callback with ptr/len/user_data), so this
// file's entire job is to plumb that pattern through Swift without leaking
// unsafe pointers or Rust allocation details up into the audit card.
//
// Scope vs. the hand-rolled verifier in Verifier.swift:
//   - DCAPQVL.verify(...) replaces layers 1-3 of our hand-roll (PCK chain,
//     body signature, QE report sig + REPORT_DATA) AND adds TCB level +
//     PCK CRL checks that our Swift code does NOT do. This is the whole
//     point of switching: row 6 of the audit card turns green legitimately.
//   - Layer 4 (raw PCK Intel SGX extensions) is still surfaced from the
//     Swift side — dcap-qvl also parses them, so we now have two independent
//     parsers and can sanity-cross-check them.

import Foundation
import dcap_qvl

public enum DCAPQVL {

    public enum Error: Swift.Error, CustomStringConvertible {
        case ffiFailure(code: Int32, message: String)
        case malformedUTF8

        public var description: String {
            switch self {
            case .ffiFailure(let code, let message):
                return "dcap-qvl FFI error \(code): \(message)"
            case .malformedUTF8:
                return "dcap-qvl output was not valid UTF-8"
            }
        }
    }

    /// C callback — appends the emitted bytes into the Data* passed via
    /// user_data. `@convention(c)` means no captures; state travels
    /// through user_data only.
    private static let appendCallback: dcap_output_callback_t = { ptr, len, user in
        guard let user = user, let ptr = ptr else { return 1 }
        let capture = user.assumingMemoryBound(to: Data.self)
        capture.pointee.append(ptr, count: len)
        return 0
    }

    /// Wraps a single FFI call: allocates a Data buffer, installs the
    /// append callback, invokes `body`, returns the captured bytes.
    /// On non-zero return from the FFI, throws with the error message
    /// the Rust side wrote into the buffer.
    private static func invoke(
        _ body: (@escaping dcap_output_callback_t, UnsafeMutableRawPointer) -> Int32
    ) throws -> Data {
        var captured = Data()
        let rc = withUnsafeMutablePointer(to: &captured) { capturedPtr -> Int32 in
            body(appendCallback, UnsafeMutableRawPointer(capturedPtr))
        }
        if rc != 0 {
            let msg = String(data: captured, encoding: .utf8) ?? "(non-UTF8 error body)"
            throw Error.ffiFailure(code: rc, message: msg)
        }
        return captured
    }

    // MARK: - FFI entry points

    /// Parse a TDX/SGX quote structurally. JSON output matches
    /// `FfiQuote` in src/ffi.rs of the upstream crate.
    public static func parseQuote(_ quote: Data) throws -> Data {
        try quote.withUnsafeBytes { q in
            try invoke { cb, user in
                dcap_parse_quote_cb(
                    q.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    quote.count,
                    cb, user)
            }
        }
    }

    /// Parse Intel SGX Extensions out of a PCK PEM blob. JSON output is
    /// `FfiPckExtension` { ppid, cpu_svn, pce_svn, pce_id, fmspc, sgx_type }.
    public static func parsePCKExtension(fromPEM pem: String) throws -> Data {
        let pemData = Data(pem.utf8)
        return try pemData.withUnsafeBytes { p in
            try invoke { cb, user in
                dcap_parse_pck_extension_from_pem_cb(
                    p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    pemData.count,
                    cb, user)
            }
        }
    }

    /// Full verify: quote + collateral (`QuoteCollateralV3` as JSON) +
    /// the trusted Intel SGX Root CA (DER). Output JSON is
    /// `FfiVerifiedReport` { status, advisory_ids, report, ppid,
    /// qe_status, platform_status }.
    public static func verify(
        quote: Data,
        collateralJSON: Data,
        rootCADER: Data,
        now: Date = Date()
    ) throws -> Data {
        let nowSecs = UInt64(now.timeIntervalSince1970)
        return try quote.withUnsafeBytes { q in
            try collateralJSON.withUnsafeBytes { c in
                try rootCADER.withUnsafeBytes { r in
                    try invoke { outCB, user in
                        dcap_verify_with_root_ca_cb(
                            q.baseAddress!.assumingMemoryBound(to: UInt8.self), quote.count,
                            c.baseAddress!.assumingMemoryBound(to: UInt8.self), collateralJSON.count,
                            r.baseAddress!.assumingMemoryBound(to: UInt8.self), rootCADER.count,
                            nowSecs, outCB, user)
                    }
                }
            }
        }
    }
}

// MARK: - Decoded result shapes

/// The parts of `FfiVerifiedReport` the audit card consumes. Extend as
/// needed; other fields stay in the raw JSON.
public struct DCAPVerifiedReport: Decodable {
    /// Overall TCB status: "UpToDate" / "SWHardeningNeeded" /
    /// "ConfigurationNeeded" / "ConfigurationAndSWHardeningNeeded" /
    /// "OutOfDate" / "OutOfDateConfigurationNeeded" / "Revoked".
    public let status: String
    public let advisory_ids: [String]
    public let qe_status: TCBStatusWithAdvisory
    public let platform_status: TCBStatusWithAdvisory

    public struct TCBStatusWithAdvisory: Decodable {
        public let status: String
        public let advisory_ids: [String]?
    }

    /// True iff the overall platform is at the most-up-to-date level
    /// Intel currently certifies. Everything else is a disclosure.
    public var isUpToDate: Bool { status == "UpToDate" }
}

/// The parts of `FfiPckExtension` we surface alongside our own parser's
/// values.
public struct DCAPQVLPCKExtension: Decodable {
    public let fmspc: Data
    public let pce_svn: Int
    public let cpu_svn: Data
    public let sgx_type: Int
}
