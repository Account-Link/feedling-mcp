import CryptoKit
import Foundation

/// Verify compose_hash against a TDX v4 quote the way dstack actually
/// encodes it. Two independent checks, either of which is sufficient:
///
///   1. `compose-hash` event in the event_log → event_payload IS the
///      compose_hash. Replay RTMR3 from all IMR=3 events and confirm
///      it matches the quote's attested RTMR3.
///   2. `mr_config_id[0] == 0x01 && mr_config_id[1:33] == compose_hash`
///      — binding set by dstack-kms at key provisioning. Present on
///      real dstack deployments; zeros on the local simulator.
///
/// References:
///   - dstack-tutorial/01-attestation-and-reference-values/verify.py
///   - dstack-tutorial/dstack_audit/phases/attestation.py
///   - Intel TDX Attestation Quote v4 spec (mr_config_id layout)
enum EventLogReplay {

    struct Event: Decodable {
        let imr: Int
        let event: String
        let digest: String            // hex, 96 chars (48 bytes SHA-384)
        let event_payload: String     // hex
        let event_type: Int?
    }

    enum Result: Equatable {
        /// Event-log contains a `compose-hash` event whose payload equals
        /// the claimed compose_hash, and RTMR3 replayed from all IMR=3
        /// events matches the quote's attested RTMR3.
        case eventLogConfirmed(rtmr3Match: Bool)
        /// mr_config_id[0] == 0x01 and mr_config_id[1:33] == compose_hash
        case mrConfigIdConfirmed
        /// Neither check succeeded but no explicit failure either —
        /// either simulator + no compose-hash event (rare), or we have
        /// zeros in mr_config_id as the simulator does. Caller decides
        /// what to surface.
        case inconclusive(reason: String)
        /// A check was attempted and failed — compose_hash claim in the
        /// bundle doesn't match what's actually in the measured event log
        /// or in mr_config_id. Don't trust this endpoint.
        case mismatch(detail: String)
    }

    /// Run both checks and combine into a single best-effort result.
    /// Preference order: mrConfigIdConfirmed > eventLogConfirmed >
    /// inconclusive > mismatch (which short-circuits).
    static func verify(
        claimedComposeHash: String,
        eventLogJSON: String,
        attestedRTMR3: String,
        mrConfigIdHex: String
    ) -> Result {
        let claim = claimedComposeHash.lowercased()

        // Check 1: mr_config_id binding (real dstack only)
        let mcid = mrConfigIdHex.lowercased()
        if mcid.count == 96 {
            let firstByte = mcid.prefix(2)
            if firstByte == "01" {
                let hashSlice = String(mcid.dropFirst(2).prefix(64))
                if hashSlice == claim {
                    return .mrConfigIdConfirmed
                } else {
                    return .mismatch(
                        detail: "mr_config_id claims compose_hash=\(String(hashSlice.prefix(16)))… but endpoint says \(String(claim.prefix(16)))…"
                    )
                }
            }
        }

        // Check 2: event log replay
        let events: [Event]
        do {
            guard let data = eventLogJSON.data(using: .utf8) else {
                return .inconclusive(reason: "event_log_json not UTF-8")
            }
            events = try JSONDecoder().decode([Event].self, from: data)
        } catch {
            return .inconclusive(reason: "could not decode event_log_json: \(error)")
        }

        // Find the compose-hash event.
        let composeEvent = events.first { $0.event == "compose-hash" }
        guard let ce = composeEvent else {
            return .inconclusive(reason: "no compose-hash event in event_log")
        }
        let payloadMatches = ce.event_payload.lowercased() == claim
        guard payloadMatches else {
            return .mismatch(
                detail: "compose-hash event_payload=\(String(ce.event_payload.prefix(16)))… but endpoint says \(String(claim.prefix(16)))…"
            )
        }

        // Replay RTMR3: start from 48 zero bytes, for each IMR=3 event
        // extend by SHA-384(current || digest). Compare to attested.
        var rtmr = Data(count: 48)
        for e in events where e.imr == 3 {
            guard let d = Data(hexString: e.digest), d.count == 48 else {
                return .inconclusive(reason: "event_log entry has malformed digest")
            }
            rtmr = Data(SHA384.hash(data: rtmr + d))
        }
        let replayMatches = rtmr.hexString.lowercased() == attestedRTMR3.lowercased()

        return .eventLogConfirmed(rtmr3Match: replayMatches)
    }
}
