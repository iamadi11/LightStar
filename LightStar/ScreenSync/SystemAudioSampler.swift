import ScreenCaptureKit
import CoreMedia
import Accelerate

// Captures system audio mix via SCStream (requires Screen Recording permission).
// Fires onBands at ~86 Hz (512 samples / 44100 Hz) with adaptive FFT analysis.
// Same FrequencyBands struct and spectral-flux beat detection as MicSyncManager.
@MainActor
final class SystemAudioSampler: NSObject {

    var onBands: ((FrequencyBands) -> Void)?
    private(set) var isRunning = false

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "audio.system", qos: .userInteractive)

    // FFT state — only accessed from `queue` (serial), nonisolated(unsafe) for Swift 6
    nonisolated(unsafe) private var fftSetup: vDSP_DFT_Setup?
    nonisolated(unsafe) private var prevMags: [Float] = []
    nonisolated(unsafe) private var maxBass = 0.001, maxMid = 0.001, maxHigh = 0.001, maxFlux = 0.001
    nonisolated(unsafe) private var accumulator: [Float] = []
    private let fftN = 512
    // Generation counter prevents start() from committing after a concurrent stop() has run.
    // @MainActor so no extra synchronization needed between start/stop.
    private var generation = 0

    func start() async throws {
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
        // Minimal video required by SCStream even for audio-only capture
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps video (ignored)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftN), .FORWARD)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()

        guard generation == gen else {
            // stop() ran while startCapture was pending — discard and clean up
            try? await s.stopCapture()
            await cleanupFFTOnQueue()
            return
        }
        stream = s
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        generation &+= 1  // invalidate any concurrent start()
        isRunning = false
        try? await stream?.stopCapture()
        stream = nil
        onBands = nil
        // Drain the serial queue THEN destroy FFT resources — prevents use-after-free
        // if analyze() callbacks were dispatched before stopCapture() returned.
        await cleanupFFTOnQueue()
    }

    private func cleanupFFTOnQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let s = self.fftSetup { vDSP_DFT_DestroySetup(s); self.fftSetup = nil }
                self.prevMags = []; self.accumulator = []
                self.maxBass = 0.001; self.maxMid = 0.001; self.maxHigh = 0.001; self.maxFlux = 0.001
                cont.resume()
            }
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioSampler: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sb: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Extract Float32 mono samples from CMSampleBuffer
        guard let blockBuf = sb.dataBuffer else { return }
        var totalLen = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuf, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &rawPtr) == noErr,
              let ptr = rawPtr else { return }

        // SCStream audio is Float32 interleaved stereo at 44100 Hz
        let channels = 2
        let sampleCount = totalLen / (MemoryLayout<Float>.size * channels)
        guard sampleCount > 0 else { return }

        // Mix stereo → mono
        var mono = [Float](repeating: 0, count: sampleCount)
        ptr.withMemoryRebound(to: Float.self, capacity: sampleCount * channels) { fp in
            for i in 0..<sampleCount {
                mono[i] = (fp[i * channels] + fp[i * channels + 1]) * 0.5
            }
        }

        // Accumulate until we have a full FFT window
        accumulator.append(contentsOf: mono)
        while accumulator.count >= fftN {
            let window = Array(accumulator.prefix(fftN))
            accumulator.removeFirst(fftN)
            let bands = analyze(window, sampleRate: 44100)
            DispatchQueue.main.async { [weak self] in self?.onBands?(bands) }
        }
    }
}

// MARK: - FFT (same algorithm as MicSyncManager — adaptive normalisation + spectral flux)

extension SystemAudioSampler {
    nonisolated private func analyze(_ samples: [Float], sampleRate: Double) -> FrequencyBands {
        let n = samples.count
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(n))
        let rms = min(1.0, Double(rmsVal) * 8.0)  // system audio is louder than mic

        guard let setup = fftSetup else {
            return FrequencyBands(bass: 0, mid: 0, high: 0, rms: rms, isBeat: false)
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

        // Spectral flux
        var flux = 0.0
        if prevMags.count == half {
            for i in 0..<half { let d = Double(mags[i] - prevMags[i]); if d > 0 { flux += d } }
        }
        prevMags = mags
        maxFlux = max(maxFlux * 0.99, flux + 1e-9)
        let isBeat = (flux / maxFlux) > 0.60 && rms > 0.03

        return FrequencyBands(bass: bass, mid: mid, high: high, rms: rms, isBeat: isBeat)
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
