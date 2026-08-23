import AVFoundation
import Accelerate

struct FrequencyBands: Sendable {
    var bass: Double    // 20–200 Hz  (kick/sub)
    var mid:  Double    // 200–2000 Hz (voice/melody)
    var high: Double    // 2000–8000 Hz (hi-hat/treble)
    var rms:  Double    // overall loudness
    var isBeat: Bool
}

// Fires onBands at the audio buffer rate (~90 Hz at 512 frames / 44100).
// No artificial minInterval — caller throttles BLE writes.
final class MicSyncManager: @unchecked Sendable {

    var onBands: ((FrequencyBands) -> Void)?

    private var engine: AVAudioEngine?
    private var fftSetup: vDSP_DFT_Setup?
    private var prevEnvelope: Double = 0
    private var envelope: Double = 0

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

        // 512 frames ≈ 11 ms at 44100 Hz — tight enough for sub-frame latency
        let bufSize: AVAudioFrameCount = 512
        let fftN = Int(bufSize)
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftN), vDSP_DFT_Direction.FORWARD)

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
        envelope = 0; prevEnvelope = 0
    }

    // MARK: - FFT analysis

    private func analyze(_ samples: UnsafePointer<Float>,
                         count n: Int,
                         sampleRate: Double) -> FrequencyBands {
        // ── RMS + envelope follower ───────────────────────────────────────
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(n))
        let raw = min(1.0, Double(rmsVal) * 15.0)
        let α = raw > envelope ? 0.85 : 0.12
        envelope = α * raw + (1 - α) * envelope
        let isBeat = envelope > 0.2 && envelope > prevEnvelope * 1.5
        prevEnvelope = envelope

        // ── FFT ──────────────────────────────────────────────────────────
        guard let setup = fftSetup else {
            return FrequencyBands(bass: 0, mid: 0, high: 0, rms: envelope, isBeat: isBeat)
        }

        // Hann window
        var windowed = [Float](repeating: 0, count: n)
        var window   = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realIn  = windowed
        var imagIn  = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        // Magnitudes (only need first n/2 bins)
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

        // Normalize by n so level is independent of buffer size
        let scale = 1.0 / Float(n)
        vDSP_vsmul(mags, 1, [scale], &mags, 1, vDSP_Length(half))

        let binHz = sampleRate / Double(n)
        let bass = bandEnergy(mags, lo:   20, hi:   200, binHz: binHz, scale: 80)
        let mid  = bandEnergy(mags, lo:  200, hi:  2000, binHz: binHz, scale: 20)
        let high = bandEnergy(mags, lo: 2000, hi:  8000, binHz: binHz, scale: 12)

        return FrequencyBands(bass: bass, mid: mid, high: high, rms: envelope, isBeat: isBeat)
    }

    private func bandEnergy(_ mags: [Float],
                            lo: Double, hi: Double,
                            binHz: Double, scale: Double) -> Double {
        let loIdx = max(1, Int(lo / binHz))
        let hiIdx = min(mags.count - 1, Int(hi / binHz))
        guard loIdx <= hiIdx else { return 0 }
        var sum: Float = 0
        let slice = Array(mags[loIdx...hiIdx])
        vDSP_sve(slice, 1, &sum, vDSP_Length(slice.count))
        return min(1.0, Double(sum) * scale)
    }
}
