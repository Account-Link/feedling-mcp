// ParserTests.swift
// Mirror of tools/dcap/test_dcap_parse.py — same quote, same expectations,
// same failure modes. If the Python reference passes and this fails, the
// two implementations have drifted.

import XCTest
@testable import FeedlingDCAP

final class ParserTests: XCTestCase {

    // MARK: - Sample fixtures loaded from test bundle

    private struct Attestation: Decodable {
        let tdx_quote_hex: String
        let measurements: Measurements
        let compose_hash: String
    }
    private struct Measurements: Decodable {
        let mrtd: String
        let rtmr0: String
        let rtmr1: String
        let rtmr2: String
        let rtmr3: String
    }

    private func loadSample() throws -> (quote: ParsedQuote, att: Attestation) {
        let bundle = Bundle.module
        guard let attURL = bundle.url(forResource: "sample_attestation", withExtension: "json",
                                      subdirectory: "TestData") else {
            XCTFail("sample_attestation.json not found in bundle")
            throw XCTSkip("fixture missing")
        }
        let att = try JSONDecoder().decode(Attestation.self, from: Data(contentsOf: attURL))
        let quote = try DCAPParser.parse(hex: att.tdx_quote_hex)
        return (quote, att)
    }

    // MARK: - Happy path

    func testVersionIsV4() throws {
        let (q, _) = try loadSample()
        XCTAssertEqual(q.header.version, 4)
    }

    func testTEETypeIsTDX() throws {
        let (q, _) = try loadSample()
        XCTAssertEqual(q.header.teeType, 0x81)
    }

    func testMRTDMatchesAttestationBundle() throws {
        let (q, att) = try loadSample()
        XCTAssertEqual(q.mrtdHex, att.measurements.mrtd)
    }

    func testRTMR0Matches() throws {
        let (q, att) = try loadSample()
        XCTAssertEqual(q.body.rtmr0.hexString, att.measurements.rtmr0)
    }

    func testRTMR1Matches() throws {
        let (q, att) = try loadSample()
        XCTAssertEqual(q.body.rtmr1.hexString, att.measurements.rtmr1)
    }

    func testRTMR2Matches() throws {
        let (q, att) = try loadSample()
        XCTAssertEqual(q.body.rtmr2.hexString, att.measurements.rtmr2)
    }

    func testRTMR3MatchesAttestationBundle() throws {
        // Load-bearing for the audit card: RTMR3 carries the compose_hash.
        let (q, att) = try loadSample()
        XCTAssertEqual(q.rtmr3Hex, att.measurements.rtmr3)
    }

    func testReportDataShape() throws {
        let (q, _) = try loadSample()
        XCTAssertEqual(q.body.reportData.count, 64)
    }

    func testSignatureDataCaptured() throws {
        let (q, _) = try loadSample()
        XCTAssertGreaterThan(q.signatureData.count, 500)
    }

    // MARK: - Malformed inputs

    func testTooShort() {
        XCTAssertThrowsError(try DCAPParser.parse(Data(count: 100))) { err in
            guard case .tooShort = err as? DCAPParseError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testWrongVersion() {
        var buf = Data(count: 636)
        buf[0] = 3; buf[1] = 0            // version 3 (SGX-era)
        buf[4] = 0x81                     // tee_type TDX
        XCTAssertThrowsError(try DCAPParser.parse(buf)) { err in
            guard case .unexpectedVersion(let got, _) = err as? DCAPParseError else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(got, 3)
        }
    }

    func testSGXQuoteRejected() {
        var buf = Data(count: 636)
        buf[0] = 4; buf[1] = 0            // version 4
        buf[4] = 0; buf[5] = 0             // tee_type = SGX (not TDX)
        XCTAssertThrowsError(try DCAPParser.parse(buf)) { err in
            guard case .notTDX = err as? DCAPParseError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testSigLenOverrun() {
        var buf = Data(count: 48 + 584 + 4)
        buf[0] = 4
        buf[4] = 0x81
        // sig_len at offset 48+584 = 632 = 999999 (way past buffer)
        let off = 48 + 584
        buf[off + 0] = 0x3F
        buf[off + 1] = 0x42
        buf[off + 2] = 0x0F
        buf[off + 3] = 0x00
        XCTAssertThrowsError(try DCAPParser.parse(buf)) { err in
            guard case .signatureOverrunsBuffer = err as? DCAPParseError else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }
}
