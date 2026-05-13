import Foundation
import UIKit

class SharedConfig {
    static let appGroupIdentifier = "group.com.feedling.mcp"
    static let sharedImageFileName = "latest_frame.jpg"
    static let sessionsDirectoryName = "sessions"
    static let frameUpdateNotificationName = "com.feedling.frameUpdate"
    static let stopBroadcastNotificationName = "com.feedling.stopBroadcast"
    static let captureIntervalMsKey = "capture_interval_ms"
    /// 30 s default. Agent doesn't need 1 fps — it pulls a frame on demand
    /// via decrypt_frame when it actually wants to look. Higher cadence
    /// just burns user bandwidth + CVM ingest cycles.
    static let captureIntervalMsDefault: Int = 30_000
    static let ingestTokenKey = "ingest_ws_token"
    static let ingestEndpointKey = "ingest_ws_endpoint"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static var captureIntervalSeconds: CFTimeInterval {
        let ms = sharedDefaults?.integer(forKey: captureIntervalMsKey) ?? 0
        let validMs = ms > 0 ? ms : captureIntervalMsDefault
        return CFTimeInterval(validMs) / 1000.0
    }

    static func saveCaptureIntervalMs(_ ms: Int) {
        sharedDefaults?.set(ms, forKey: captureIntervalMsKey)
    }

    static var ingestToken: String {
        get { sharedDefaults?.string(forKey: ingestTokenKey) ?? "" }
        set { sharedDefaults?.set(newValue, forKey: ingestTokenKey) }
    }

    // Broadcast extension is a separate target and cannot import the main
    // app's `CVMEndpoints` enum. The real value is written to app-group
    // UserDefaults by `FeedlingAPI.init` (see `resolveIngestWSEndpoint`);
    // this fallback only matters on the very first broadcast before the
    // main app has ever launched. Kept in sync with `CVMEndpoints.defaults`
    // so a cold-start fallback still hits the current CVM.
    static let defaultIngestEndpoint =
        "wss://9798850e096d770293c67305c6cfdceed68c1d28-9998.dstack-pha-prod9.phala.network/ingest"

    static var ingestEndpoint: String {
        get { sharedDefaults?.string(forKey: ingestEndpointKey) ?? defaultIngestEndpoint }
        set { sharedDefaults?.set(newValue, forKey: ingestEndpointKey) }
    }

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var sharedImageURL: URL? {
        sharedContainerURL?.appendingPathComponent(sharedImageFileName)
    }

    static var sessionsRootURL: URL? {
        sharedContainerURL?.appendingPathComponent(sessionsDirectoryName)
    }

    static func createSessionDirectory() -> URL? {
        guard let root = sessionsRootURL else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let sessionURL = root.appendingPathComponent(formatter.string(from: Date()))
        try? FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        return sessionURL
    }

    @discardableResult
    static func saveFrameToSession(image: UIImage, sessionURL: URL, index: Int) -> Bool {
        let fileURL = sessionURL.appendingPathComponent(String(format: "frame_%04d.jpg", index))
        guard let data = image.jpegData(compressionQuality: 0.7) else { return false }
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    static func saveImage(_ image: UIImage) -> Bool {
        guard let imageURL = sharedImageURL,
              let data = image.jpegData(compressionQuality: 0.7) else { return false }
        let dir = imageURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return (try? data.write(to: imageURL, options: .atomic)) != nil
    }

    static func loadImage() -> UIImage? {
        guard let url = sharedImageURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func postFrameUpdateNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: frameUpdateNotificationName as CFString),
            nil, nil, true)
    }

    static func postStopBroadcastNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: stopBroadcastNotificationName as CFString),
            nil, nil, true)
    }
}
