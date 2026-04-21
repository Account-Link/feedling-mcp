import ReplayKit
import UIKit
import VideoToolbox

class SampleHandler: RPBroadcastSampleHandler {
    private var lastFrameTime: CFTimeInterval = 0
    private var frameInterval: CFTimeInterval = CFTimeInterval(SharedConfig.captureIntervalMsDefault) / 1000.0
    private let processingQueue = DispatchQueue(label: "com.feedling.frameProcessing", qos: .userInitiated)
    let webSocketFrameQueue = WebSocketFrameQueue(maxPendingFrames: 60)
    private var currentSessionURL: URL?
    private var frameIndex: Int = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        frameInterval = SharedConfig.captureIntervalSeconds
        lastFrameTime = CACurrentMediaTime()
        frameIndex = 0
        currentSessionURL = SharedConfig.createSessionDirectory()

        let token = SharedConfig.ingestToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = SharedConfig.ingestEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        WebSocketManager.shared.connect(endpoint: endpoint.isEmpty ? SharedConfig.defaultIngestEndpoint : endpoint,
                                        token: token.isEmpty ? "feedling" : token)
        print("[broadcast] started, interval=\(Int(frameInterval * 1000))ms, endpoint=\(endpoint)")
    }

    override func broadcastPaused() {
        print("[broadcast] paused")
    }

    override func broadcastResumed() {
        print("[broadcast] resumed")
    }

    override func broadcastFinished() {
        WebSocketManager.shared.disconnect()
        webSocketFrameQueue.clear()
        print("[broadcast] finished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastFrameTime >= frameInterval else { return }
        lastFrameTime = currentTime
        processingQueue.async { [weak self] in
            self?.extractAndSaveFrame(from: sampleBuffer)
        }
    }

    private func extractAndSaveFrame(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let cg = cgImage else { return }

        let image = UIImage(cgImage: cg)
        SharedConfig.saveImage(image)
        SharedConfig.postFrameUpdateNotification()

        if let sessionURL = currentSessionURL {
            frameIndex += 1
            SharedConfig.saveFrameToSession(image: image, sessionURL: sessionURL, index: frameIndex)
        }

        enqueueFrameForWebSocket(image)
    }
}
