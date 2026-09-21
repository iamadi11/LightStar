#if os(macOS)
import ScreenCaptureKit
import CoreMedia

// Music and Combined both use this sampler. Combined's screen sampler stays
// video-only. On 14.2+ this is a HAL process tap so Chrome is not in a
// display capture set (that blacks Netflix/Prime for the user).
@MainActor
public final class SystemAudioSampler: NSObject {

    public var onBands: ((FrequencyBands) -> Void)?
    private(set) var isRunning = false

    private var stream: SCStream?
    private var processTapBox: AnyObject?
    private let queue = DispatchQueue(label: "audio.system", qos: .userInteractive)
    private let engine = AudioFFTEngine()
    private var generation = 0

    public func start() async throws {
        guard !isRunning else { return }
        generation &+= 1
        let gen = generation

        if #available(macOS 14.2, *) {
            try startProcessTap(generation: gen)
            return
        }
        try await startDisplayStream(generation: gen)
    }

    public func stop() async {
        generation &+= 1
        guard isRunning else { return }
        isRunning = false
        if #available(macOS 14.2, *) {
            (processTapBox as? SystemAudioProcessTap)?.stop()
            processTapBox = nil
        }
        try? await stream?.stopCapture()
        stream = nil
        onBands = nil
        await cleanupEngineOnQueue()
    }

    @available(macOS 14.2, *)
    private func startProcessTap(generation gen: Int) throws {
        let tap = SystemAudioProcessTap()
        tap.onBands = { [weak self] bands in
            DispatchQueue.main.async { [weak self] in self?.onBands?(bands) }
        }
        try tap.start()
        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            tap.stop()
            throw CancellationError()
        }
        processTapBox = tap
        isRunning = true
    }

    /// macOS 14.0–14.1 only. Display capture includes Chrome and can black DRM video.
    private func startDisplayStream(generation gen: Int) async throws {
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
        // EE-012: prepare FFT before startCapture so early buffers are not zero-band.
        engine.prepare()
        try await s.startCapture()

        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            try? await s.stopCapture()
            throw CancellationError()
        }
        stream = s
        isRunning = true
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
