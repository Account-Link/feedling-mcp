// BaseImageReference.swift — trust-on-first-use pinning of the dstack
// base-image measurements (MRTD + RTMR0-2).
//
// On the first audit-card run the app fetches the expected measurements
// from Phala's public app-attestations endpoint (Trust Center backend),
// saves them locally, and from then on compares every live TDX quote's
// MRTD/RTMR0-2 against that saved reference. A mismatch means either
// Phala has rolled a new dstack image (reference is stale) or the
// enclave is running a base image we didn't authorize — either is
// worth surfacing.
//
// Storage: UserDefaults. The reference values are public — anyone with
// the app_id can read them. No Keychain is needed.

import Foundation

public struct BaseImageReference: Codable, Equatable {
    public let mrtd: String
    public let rtmr0: String
    public let rtmr1: String
    public let rtmr2: String
    public let savedAt: Date
    public let imageVersion: String?
}

public enum BaseImageStore {
    private static func key(appId: String) -> String {
        "feedling.baseImage.reference.v1.\(appId)"
    }
    public static func load(appId: String) -> BaseImageReference? {
        guard let data = UserDefaults.standard.data(forKey: key(appId: appId))
        else { return nil }
        return try? JSONDecoder().decode(BaseImageReference.self, from: data)
    }
    public static func save(_ ref: BaseImageReference, appId: String) {
        guard let data = try? JSONEncoder().encode(ref) else { return }
        UserDefaults.standard.set(data, forKey: key(appId: appId))
    }
    public static func clear(appId: String) {
        UserDefaults.standard.removeObject(forKey: key(appId: appId))
    }
}

public enum BaseImageReferenceError: Swift.Error, CustomStringConvertible {
    case fetchFailed(underlying: Swift.Error)
    case http(status: Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .fetchFailed(let e): return "fetch failed: \(e)"
        case .http(let s): return "HTTP \(s)"
        case .malformed(let d): return "malformed response: \(d)"
        }
    }
}

public enum BaseImageReferenceClient {
    /// Hit the public app-attestations endpoint and pull MRTD + RTMR0-2
    /// out of `instances[0].tcb_info`. Backs the first-launch pin.
    public static func fetch(appId: String) async throws -> BaseImageReference {
        let url = URL(string: "https://cloud-api.phala.network/api/v1/apps/\(appId)/attestations")!
        let body: Data
        let resp: URLResponse
        do {
            (body, resp) = try await URLSession.shared.data(from: url)
        } catch {
            throw BaseImageReferenceError.fetchFailed(underlying: error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BaseImageReferenceError.http(status: http.statusCode)
        }
        // tcb_info is a nested JSON object, not a string. Decode it
        // directly via Codable.
        struct Envelope: Decodable {
            let instances: [Instance]
            struct Instance: Decodable {
                let tcb_info: TcbInfo
                let image_version: String?
            }
            struct TcbInfo: Decodable {
                let mrtd: String
                let rtmr0: String
                let rtmr1: String
                let rtmr2: String
            }
        }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: body)
        } catch {
            throw BaseImageReferenceError.malformed(
                "decode: \(String(describing: error).prefix(200))")
        }
        guard let first = env.instances.first else {
            throw BaseImageReferenceError.malformed("instances array empty")
        }
        return BaseImageReference(
            mrtd: first.tcb_info.mrtd.lowercased(),
            rtmr0: first.tcb_info.rtmr0.lowercased(),
            rtmr1: first.tcb_info.rtmr1.lowercased(),
            rtmr2: first.tcb_info.rtmr2.lowercased(),
            savedAt: Date(),
            imageVersion: first.image_version
        )
    }
}

/// Outcome of comparing a live TDX quote's MRTD+RTMR0-2 against the
/// saved reference. Consumed by AuditCardView.baseImageRow.
public struct BaseImageVerdict: Equatable {
    public enum Kind: Equatable {
        /// All four measurements match the saved reference.
        case match
        /// One or more measurements diverge from the saved reference.
        case mismatch(reason: String)
        /// No saved reference yet; fetched and saved on this audit.
        /// Treated as pass for the current audit (trust-on-first-use).
        case firstLaunch
        /// No saved reference AND fetch failed. Previous saved
        /// reference also absent. User should retry online.
        case pendingFirstFetch(error: String)
        /// Quote didn't parse; comparison impossible.
        case quoteUnavailable
    }
    public let kind: Kind
    public let saved: BaseImageReference?

    public var isPass: Bool {
        switch kind {
        case .match, .firstLaunch: return true
        default: return false
        }
    }
}
