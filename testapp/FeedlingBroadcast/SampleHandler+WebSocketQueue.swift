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
        guard let jpegData = resized.jpegData(compressionQuality: 0.6) else { return }

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
        WebSocketManager.shared.sendFrame(payload)
        print("[ws] sent frame \(Int(resized.size.width))x\(Int(resized.size.height)) ocr=\(ocrText.count)chars")
    }

    private func resizeIfNeeded(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
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
