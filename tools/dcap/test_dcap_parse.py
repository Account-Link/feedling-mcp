"""
Tests for tools/dcap/dcap_parse.py — runs against a real TDX quote
captured from the dstack simulator.

Run with:
    python3 -m unittest tools/dcap/test_dcap_parse.py -v

The sample quote in testdata/ was captured from backend/enclave_app.py
running against the phala dstack simulator at git commit 61db1c0. When we
regenerate the sample (new simulator, new phase) the expected hex values
below should be updated to match what the same simulator reports via its
`/info` endpoint — they're the source of truth.
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path

from dcap_parse import DCAPParseError, parse_quote, parse_quote_hex


TESTDATA = Path(__file__).parent / "testdata"


def _load_sample() -> tuple[str, dict]:
    quote_hex = (TESTDATA / "sample_quote.hex").read_text().strip()
    attestation = json.loads((TESTDATA / "sample_attestation.json").read_text())
    return quote_hex, attestation


class TestParseQuoteSample(unittest.TestCase):
    """End-to-end: parse a real simulator quote and verify every measured
    field matches what the /attestation endpoint claims."""

    @classmethod
    def setUpClass(cls):
        cls.quote_hex, cls.att = _load_sample()
        cls.q = parse_quote_hex(cls.quote_hex)

    def test_version_is_v4(self):
        self.assertEqual(self.q.header.version, 4)

    def test_tee_type_is_tdx(self):
        self.assertEqual(self.q.header.tee_type, 0x81)

    def test_mrtd_matches_attestation_bundle(self):
        expected = self.att["measurements"]["mrtd"]
        self.assertEqual(self.q.mrtd_hex, expected)

    def test_rtmr0_matches(self):
        self.assertEqual(self.q.body.rtmr0.hex(), self.att["measurements"]["rtmr0"])

    def test_rtmr1_matches(self):
        self.assertEqual(self.q.body.rtmr1.hex(), self.att["measurements"]["rtmr1"])

    def test_rtmr2_matches(self):
        self.assertEqual(self.q.body.rtmr2.hex(), self.att["measurements"]["rtmr2"])

    def test_rtmr3_matches_attestation_bundle(self):
        """RTMR3 contains the compose_hash for dstack apps — the key
        load-bearing value for Feedling's DevProof story."""
        self.assertEqual(self.q.rtmr3_hex, self.att["measurements"]["rtmr3"])

    def test_report_data_shape(self):
        """REPORT_DATA is 64 bytes; first 32 are the sha256 binding of
        (content_pk, tls_cert_fp, version_tag)."""
        self.assertEqual(len(self.q.body.report_data), 64)

    def test_signature_data_captured_not_empty(self):
        """The QE report + ECDSA sig + PCK cert chain live here. We don't
        parse them yet, but we do capture all of them."""
        self.assertGreater(len(self.q.signature_data), 500)


class TestMalformedInputs(unittest.TestCase):
    def test_too_short(self):
        with self.assertRaises(DCAPParseError):
            parse_quote(b"\x00" * 100)

    def test_wrong_version(self):
        # Build a 636-byte blob with version=3, which should be rejected.
        buf = bytearray(636)
        buf[0:2] = (3).to_bytes(2, "little")
        buf[4:8] = (0x81).to_bytes(4, "little")
        with self.assertRaises(DCAPParseError) as ctx:
            parse_quote(bytes(buf))
        self.assertIn("version 3", str(ctx.exception))

    def test_sgx_quote_rejected(self):
        # Correct v4 header but tee_type=0 (SGX) — not our format.
        buf = bytearray(636)
        buf[0:2] = (4).to_bytes(2, "little")
        buf[4:8] = (0).to_bytes(4, "little")
        with self.assertRaises(DCAPParseError) as ctx:
            parse_quote(bytes(buf))
        self.assertIn("not TDX", str(ctx.exception))

    def test_sig_len_overrun(self):
        # Valid header/body, sig_len points past the buffer end.
        buf = bytearray(48 + 584 + 4)
        buf[0:2] = (4).to_bytes(2, "little")
        buf[4:8] = (0x81).to_bytes(4, "little")
        buf[48 + 584:48 + 584 + 4] = (999999).to_bytes(4, "little")
        with self.assertRaises(DCAPParseError) as ctx:
            parse_quote(bytes(buf))
        self.assertIn("overruns", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
