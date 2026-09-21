#if os(macOS)
import ScreenCaptureKit
import CoreMedia

// Captures system audio mix via SCStream (requires Screen Recording permission).
// Music-only path. Combined attaches this same FFT to the screen SCStream instead
// of opening a second stream, which macOS often starves of audio buffers.
@MainActor
public final class SystemAudioSampler: NSObject {

    public var onBands: ((FrequencyBands) -> Void)?
    private(set) var isRunning = false

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "audio.system", qos: .userInteractive)
    private let engine = AudioFFTEngine()
    private var generation = 0

    public func start() async throws {
        guard !isRunning else { return }
        generation &+= 1
        let gen = generation

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 44100
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()

        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            try? await s.stopCapture()
            throw CancellationError()
        }
        engine.prepare()
        stream = s
        isRunning = true
    }

    public func stop() async {
        generation &+= 1
        guard isRunning else { return }
        isRunning = false
        try? await stream?.stopCapture()
        stream = nil
        onBands = nil
        await cleanupEngineOnQueue()
    }

    private func cleanupEngineOnQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.engine.reset()
                cont.resume()
            }
        }
    }
}

extension SystemAudioSampler: SCStreamOutput {
    public nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sb: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }
        engine.ingest(sb) { bands in
            DispatchQueue.main.async { [weak self] in self?.onBands?(bands) }
        }
    }
}

#endif
