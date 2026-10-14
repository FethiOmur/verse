import CoreMedia
import Foundation
import ScreenCaptureKit

/// Fallback route: ScreenCaptureKit audio for one app (needs Screen Recording permission). Numbers only.
final class SCKCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let env: Envelope
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "tapprobe.sck")
    var info: [String: String] = [:]
    var stopError: String?

    init(env: Envelope) { self.env = env }

    func start(appName: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.applicationName == appName }) else {
            throw CAError(what: "SCK: app '\(appName)' not in shareable content", status: -1)
        }
        guard let display = content.displays.first else { throw CAError(what: "SCK: no display", status: -1) }
        info["sckApp"] = "\(app.applicationName) pid \(app.processID) \(app.bundleIdentifier)"
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.excludesCurrentProcessAudio = true
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        env.sampleRate = 48000
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        let cb = nowSeconds()
        let start = sb.presentationTimeStamp.seconds
        try? sb.withAudioBufferList { abl, _ in
            guard let b = abl.first, let d = b.mData else { return }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            env.add(UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: n),
                    channels: Int(b.mNumberChannels), startHost: start, callbackHost: cb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { stopError = "\(error)" }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }
}
