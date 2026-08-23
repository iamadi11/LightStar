import AVFoundation
import Accelerate

// Reads microphone amplitude on the audio thread.
// Fires onLevel (0–1) and onBeat on MainActor at ~30 Hz.
// Uses an envelope follower (fast attack, slow decay) so beats feel instant.
final class MicSyncManager: @unchecked Sendable {

    var onLevel: ((Double) -> Void)?
    var onBeat: (() -> Void)?

    private var engine: AVAudioEngine?
    // All written from audio thread only — no locks needed (serial audio thread)
    private var lastFireTime: Double = 0
    private var envelope: Double = 0      // current smoothed level
    private var prevEnvelope: Double = 0  // for beat edge detection
    private let minInterval: Double = 1.0 / 30.0  // 30 Hz

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
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44100

        // 512 frames ≈ 11ms at 44100 Hz — much lower latency than 2048
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buf, _ in
            guard let self else { return }

            let raw = Self.rms(buf, sampleRate: sampleRate)

            // Envelope follower: attack=fast (0.8), decay=slow (0.15)
            // Attack responds in ~1 frame; decay trails for ~6 frames
            let α = raw > self.envelope ? 0.8 : 0.15
            self.envelope = α * raw + (1 - α) * self.envelope

            let now = CACurrentMediaTime()
            guard now - self.lastFireTime >= self.minInterval else { return }
            self.lastFireTime = now

            let level = self.envelope
            let prev = self.prevEnvelope
            self.prevEnvelope = level

            // Beat: envelope rises sharply past 0.2 (relative jump > 50%)
            let isBeat = level > 0.2 && level > prev * 1.5

            DispatchQueue.main.async {
                self.onLevel?(level)
                if isBeat { self.onBeat?() }
            }
        }

        try e.start()
        engine = e
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onLevel = nil
        onBeat = nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> Double {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        vDSP_svesq(data[0], 1, &sum, vDSP_Length(frames))
        let rms = sqrtf(sum / Float(frames))
        return min(1.0, Double(rms) * 15.0)
    }
}
