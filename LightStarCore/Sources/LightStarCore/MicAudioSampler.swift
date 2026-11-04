import AVFoundation
import AVFAudio
import Accelerate

// Captures microphone input via AVAudioEngine.
// Fires onBands at ~86 Hz (512 samples / 44100 Hz) through the same
// AudioFFTEngine as SystemAudioSampler, so both read loudness on one scale. Requires Microphone permission (NSMicrophoneUsageDescription).
@MainActor
public final class MicAudioSampler {

    public var onBands: ((FrequencyBands) -> Void)?
    private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var engineConfigObserver: Any?
    private var tapCore: TapCore?
    private let fftN = 512

    public static let micDeniedError = NSError(
        domain: "MicAudio", code: -5001,
        userInfo: [NSLocalizedDescriptionKey: "Microphone access required"])

    // Generation counter prevents start() from committing after a concurrent stop() has run.
    private var generation = 0

    public func start() async throws {
        guard !isRunning else { return }
        generation &+= 1
        let gen = generation
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw Self.micDeniedError
        }
        if status == .notDetermined {
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            if !granted { throw Self.micDeniedError }
        }
        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else { throw CancellationError() }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif

        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw NSError(domain: "MicAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }

        let sampleRate = fmt.sampleRate
        let channelCount = Int(fmt.channelCount)
        guard channelCount > 0 else {
            throw NSError(domain: "MicAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No audio channels available"])
        }

        let core = TapCore(fftN: fftN, sampleRate: sampleRate, channelCount: channelCount)
        core.owner = self
        core.fft.prepare()

        // AVAudioNodeTapBlock is not @Sendable. A literal here inherits @MainActor
        // from start() and SIGTRAPs on the realtime tap queue. The handler must
        // be created on TapCore (non-isolated).
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(fftN),
            format: fmt,
            block: core.tapHandler
        )

        do {
            try eng.start()
        } catch {
            core.teardownFFT()
            input.removeTap(onBus: 0)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
        guard !CaptureSessionPolicy.isSuperseded(startGeneration: gen, currentGeneration: generation) else {
            input.removeTap(onBus: 0)
            eng.stop()
            core.teardownFFT()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw CancellationError()
        }
        tapCore = core
        engine = eng
        isRunning = true

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                await self.stop()
                try? await self.start()
            }
        }
    }

    public func stop() async {
        generation &+= 1  // invalidate any concurrent start(), even if idle
        guard isRunning else { return }
        isRunning = false
        if let obs = engineConfigObserver { NotificationCenter.default.removeObserver(obs) }
        engineConfigObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onBands = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        let core = tapCore
        tapCore = nil
        await core?.drainAndTeardown()
    }
}

/// FFT + mix live on a serial queue. `@unchecked Sendable` so the AVAudioEngine
/// tap can capture it without hopping onto `MicAudioSampler`'s MainActor.
private final class TapCore: @unchecked Sendable {
    let queue: DispatchQueue
    let fftN: Int
    let sampleRate: Double
    let channelCount: Int
    nonisolated(unsafe) weak var owner: MicAudioSampler?
    let fft = AudioFFTEngine()
    private(set) var tapHandler: AVAudioNodeTapBlock

    init(fftN: Int, sampleRate: Double, channelCount: Int) {
        self.queue = DispatchQueue(label: "audio.mic", qos: .userInteractive)
        self.fftN = fftN
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.tapHandler = { _, _ in }
        self.tapHandler = { [unowned self] buffer, _ in
            self.handle(buffer)
        }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            mono = Array(UnsafeBufferPointer(start: chData[0], count: frameCount))
        } else {
            for ch in 0..<channelCount {
                let ch0 = UnsafeBufferPointer(start: chData[ch], count: frameCount)
                for i in 0..<frameCount { mono[i] += ch0[i] }
            }
            let invCh = 1.0 / Float(channelCount)
            vDSP_vsmul(mono, 1, [invCh], &mono, 1, vDSP_Length(frameCount))
        }

        let samples = mono
        queue.async { self.process(samples) }
    }

    private func process(_ samples: [Float]) {
        fft.ingest(mono: samples, sampleRate: sampleRate) { bands in
            Task { @MainActor [weak owner] in owner?.onBands?(bands) }
        }
    }

    func teardownFFT() {
        fft.reset()
    }

    func drainAndTeardown() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.teardownFFT()
                cont.resume()
            }
        }
    }
}
