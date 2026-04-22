import UIKit
import Vision

extension SampleHandler {
    func enqueueFrameForWebSocket(_ image: UIImage) {
        webSocketFrameQueue.enqueue(image: image)
    }
}

final class WebSocketFrameQueue {
    private struct PendingFrame {
        let image: UIImage
        let enqueueTs: TimeInterval
    }

    private let consumerQueue = DispatchQueue(label: "com.feedling.wsConsumer", qos: .utility)
    private let framesQueue = DispatchQueue(label: "com.feedling.pendingFrames", qos: .utility)
    private var pendingFrames: [PendingFrame] = []
    private var isConsuming = false
    private let maxPendingFrames: Int

    init(maxPendingFrames: Int) {
        self.maxPendingFrames = maxPendingFrames
    }

    func enqueue(image: UIImage) {
        framesQueue.async { [weak self] in
            guard let self else { return }
            if self.pendingFrames.count >= self.maxPendingFrames {
                self.pendingFrames.removeFirst()
            }
            self.pendingFrames.append(PendingFrame(image: image, enqueueTs: Date().timeIntervalSince1970))
            self.startConsumingIfNeeded()
        }
    }

    func clear() {
        framesQueue.async { [weak self] in
            self?.pendingFrames.removeAll()
            self?.isConsuming = false
        }
    }

    private func startConsumingIfNeeded() {
        guard !isConsuming else { return }
        isConsuming = true
        consumerQueue.async { [weak self] in self?.consume() }
    }

    private func consume() {
        while true {
            let next: PendingFrame? = framesQueue.sync {
                if pendingFrames.isEmpty { isConsuming = false; return nil }
                return pendingFrames.removeFirst()
            }
            guard let frame = next else { return }
            send(frame: frame)
        }
    }

    private func send(frame: PendingFrame) {
        guard WebSocketManager.shared.connected else { return }

        let resized = resizeIfNeeded(frame.image, maxEdge: 960)
        // 0.5 balances wire-size (CVM egress is per-TCP throttled)
        // against future server-side OCR, which will run on these
        // bytes inside the enclave. Q=0.4 starts to mush small text;
        // Q=0.5 preserves legibility at ~30% fewer bytes than Q=0.6.
        guard let jpegData = resized.jpegData(compressionQuality: 0.5) else { return }

        let ocrText = performOCR(from: resized)
        let bundleId = "com.feedling.mcp"

        let payload = IngestFramePayload(
            type: "frame",
            ts: frame.enqueueTs,
            app: bundleId,
            bundle: bundleId,
            ocrText: ocrText,
            urls: [],
            image: jpegData.base64EncodedString(),
            w: Int(resized.size.width),
            h: Int(resized.size.height),
            tierHint: 2,
            routingSignals: IngestRoutingSignals(
                dhashDistance: 64,
                ocrTextLength: ocrText.count,
                ocrURLCount: 0,
                bundleId: bundleId,
                isTextHeavyApp: false
            )
        )

        // All frames are v1 envelopes — backend drops anything else at
        // _save_frame. If the App Group ctx is missing, the main app
        // hasn't published keys yet; skip the frame rather than firing
        // plaintext the server will throw away.
        guard let ctx = FrameEnvelope.loadContext(),
              let inner = try? JSONEncoder().encode(payload),
              let env = FrameEnvelope.wrap(plaintext: inner, ctx: ctx) else {
            print("[ws] skipping frame — v1 envelope context unavailable")
            return
        }
        var wire = env
        wire["type"] = "frame"            // backend WS handler routes on this
        wire["ts"] = frame.enqueueTs      // index field — server stores in frames_meta
        WebSocketManager.shared.sendJSON(wire)
        print("[ws] sent v1 frame envelope body_ct_len=\(((env["envelope"] as? [String:Any])?["body_ct"] as? String ?? "").count)")
    }

    private func resizeIfNeeded(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        // UIImage from VTCreateCGImageFromCVPixelBuffer has scale=1, so
        // .size is already in pixels. UIGraphicsImageRenderer defaults
        // to the device scale (@3x on iPhone), which would render a
        // requested 442x960 target as 1326x2880 actual pixels and bloat
        // every JPEG ~9x. Force scale=1 so we get exactly what we asked.
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let ratio = maxEdge / longest
        let size = CGSize(width: floor(image.size.width * ratio),
                          height: floor(image.size.height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func performOCR(from image: UIImage) -> String {
        guard let cg = image.cgImage else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.01
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
