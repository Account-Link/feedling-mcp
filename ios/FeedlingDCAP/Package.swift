// swift-tools-version: 5.9
import PackageDescription

/// FeedlingDCAP — TDX quote parser + verifier for the Feedling iOS audit
/// card (see docs/DESIGN_E2E.md §5.2).
///
/// Phase 1E scope:
///  - Quote parsing (this file + Sources/FeedlingDCAP/Parser.swift)
///  - Signature chain verification: PCK cert chain + ECDSA-P256 over the
///    body, hooking into iOS CryptoKit's P256 primitives
///  - Exposed as `DCAPVerifier.verify(quote:rootCA:)` returning a
///    strongly-typed `VerifiedQuote` (measurements + report_data) or
///    throwing a typed error for each failure mode the audit card wants
///    to surface
///
/// This package ships as a standalone SwiftPM module so the iOS app pulls
/// it via dependency rather than having 1000 lines of attestation code
/// sprinkled inside the main target. It also builds cleanly on macOS CLI,
/// so unit tests run in CI without the iOS simulator.
let package = Package(
    name: "FeedlingDCAP",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),      // macOS target so tests run on CI / dev laptops
    ],
    products: [
        .library(name: "FeedlingDCAP", targets: ["FeedlingDCAP"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FeedlingDCAP",
            path: "Sources/FeedlingDCAP"
        ),
        .testTarget(
            name: "FeedlingDCAPTests",
            dependencies: ["FeedlingDCAP"],
            path: "Tests/FeedlingDCAPTests",
            resources: [
                .copy("TestData"),
            ]
        ),
    ]
)
