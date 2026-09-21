import AVFoundation
import AVFAudio
import Accelerate

// Captures microphone input via AVAudioEngine.
// Fires onBands at ~86 Hz (512 samples / 44100 Hz) with the same FFT analysis
// as SystemAudioSampler. Requires Microphone permission (NSMicrophoneUsageDescription).
@MainActor
public final class MicAudioSampler {

    public var onBands: ((FrequencyBands) -> Void)?
    private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var engineConfigObserver: Any?
    private let analyzeQueue = DispatchQueue(label: "audio.mic", qos: .userInteractive)
    private let fftN = 512

    // FFT state — only accessed from analyzeQueue (serial)
    nonisolated(unsafe) private var fftSetup: vDSP_DFT_Setup?
    nonisolated(unsafe) private var prevMags: [Float] = []
    nonisolated(unsafe) private var maxBass = 0.001, maxMid = 0.001, maxHigh = 0.001, maxFlux = 0.001
    nonisolated(unsafe) private var accumulator: [Float] = []

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
        guard generation == gen else { return }

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

        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftN), .FORWARD)

        let sampleRate = fmt.sampleRate
        let channelCount = Int(fmt.channelCount)
        guard channelCount > 0 else {
            throw NSError(domain: "MicAudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No audio channels available"])
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftN), format: fmt) {
            [weak self] buffer, _ in
            guard let self,
                  let chData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Mix to mono
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

            self.analyzeQueue.async { [weak self] in
                guard let self else { return }
                self.accumulator.append(contentsOf: mono)
                var offset = 0
                while self.accumulator.count - offset >= self.fftN {
                    let window = Array(self.accumulator[offset ..< offset + self.fftN])
                    offset += self.fftN
                    let bands = self.analyze(window, sampleRate: sampleRate)
                    DispatchQueue.main.async { [weak self] in self?.onBands?(bands) }
                }
                if offset > 0 { self.accumulator = Array(self.accumulator[offset...]) }
            }
        }

        do {
            try eng.start()
        } catch {
            if let s = fftSetup { vDSP_DFT_DestroySetup(s); fftSetup = nil }
            input.removeTap(onBus: 0)
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
        guard generation == gen else {
            input.removeTap(onBus: 0)
            eng.stop()
            if let s = fftSetup { vDSP_DFT_DestroySetup(s); fftSetup = nil }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }
        engine = eng
        isRunning = true

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            analyzeQueue.async {
                if let s = self.fftSetup { vDSP_DFT_DestroySetup(s); self.fftSetup = nil }
                self.prevMags = []; self.accumulator = []
                self.maxBass = 0.001; self.maxMid = 0.001; self.maxHigh = 0.001; self.maxFlux = 0.001
                cont.resume()
            }
        }
    }
}

// MARK: - FFT (same algorithm as SystemAudioSampler)

public extension MicAudioSampler {
    nonisolated private func analyze(_ samples: [Float], sampleRate: Double) -> FrequencyBands {
        let n = samples.count
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(n))
        let rms = min(1.0, Double(rmsVal) * 20.0)  // mic is quieter than system audio

        guard let setup = fftSetup else {
            return FrequencyBands(bass: 0, mid: 0, high: 0, rms: rms, flux: 0)
        }

        var windowed = [Float](repeating: 0, count: n)
        var window   = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realIn  = windowed
        var imagIn  = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        let half = n / 2
        var mags = [Float](repeating: 0, count: half)
        realOut.withUnsafeBufferPointer { rp in
            imagOut.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        let s = 1.0 / Float(n); vDSP_vsmul(mags, 1, [s], &mags, 1, vDSP_Length(half))

        let binHz = sampleRate / Double(n)
        let rawBass = bandRMS(mags, lo:   20, hi:   200, binHz: binHz)
        let rawMid  = bandRMS(mags, lo:  200, hi:  2000, binHz: binHz)
        let rawHigh = bandRMS(mags, lo: 2000, hi:  8000, binHz: binHz)

        maxBass = max(maxBass * 0.995, rawBass + 1e-9)
        maxMid  = max(maxMid  * 0.995, rawMid  + 1e-9)
        maxHigh = max(maxHigh * 0.995, rawHigh + 1e-9)

        let bass = min(1.0, rawBass / maxBass)
        let mid  = min(1.0, rawMid  / maxMid)
        let high = min(1.0, rawHigh / maxHigh)

        var flux = 0.0
        if prevMags.count == half {
            for i in 0..<half { let d = Double(mags[i] - prevMags[i]); if d > 0 { flux += d } }
        }
        prevMags = mags
        maxFlux = max(maxFlux * 0.99, flux + 1e-9)
        let normFlux = min(1.0, flux / maxFlux)

        return FrequencyBands(bass: bass, mid: mid, high: high, rms: rms, flux: normFlux)
    }

    nonisolated private func bandRMS(_ mags: [Float], lo: Double, hi: Double, binHz: Double) -> Double {
        let loIdx = max(1, Int(lo / binHz))
        let hiIdx = min(mags.count - 1, Int(hi / binHz))
        guard loIdx <= hiIdx else { return 0 }
        let slice = Array(mags[loIdx...hiIdx])
        var sum: Float = 0
        vDSP_svesq(slice, 1, &sum, vDSP_Length(slice.count))
        return Double(sqrtf(sum / Float(slice.count)))
    }
}
