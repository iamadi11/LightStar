import Accelerate
import CoreMedia
import Foundation

/// Shared FFT + spectral-flux analyzer for system-audio taps (standalone
/// SCStream or the audio output on the Combined screen stream).
final class AudioFFTEngine: @unchecked Sendable {
    private let fftN = 512
    private var fftSetup: vDSP_DFT_Setup?
    private var prevMags: [Float] = []
    private var maxBass = 0.001, maxMid = 0.001, maxHigh = 0.001, maxFlux = 0.001
    private var accumulator: [Float] = []

    func prepare() {
        if fftSetup == nil {
            fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftN), .FORWARD)
        }
    }

    func reset() {
        if let s = fftSetup { vDSP_DFT_DestroySetup(s); fftSetup = nil }
        prevMags = []
        accumulator = []
        maxBass = 0.001; maxMid = 0.001; maxHigh = 0.001; maxFlux = 0.001
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, deliver: (FrequencyBands) -> Void) {
        guard let blockBuf = sampleBuffer.dataBuffer else { return }
        var totalLen = 0
        var rawPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuf, atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen,
            dataPointerOut: &rawPtr
        ) == noErr, let ptr = rawPtr else { return }

        let channels = 2
        let sampleCount = totalLen / (MemoryLayout<Float>.size * channels)
        guard sampleCount > 0 else { return }

        var mono = [Float](repeating: 0, count: sampleCount)
        ptr.withMemoryRebound(to: Float.self, capacity: sampleCount * channels) { fp in
            for i in 0..<sampleCount {
                mono[i] = (fp[i * channels] + fp[i * channels + 1]) * 0.5
            }
        }

        accumulator.append(contentsOf: mono)
        var offset = 0
        while accumulator.count - offset >= fftN {
            let window = Array(accumulator[offset ..< offset + fftN])
            offset += fftN
            deliver(analyze(window, sampleRate: 44100))
        }
        if offset > 0 { accumulator = Array(accumulator[offset...]) }
    }

    private func analyze(_ samples: [Float], sampleRate: Double) -> FrequencyBands {
        let n = samples.count
        var rmsVal: Float = 0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(n))
        let rms = min(1.0, Double(rmsVal) * 8.0)

        guard let setup = fftSetup else {
            return FrequencyBands(bass: 0, mid: 0, high: 0, rms: rms, flux: 0)
        }

        var windowed = [Float](repeating: 0, count: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var realIn = windowed
        var imagIn = [Float](repeating: 0, count: n)
        var realOut = [Float](repeating: 0, count: n)
        var imagOut = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        let half = n / 2
        var mags = [Float](repeating: 0, count: half)
        realOut.withUnsafeBufferPointer { rp in
            imagOut.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: ip.baseAddress!)
                )
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        let s = 1.0 / Float(n)
        vDSP_vsmul(mags, 1, [s], &mags, 1, vDSP_Length(half))

        let binHz = sampleRate / Double(n)
        let rawBass = bandRMS(mags, lo: 20, hi: 200, binHz: binHz)
        let rawMid = bandRMS(mags, lo: 200, hi: 2000, binHz: binHz)
        let rawHigh = bandRMS(mags, lo: 2000, hi: 8000, binHz: binHz)

        maxBass = max(maxBass * 0.995, rawBass + 1e-9)
        maxMid = max(maxMid * 0.995, rawMid + 1e-9)
        maxHigh = max(maxHigh * 0.995, rawHigh + 1e-9)

        let bass = min(1.0, rawBass / maxBass)
        let mid = min(1.0, rawMid / maxMid)
        let high = min(1.0, rawHigh / maxHigh)

        var flux = 0.0
        if prevMags.count == half {
            for i in 0..<half {
                let d = Double(mags[i] - prevMags[i])
                if d > 0 { flux += d }
            }
        }
        prevMags = mags
        maxFlux = max(maxFlux * 0.99, flux + 1e-9)
        let normFlux = min(1.0, flux / maxFlux)

        return FrequencyBands(bass: bass, mid: mid, high: high, rms: rms, flux: normFlux)
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
