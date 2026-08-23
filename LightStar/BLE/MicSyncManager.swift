import AVFoundation
import Accelerate

struct FrequencyBands: Sendable {
    var bass: Double    // 20–200 Hz  — normalised 0–1 against rolling max
    var mid:  Double    // 200–2000 Hz
    var high: Double    // 2000–8000 Hz
    var rms:  Double    // overall loudness
    var isBeat: Bool    // spectral flux onset
}

// Fires onBands at audio buffer rate (~90 Hz / 512 frames at 44100).
// Uses adaptive per-band normalisation so scale is mic-independent.
// Beat detection via spectral flux — more reliable than envelope threshold.
final class MicSyncManager: @unchecked Sendable {

    var onBands: ((FrequencyBands) -> Void)?

    private var engine: AVAudioEngine?
    private var fftSetup: vDSP_DFT_Setup?

    // Adaptive rolling max — decays slowly so gain self-calibrates
    private var maxBass: Double = 0.001
    private var maxMid:  Double = 0.001
    private var maxHigh: Double = 0.001
    private var maxFlux: Double = 0.001

    // Spectral flux beat detection
    private var prevMags: [Float] = []

    func start() async throws {
        guard engine == nil else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw NSError(domain: "MicSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied"])
        }

        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100.0

        let bufSize: AVAudioFrameCount = 512
        let fftN = Int(bufSize)
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftN), .FORWARD)

        input.installTap(onBus: 0, bufferSize: bufSize, format: format) { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData else { return }
            let frames = Int(buf.frameLength)
            guard frames >= 64 else { return }
            let bands = self.analyze(data[0], count: frames, sampleRate: sampleRate)
            DispatchQueue.main.async { self.onBands?(bands) }
        }

        try e.start()
        engine = e
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let s = fftSetup { vDSP_DFT_DestroySetup(s); fftSetup = nil }
        onBands = nil
        prevMags = []
        maxBass = 0.001; maxMid = 0.001; maxHigh = 0.001; maxFlux = 0.001
    }

    // MARK: - Analysis

    private func analyze(_ samples: UnsafePointer<Float>,
                         count n: Int,
                         sampleRate: Double) -> FrequencyBands {
        // Overall RMS
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(n))
        let rms = min(1.0, Double(rmsVal) * 15.0)

        guard let setup = fftSetup else {
            return FrequencyBands(bass: 0, mid: 0, high: 0, rms: rms, isBeat: false)
        }

        // Hann window
        var windowed = [Float](repeating: 0, count: n)
        var window   = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // DFT
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
        let scale = 1.0 / Float(n)
        vDSP_vsmul(mags, 1, [scale], &mags, 1, vDSP_Length(half))

        let binHz = sampleRate / Double(n)

        // Raw band energies (no fixed scale — we normalise adaptively below)
        let rawBass = bandRMS(mags, lo:   20, hi:   200, binHz: binHz)
        let rawMid  = bandRMS(mags, lo:  200, hi:  2000, binHz: binHz)
        let rawHigh = bandRMS(mags, lo: 2000, hi:  8000, binHz: binHz)

        // Adaptive rolling max — decays 0.5% per frame so it tracks environment
        maxBass = max(maxBass * 0.995, rawBass + 1e-9)
        maxMid  = max(maxMid  * 0.995, rawMid  + 1e-9)
        maxHigh = max(maxHigh * 0.995, rawHigh + 1e-9)

        let bass = min(1.0, rawBass / maxBass)
        let mid  = min(1.0, rawMid  / maxMid)
        let high = min(1.0, rawHigh / maxHigh)

        // Spectral flux beat detection:
        // Sum of positive magnitude differences from previous frame.
        // Catches onsets regardless of absolute level — works for any mic.
        var flux: Double = 0
        if prevMags.count == half {
            for i in 0..<half {
                let diff = Double(mags[i] - prevMags[i])
                if diff > 0 { flux += diff }
            }
        }
        prevMags = mags

        maxFlux = max(maxFlux * 0.99, flux + 1e-9)
        let normFlux = flux / maxFlux

        // Beat threshold: flux spike above 60% of running max AND minimum loudness
        let isBeat = normFlux > 0.60 && rms > 0.05

        return FrequencyBands(bass: bass, mid: mid, high: high, rms: rms, isBeat: isBeat)
    }

    private func bandRMS(_ mags: [Float], lo: Double, hi: Double, binHz: Double) -> Double {
        let loIdx = max(1, Int(lo / binHz))
        let hiIdx = min(mags.count - 1, Int(hi / binHz))
        guard loIdx <= hiIdx else { return 0 }
        let slice = Array(mags[loIdx...hiIdx])
        var sum: Float = 0
        vDSP_svesq(slice, 1, &sum, vDSP_Length(slice.count))
        return Double(sqrtf(sum / Float(slice.count)))
    }
}
