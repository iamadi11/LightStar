#if os(macOS)
import AVFoundation
import QuartzCore
import os

/// Soft generative tones for the Canvas, in the spirit of Eno's Bloom: each
/// stir rings a bell-like note on a pentatonic scale (height picks the pitch,
/// side picks the pan, speed picks the loudness), into a large hall reverb.
/// Off by default; nothing plays in Music mode, where the music is the sound.
@MainActor
public final class CanvasSound {
    public static let defaultsKey = "canvasSound"
    public static var stored: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    public var enabled = false { didSet { enabled ? start() : stop() } }

    private var engine: AVAudioEngine?
    private let core = SynthCore(sampleRate: 48_000)
    private var lastStroke = 0.0
    private var lastStrokePoint = (x: -1.0, y: -1.0)

    public init() {}

    /// A stroke passing (x, y) at `speed` canvas-widths per second. Rings at
    /// most ~9 notes a second and only once the pointer has really moved.
    public func stroke(x: Double, y: Double, speed: Double) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastStroke > 0.11, hypot(x - lastStrokePoint.x, y - lastStrokePoint.y) > 0.035 else { return }
        lastStroke = now
        lastStrokePoint = (x, y)
        core.trigger(.init(frequency: Self.pitch(height: 1 - y), velocity: min(1, 0.25 + speed * 0.6),
                           pan: x * 2 - 1, decay: 1.6))
    }

    /// A single soft note (a tap, a planted well).
    public func note(x: Double, y: Double, velocity: Double = 0.5, low: Bool = false) {
        guard enabled else { return }
        let f = Self.pitch(height: 1 - y) / (low ? 2 : 1)
        core.trigger(.init(frequency: f, velocity: velocity, pan: x * 2 - 1, decay: low ? 2.6 : 1.8))
    }

    /// An arpeggio for a discovery.
    public func chord(rising: Bool = true) {
        guard enabled else { return }
        let degrees = rising ? [0, 4, 7, 12] : [12, 7, 4, 0]
        for (i, d) in degrees.enumerated() {
            core.trigger(.init(frequency: 261.63 * pow(2, Double(d) / 12), velocity: 0.55, pan: Double(i) / 3 - 0.5,
                               decay: 2.4, delay: Double(i) * 0.09))
        }
    }

    /// A low swell at the turn of each breath: root in, fifth out.
    public func breath(inhale: Bool) {
        guard enabled else { return }
        core.trigger(.init(frequency: inhale ? 130.81 : 196.0, velocity: 0.35, pan: 0, decay: 3.5, attack: 0.6))
    }

    /// Major pentatonic over two and a half octaves from G3.
    static func pitch(height: Double) -> Double {
        let scale = [0, 2, 4, 7, 9]
        let index = Int(min(0.999, max(0, height)) * 13)
        let semis = (index / 5) * 12 + scale[index % 5]
        return 196.0 * pow(2, Double(semis) / 12)
    }

    private func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2) else { return }
        let source = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 42
        engine.attach(source)
        engine.attach(reverb)
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.55
        do { try engine.start() } catch { return }
        self.engine = engine
    }

    private func stop() {
        engine?.stop()
        engine = nil
    }
}

/// The synth itself. It runs on the audio thread, so it is built outside the
/// main actor and only shares a locked queue of notes with it.
private final class SynthCore: @unchecked Sendable {
    struct Note: Sendable {
        var frequency: Double
        var velocity: Double
        var pan: Double
        var decay: Double
        var delay: Double = 0
        var attack: Double = 0.006
    }
    private struct Voice {
        var note: Note
        var phase = 0.0
        var age = 0.0
        var active = false
    }

    let sampleRate: Double
    private let queue = OSAllocatedUnfairLock(initialState: [Note]())
    private var voices = [Voice](repeating: Voice(note: Note(frequency: 0, velocity: 0, pan: 0, decay: 1)), count: 14)

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func trigger(_ note: Note) { queue.withLock { $0.append(note) } }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] _, _, frameCount, bufferList in
            render(Int(frameCount), UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
    }

    private func render(_ frames: Int, _ buffers: UnsafeMutableAudioBufferListPointer) {
        let incoming = queue.withLock { q -> [Note] in
            defer { q.removeAll(keepingCapacity: true) }
            return q
        }
        for note in incoming {
            // A free voice, or steal the oldest.
            let i = voices.firstIndex { !$0.active } ?? voices.indices.max { voices[$0].age < voices[$1].age } ?? 0
            voices[i] = Voice(note: note, phase: 0, age: -note.delay, active: true)
        }
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        let dt = 1 / sampleRate
        for f in 0..<frames {
            var l: Double = 0, r: Double = 0
            for v in voices.indices where voices[v].active {
                voices[v].age += dt
                let age = voices[v].age
                guard age >= 0 else { continue }
                let n = voices[v].note
                let env = min(1, age / n.attack) * exp(-age / n.decay)
                if age > n.decay * 7 { voices[v].active = false; continue }
                voices[v].phase += 2 * .pi * n.frequency * dt
                let p = voices[v].phase
                // A soft bell: fundamental, an inharmonic partial that fades faster, a touch of air.
                let s = sin(p) + 0.35 * sin(2.76 * p) * exp(-age * 2.5) + 0.12 * sin(5.4 * p) * exp(-age * 6)
                let a = s * env * n.velocity * 0.18
                l += a * sqrt(0.5 * (1 - n.pan))
                r += a * sqrt(0.5 * (1 + n.pan))
            }
            left[f] = Float(l)
            right?[f] = Float(r)
        }
    }
}
#endif
