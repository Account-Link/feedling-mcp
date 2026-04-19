// Verifier.swift
// Phase 1E TODO: full DCAP quote verification.
//
// This file is a placeholder that documents what needs to be implemented
// before the iOS audit card can claim "hardware attestation valid." A
// parsed quote is just a blob until the Intel DCAP PCK cert chain has
// been walked and the ECDSA-P256 signature over the body has been
// checked. None of that code lives here yet.
//
// Reference impls to port / wrap:
//   - https://github.com/intel/SGXDataCenterAttestationPrimitives
//   - https://github.com/automata-network/dcap-rs (Rust, FFI-able via UniFFI)
//
// The surface we want:
//
//     public struct VerifiedQuote {
//         public let parsed: ParsedQuote
//         public let pckChain: [X509Cert]        // validated against Intel root
//         public let verifiedAt: Date
//     }
//
//     public enum DCAPVerifyError: Error {
//         case chainSignatureInvalid
//         case rootNotTrusted(fingerprint: Data)
//         case quoteSignatureInvalid
//         case quoteExpired
//         case pckCertExpired
//         case parseFailed(DCAPParseError)
//     }
//
//     public enum DCAPVerifier {
//         public static func verify(
//             quote: Data,
//             rootCA: Data            // Intel SGX Root CA cert, DER
//         ) throws -> VerifiedQuote
//     }
//
// Implementation notes for Phase 1E:
//
//  1. Parse quote via DCAPParser.parse(quote). Already done.
//  2. The quote's signatureData starts with a 64-byte ECDSA-P256 sig over
//     the body (header + report_body). Then comes the ECDSA attestation
//     key (64 bytes), QE report (384 bytes), QE report sig (64), QE auth
//     data length (u16 + data), cert data type (u16), cert data length
//     (u32), cert data (PEM-encoded PCK cert chain, typically).
//  3. Walk the cert chain: leaf (PCK cert) → intermediate (Intel SGX
//     Platform CA) → root (Intel SGX Root CA). Use iOS's Security.framework
//     or SwiftASN1 (from apple/swift-certificates) to parse X509s.
//  4. Verify root's DER matches the pinned Intel SGX Root CA byte-for-byte.
//  5. Verify each signature in the chain via CryptoKit.P256.Signing.
//  6. Compute digest over body bytes, verify against the ECDSA sig using
//     the ECDSA attestation key. That key must itself be signed by the
//     QE report, which must be signed by the PCK cert. All three signatures
//     must pass.
//  7. Check validity windows (not-before, not-after) on all certs.

import Foundation

public enum DCAPVerifier {
    // Intentionally unimplemented. Calls here throw `notImplemented` until
    // Phase 1E wiring lands. iOS audit code should special-case this and
    // show the "On-chain audit" row as ⚠️ with a "verifier not available in
    // this build" message.
    public enum Status {
        case notImplemented
    }
    public static let status: Status = .notImplemented
}
