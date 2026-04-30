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
//
// When dcap_qvl.xcframework is not present (e.g. simulator dev builds),
// the #if canImport guard below compiles stub implementations that throw
// .unavailable instead of crashing. The audit card shows a "library not
// linked" note rather than a build error.

import Foundation

// MARK: - Decoded result shapes (always available)

public struct DCAPVerifiedReport: Decodable {
    public let status: String
    public let advisory_ids: [String]
    public let qe_status: TCBStatusWithAdvisory
    public let platform_status: TCBStatusWithAdvisory

    public struct TCBStatusWithAdvisory: Decodable {
        public let status: String
        public let advisory_ids: [String]?
    }

    public var isUpToDate: Bool { status == "UpToDate" }
}

public struct DCAPQVLPCKExtension: Decodable {
    public let fmspc: Data
    public let pce_svn: Int
    public let cpu_svn: Data
    public let sgx_type: Int
}

// MARK: - FFI bridge (only when the xcframework is linked)

#if canImport(dcap_qvl)
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

    private static let appendCallback: dcap_output_callback_t = { ptr, len, user in
        guard let user = user, let ptr = ptr else { return 1 }
        let capture = user.assumingMemoryBound(to: Data.self)
        capture.pointee.append(ptr, count: len)
        return 0
    }

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

#else

// Stub — xcframework not linked. All methods throw .unavailable.
public enum DCAPQVL {

    public enum Error: Swift.Error, CustomStringConvertible {
        case unavailable
        case ffiFailure(code: Int32, message: String)
        case malformedUTF8

        public var description: String {
            switch self {
            case .unavailable:      return "dcap_qvl library not linked in this build"
            case .ffiFailure(let c, let m): return "dcap-qvl FFI error \(c): \(m)"
            case .malformedUTF8:    return "dcap-qvl output was not valid UTF-8"
            }
        }
    }

    public static func parseQuote(_ quote: Data) throws -> Data {
        throw Error.unavailable
    }

    public static func parsePCKExtension(fromPEM pem: String) throws -> Data {
        throw Error.unavailable
    }

    public static func verify(
        quote: Data,
        collateralJSON: Data,
        rootCADER: Data,
        now: Date = Date()
    ) throws -> Data {
        throw Error.unavailable
    }
}

#endif
