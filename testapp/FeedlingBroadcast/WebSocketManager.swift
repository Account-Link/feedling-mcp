import Foundation

// Minimal WebSocket client using URLSessionWebSocketTask (no third-party dependency)

struct IngestRoutingSignals: Encodable {
    let dhashDistance: Int
    let ocrTextLength: Int
    let ocrURLCount: Int
    let bundleId: String
    let isTextHeavyApp: Bool

    enum CodingKeys: String, CodingKey {
        case dhashDistance = "dhash_distance"
        case ocrTextLength = "ocr_text_length"
        case ocrURLCount = "ocr_url_count"
        case bundleId = "bundle_id"
        case isTextHeavyApp = "is_text_heavy_app"
    }
}

struct IngestFramePayload: Encodable {
    let type: String
    let ts: Double
    let app: String?
    let bundle: String?
    let ocrText: String
    let urls: [String]
    let image: String
    let w: Int
    let h: Int
    let tierHint: Int
    let routingSignals: IngestRoutingSignals

    enum CodingKeys: String, CodingKey {
        case type, ts, app, bundle, urls, image, w, h
        case ocrText = "ocr_text"
        case tierHint = "tier_hint"
        case routingSignals = "routing_signals"
    }
}

final class WebSocketManager: NSObject {
    static let shared = WebSocketManager()

    private let queue = DispatchQueue(label: "com.feedling.ws", qos: .utility)
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var retryAttempt = 0
    private let encoder = JSONEncoder()
    private var endpointURL: URL?
    private var token: String = ""

    private override init() { super.init() }

    func connect(endpoint: String = SharedConfig.defaultIngestEndpoint, token: String) {
        queue.async {
            self.token = token
            guard let url = URL(string: endpoint) else { return }
            self.endpointURL = url
            self.retryAttempt = 0
            self.openSocket(url: url)
        }
    }

    func disconnect() {
        queue.async {
            self.reconnectWorkItem?.cancel()
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            self.isConnected = false
        }
    }

    /// Send an arbitrary JSON-encodable dictionary. Used by the v1
    /// envelope path — the envelope is assembled in FrameEnvelope and
    /// doesn't fit into IngestFramePayload's schema.
    @discardableResult
    func sendJSON(_ object: [String: Any]) -> Bool {
        queue.sync {
            guard isConnected, let task = webSocketTask,
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) else { return false }
            task.send(.string(text)) { _ in }
            return true
        }
    }

    var connected: Bool { queue.sync { isConnected } }

    private func openSocket(url: URL) {
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
        print("[ws] connecting to \(url)")
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let delay = min(pow(2.0, Double(retryAttempt)), 30.0)
        retryAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, let url = self.endpointURL else { return }
            self.openSocket(url: url)
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        print("[ws] reconnecting in \(Int(delay))s")
    }
}

extension WebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async {
            self.isConnected = true
            self.retryAttempt = 0
            print("[ws] connected")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            self.isConnected = false
            print("[ws] closed")
            self.scheduleReconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            queue.async {
                self.isConnected = false
                print("[ws] error: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }
}
