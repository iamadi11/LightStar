#if canImport(Metal)
import Metal
import QuartzCore
import simd

/// The scene shader's `DisplayParams`, same layout.
public struct DisplayLook {
    /// CanvasStyle order.
    public var look: Int32 = 0
    /// Seconds of drift for the drawn-only parts (lava blobs, aurora curtains, stars).
    public var time: Float = 0
    public var trailGain: Float = 0
    public var wet: Float = 0
    public var exposure: Float = 1
    private var pad0: Float = 0
    private var pad1 = SIMD2<Float>()
    public var palette: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    public init() {}

    public init(style: CanvasStyle, time: Float = 0) {
        look = Int32(CanvasStyle.allCases.firstIndex(of: style) ?? 0)
        self.time = time
        let hues = style.look.hues
        let rgb = (0..<4).map { SIMD4(FluidAutoPilot.rgb(hue: hues[$0 % hues.count]), 1) }
        palette = (rgb[0], rgb[1], rgb[2], rgb[3])
        let finish = style.finish
        trailGain = finish.trails
        wet = finish.wet
    }
}

extension CanvasStyle {
    /// How each look uses the shared effects: particle trails, liquid-glass
    /// shading, glow, and how particles move and shine.
    public struct Finish: Sendable {
        public var trails: Float
        public var wet: Float
        public var bloom: Float
        public var grain: Float
        /// Steady rise of the particles (canvas heights per second, negative = up).
        public var drift: Float
        public var curl: Float
        /// Particles drawn whiter than the colour under them (stars, plankton).
        public var whiten: Float
        public var particleBrightness: Float
    }

    public var finish: Finish {
        switch self {
        case .liquid: return Finish(trails: 0.55, wet: 1, bloom: 0.75, grain: 0.035, drift: 0, curl: 0.01, whiten: 0.15, particleBrightness: 0.32)
        case .aura: return Finish(trails: 0.2, wet: 0, bloom: 0.5, grain: 0.03, drift: 0, curl: 0.02, whiten: 0.3, particleBrightness: 0.18)
        case .lava: return Finish(trails: 0.5, wet: 0, bloom: 0.8, grain: 0.04, drift: -0.035, curl: 0.015, whiten: 0.35, particleBrightness: 0.28)
        case .aurora: return Finish(trails: 0.35, wet: 0, bloom: 0.9, grain: 0.03, drift: -0.012, curl: 0.006, whiten: 0.4, particleBrightness: 0.21)
        case .ocean: return Finish(trails: 0.45, wet: 0.2, bloom: 1.1, grain: 0.03, drift: 0, curl: 0.012, whiten: 0.45, particleBrightness: 0.39)
        case .nebula: return Finish(trails: 0.6, wet: 0.25, bloom: 1.0, grain: 0.035, drift: 0, curl: 0.008, whiten: 0.6, particleBrightness: 0.28)
        case .ink: return Finish(trails: 0.7, wet: 0.5, bloom: 0, grain: 0.025, drift: 0.004, curl: 0.004, whiten: 0, particleBrightness: 0.35)
        }
    }
}

/// Draws the Canvas: particles riding the flow into silk trails, the look,
/// glow, highlight roll-off (EDR-aware) and grain; and the lights' 48×27 copy.
/// All work goes into the caller's command buffer.
public final class CanvasRenderer {
    public struct Params {
        public var look = DisplayLook()
        public var finish = CanvasStyle.liquid.finish
        public var dt: Float = 1.0 / 60
        public var time: Float = 0
        /// EDR headroom of the window's screen (1 on SDR).
        public var headroom: Float = 1
        /// Particles respawned around a point this frame (x, y, radius, on).
        public var burst = SIMD4<Float>(0, 0, 0, 0)
        public var light = LightParams()
    }

    /// The light shader's `LightParams`.
    public struct LightParams {
        public var gain: Float = 1
        public var white: Float = 0
        public var warm: Float = 0
        var pad: Float = 0
        public init(gain: Float = 1, white: Float = 0, warm: Bool = false) {
            self.gain = gain; self.white = white; self.warm = warm ? 1 : 0
        }
    }

    private struct ParticleParams {
        var simTexel: SIMD2<Float>
        var dt: Float
        var time: Float
        var curlNoise: Float
        var drift: Float
        var aspect: Float
        var count: UInt32
        var frame: UInt32
        var lifeMin: Float
        var lifeMax: Float
        var speed: Float
        var burst: SIMD4<Float>
    }
    private struct PointParams { var intensity: Float; var size: Float; var whiten: Float; var pad: Float = 0 }
    private struct TrailParams { var simTexel: SIMD2<Float>; var dt: Float; var decay: Float }
    private struct BloomParams { var texel: SIMD2<Float>; var threshold: Float; var knee: Float }
    private struct FinalParams {
        var bloomGain: Float; var headroom: Float; var grain: Float; var time: Float
        var resolution: SIMD2<Float>; var pad = SIMD2<Float>()
    }

    let device: MTLDevice
    private let library: MTLLibrary
    private let particleUpdate: MTLComputePipelineState
    private let trailFade: MTLComputePipelineState
    private var renderStates: [String: MTLRenderPipelineState] = [:]

    private var particles: MTLBuffer?
    public private(set) var particleCount = 0
    private var trail: (read: MTLTexture, write: MTLTexture)?
    private var scene: MTLTexture?
    /// While the window is hidden only the lights look, so a 480×270 scene does.
    private var smallScene: MTLTexture?
    /// The scene the lights read: the full one, or the small one while hidden.
    private var lightSource: MTLTexture?
    private var bloom: [MTLTexture] = []
    private var frameIndex: UInt32 = 0

    public init?(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: CanvasShaders.source, options: nil),
              let update = library.makeFunction(name: "particleUpdate").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let fade = library.makeFunction(name: "trailFade").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        self.device = device
        self.library = library
        particleUpdate = update
        trailFade = fade
    }

    /// Sizes everything for the colour texture (the scene is drawn at its size)
    /// and a particle budget. Cheap when nothing changed.
    public func prepare(dyeWidth: Int, dyeHeight: Int, particles count: Int) {
        if scene?.width != dyeWidth || scene?.height != dyeHeight {
            scene = texture(dyeWidth, dyeHeight, mipmapped: true)
            // Trails are soft by nature; past 1440 lines they only cost memory.
            let scale = min(1, 1440 / Double(min(dyeWidth, dyeHeight)))
            let tw = max(8, Int(Double(dyeWidth) * scale)), th = max(8, Int(Double(dyeHeight) * scale))
            if let a = texture(tw, th), let b = texture(tw, th) { trail = (a, b); clearTrail = true }
            bloom = []
            var w = dyeWidth / 2, h = dyeHeight / 2
            while bloom.count < 6, w >= 8, h >= 8 {
                if let t = texture(w, h) { bloom.append(t) }
                w /= 2; h /= 2
            }
        }
        if count != particleCount {
            particleCount = count
            particles = count > 0 ? device.makeBuffer(length: count * 16, options: .storageModePrivate) : nil
            seedParticles = true
        }
    }

    private var clearTrail = true
    private var seedParticles = true

    /// Only what the lights need, while the window is hidden: the look at
    /// 480×270, no particles or trails (the picture waits as it was).
    public func renderLightsOnlyScene(_ cb: MTLCommandBuffer, sim: FluidSimulation, params p: Params) {
        guard let dye = sim.dyeTexture else { return }
        sim.prepareMips(cb)
        if smallScene == nil { smallScene = texture(480, 270, mipmapped: true) }
        guard let small = smallScene, let trail = trail?.read else { return }
        var look = p.look
        look.trailGain = 0
        drawScene(cb, into: small, dye: dye, trail: trail, look: look)
        lightSource = small
    }

    private func drawScene(_ cb: MTLCommandBuffer, into target: MTLTexture, dye: MTLTexture, trail: MTLTexture, look: DisplayLook) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let state = renderState("scene"), let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            var look = look
            enc.setRenderPipelineState(state)
            enc.setFragmentTexture(dye, index: 0)
            enc.setFragmentTexture(trail, index: 1)
            enc.setFragmentBytes(&look, length: MemoryLayout<DisplayLook>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
    }

    /// Particles, trails and the scene. Call after the simulation's colour moved.
    public func renderScene(_ cb: MTLCommandBuffer, sim: FluidSimulation, params p: Params) {
        guard let dye = sim.dyeTexture, let velocity = sim.velocityTexture, let scene, var trail else { return }
        sim.prepareMips(cb)
        frameIndex &+= 1
        lightSource = scene

        if clearTrail || seedParticles, let blit = cb.makeBlitCommandEncoder() {
            if clearTrail {
                for t in [trail.read, trail.write] { clearTexture(blit, t) }
                clearTrail = false
            }
            if seedParticles, let particles {
                // Age past any life: every particle respawns at a random spot on the first update.
                blit.fill(buffer: particles, range: 0..<particles.length, value: 0x7F)
                seedParticles = false
            }
            blit.endEncoding()
        }

        // Fade and carry the trails with the flow, then move the particles.
        if let enc = cb.makeComputeCommandEncoder() {
            var tp = TrailParams(simTexel: sim.simTexel, dt: p.dt, decay: pow(0.93, p.dt * 60))
            enc.setComputePipelineState(trailFade)
            enc.setTexture(trail.read, index: 0)
            enc.setTexture(velocity, index: 1)
            enc.setTexture(trail.write, index: 2)
            enc.setBytes(&tp, length: MemoryLayout<TrailParams>.stride, index: 0)
            dispatch2D(enc, trailFade, trail.write.width, trail.write.height)
            if let particles, particleCount > 0 {
                var pp = ParticleParams(simTexel: sim.simTexel, dt: p.dt, time: p.time, curlNoise: p.finish.curl,
                                        drift: p.finish.drift, aspect: sim.canvasAspect, count: UInt32(particleCount),
                                        frame: frameIndex, lifeMin: 2.5, lifeMax: 7, speed: 1, burst: p.burst)
                enc.setComputePipelineState(particleUpdate)
                enc.setBuffer(particles, offset: 0, index: 0)
                enc.setBytes(&pp, length: MemoryLayout<ParticleParams>.stride, index: 1)
                enc.setTexture(velocity, index: 0)
                let w = particleUpdate.threadExecutionWidth
                enc.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            }
            enc.endEncoding()
        }
        trail = (trail.write, trail.read)
        self.trail = trail

        // Particles add their glow onto the faded trails.
        if let particles, particleCount > 0, p.finish.trails > 0, let state = renderState("points") {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = trail.read
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
                var pt = PointParams(intensity: p.finish.particleBrightness,
                                     size: max(1.5, Float(trail.read.height) / 720), whiten: p.finish.whiten)
                enc.setRenderPipelineState(state)
                enc.setVertexBuffer(particles, offset: 0, index: 0)
                enc.setVertexBytes(&pt, length: MemoryLayout<PointParams>.stride, index: 1)
                enc.setVertexTexture(dye, index: 0)
                enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
                enc.endEncoding()
            }
        }

        // The look, shading and trails at the colour's own size.
        drawScene(cb, into: scene, dye: dye, trail: trail.read, look: p.look)
    }

    /// Glow, highlight roll-off and grain into the window's drawable.
    public func renderFinal(_ cb: MTLCommandBuffer, to pass: MTLRenderPassDescriptor, format: MTLPixelFormat,
                            params p: Params) {
        guard let scene, let target = pass.colorAttachments[0].texture else { return }
        let bloomOn = p.finish.bloom > 0 && !bloom.isEmpty
        if bloomOn { renderBloom(cb) }
        guard let state = renderState("final", format: format), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = FinalParams(bloomGain: bloomOn ? p.finish.bloom : 0, headroom: p.headroom, grain: p.finish.grain,
                            time: p.time, resolution: SIMD2(Float(target.width), Float(target.height)))
        enc.setRenderPipelineState(state)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(bloomOn ? bloom[0] : scene, index: 1)
        enc.setFragmentBytes(&f, length: MemoryLayout<FinalParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The lights' copy from the scene's mipmaps (before glow and grain).
    public func renderLights(_ cb: MTLCommandBuffer, into target: MTLTexture, light: LightParams) {
        guard let scene = lightSource ?? scene, let state = renderState("lights", format: target.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var l = light
        enc.setRenderPipelineState(state)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentBytes(&l, length: MemoryLayout<LightParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func renderBloom(_ cb: MTLCommandBuffer) {
        guard let scene, let pre = renderState("bloomPrefilter"), let down = renderState("bloomDown"),
              let up = renderState("bloomUpAdd") else { return }
        func pass(_ target: MTLTexture, _ state: MTLRenderPipelineState, source: MTLTexture, load: Bool, threshold: Float = 0) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = load ? .load : .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { return }
            var b = BloomParams(texel: SIMD2(1 / Float(source.width), 1 / Float(source.height)), threshold: threshold, knee: 0.4)
            enc.setRenderPipelineState(state)
            enc.setFragmentTexture(source, index: 0)
            enc.setFragmentBytes(&b, length: MemoryLayout<BloomParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        pass(bloom[0], pre, source: scene, load: false, threshold: 0.45)
        for i in 1..<bloom.count { pass(bloom[i], down, source: bloom[i - 1], load: false) }
        for i in stride(from: bloom.count - 1, to: 0, by: -1) { pass(bloom[i - 1], up, source: bloom[i], load: true) }
    }

    private func renderState(_ name: String, format: MTLPixelFormat = .rgba16Float) -> MTLRenderPipelineState? {
        let key = "\(name)-\(format.rawValue)"
        if let s = renderStates[key] { return s }
        let d = MTLRenderPipelineDescriptor()
        d.colorAttachments[0].pixelFormat = format
        switch name {
        case "points":
            d.vertexFunction = library.makeFunction(name: "particleVertex")
            d.fragmentFunction = library.makeFunction(name: "particleFragment")
            additive(d)
        case "bloomUpAdd":
            d.vertexFunction = library.makeFunction(name: "displayVertex")
            d.fragmentFunction = library.makeFunction(name: "bloomUp")
            additive(d)
        default:
            let fragment = ["scene": "sceneFragment", "final": "finalFragment", "lights": "lightFragment",
                            "bloomPrefilter": "bloomPrefilter", "bloomDown": "bloomDown"][name] ?? name
            d.vertexFunction = library.makeFunction(name: "displayVertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
        }
        let state = try? device.makeRenderPipelineState(descriptor: d)
        renderStates[key] = state
        return state
    }

    private func additive(_ d: MTLRenderPipelineDescriptor) {
        let a = d.colorAttachments[0]!
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .one
        a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .one
        a.destinationAlphaBlendFactor = .one
    }

    private func texture(_ w: Int, _ h: Int, mipmapped: Bool = false) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func clearTexture(_ blit: MTLBlitCommandEncoder, _ t: MTLTexture) {
        // Private textures can't be filled directly; copy from a zeroed buffer.
        let bytesPerRow = t.width * 8
        guard let zero = device.makeBuffer(length: bytesPerRow * t.height, options: .storageModePrivate) else { return }
        blit.fill(buffer: zero, range: 0..<zero.length, value: 0)
        blit.copy(from: zero, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: zero.length,
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                  to: t, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
    }

    private func dispatch2D(_ enc: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = state.threadExecutionWidth, th = max(1, state.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
#endif
