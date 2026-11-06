/// A push of colour and motion into the fluid. Position is 0…1 with y down,
/// like the view; velocity is in simulation cells per second.
public struct FluidSplat: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var dx: Double
    public var dy: Double
    public var color: SIMD3<Float>
    /// Gaussian radius as a share of the canvas height (squared falloff, as in the original).
    public var radius: Double

    public init(x: Double, y: Double, dx: Double, dy: Double, color: SIMD3<Float>, radius: Double = 0.0025) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.color = color; self.radius = radius
    }
}

#if canImport(Metal)
import Metal
import simd

/// Real-time 2-D fluid on the GPU for the Canvas. Velocity runs on a coarse
/// grid; colour ("dye") on a finer one that is drawn at the view's own
/// resolution. All GPU work is encoded into the caller's command buffer.
/// How finely the colour is drawn, whatever the screen. Above the screen's
/// own resolution the picture is filtered down through mipmaps
/// (supersampling), which keeps fine filaments sharp without shimmer.
/// Measured on the BenQ (6016×3384): Native 6.3 ms GPU, 4K 7.3 ms, both 60 fps;
/// 8K was tried and dropped: 458 ms a frame (4 fps) and ~1 GB.
public enum CanvasQuality: String, CaseIterable, Identifiable, Sendable {
    case native, uhd
    public var id: String { rawValue }
    public var title: String { self == .native ? "Standard" : "4K" }
    public static let defaultsKey = "canvasQuality"
    public static var stored: CanvasQuality {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasQuality.init) ?? .uhd
    }

    /// Short side of the colour texture for a drawable whose short side is `screen` pixels.
    public func colourResolution(screen: Int) -> Int {
        switch self {
        case .native: return min(1440, max(256, screen))
        case .uhd: return 2160
        }
    }
}

public final class FluidSimulation {
    public struct Settings: Equatable, Sendable {
        /// Short side of the velocity grid, in cells.
        public var simResolution = 256
        /// Short side of the colour texture, in texels.
        public var dyeResolution = 1024
        public var velocityDissipation: Float = 0.2
        public var dyeDissipation: Float = 0.6
        public var pressureDecay: Float = 0.8
        public var pressureIterations = 20
        public var curl: Float = 30
        public init() {}
    }

    private struct Params {
        var simTexel = SIMD2<Float>(0, 0)
        var dt: Float = 0
        var dissipation: Float = 0
        var point = SIMD2<Float>(0, 0)
        var radius: Float = 0
        var aspect: Float = 1
        var value = SIMD4<Float>(0, 0, 0, 0)
        var curl: Float = 0
        var pressureDecay: Float = 0
        var origin = SIMD2<UInt32>(0, 0)
    }

    /// The `forces` kernel's `ForceParams`, same layout.
    private struct ForceParams {
        var gravity: SIMD2<Float>
        var dt: Float
        var aspect: Float
        var wellCount: Int32
        var pad = SIMD3<Float>(0, 0, 0)
        var wells: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    /// Two textures: read one, write the other, then swap.
    private struct Pair {
        var read: MTLTexture
        var write: MTLTexture
        mutating func swap() { (read, write) = (write, read) }
    }

    public let device: MTLDevice
    public var settings: Settings
    /// Solid edges (Tilt mode): colour pools instead of leaving the canvas.
    public var walls = false
    /// Tilt: screen-space pull (cells/s² on full-strength colour), y down.
    public var gravity = SIMD2<Float>(0, 0)
    /// Gravity wells: x, y (0…1, y down), strength (+ pulls, − pushes), swirl. Up to 8.
    public var wells: [SIMD4<Float>] = []
    private let pipelines: [String: MTLComputePipelineState]
    private let library: MTLLibrary
    private var velocity: Pair?
    private var dye: Pair?
    private var pressure: Pair?
    private var divergenceTex: MTLTexture?
    private var curlTex: MTLTexture?
    private var aspect: Float = 1
    private var pendingVelocity: [FluidSplat] = []
    private var pendingDye: [FluidSplat] = []
    /// New textures start with undefined contents; cleared on the next step.
    private var uncleared: [MTLTexture] = []

    /// Nil when Metal or the shaders aren't available.
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), settings: Settings = Settings()) {
        guard let device, let library = try? device.makeLibrary(source: FluidShaders.source, options: nil) else { return nil }
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["advect", "curl", "vorticity", "divergence", "clear", "scale", "jacobi", "gradientSubtract", "splat", "splatPatch", "forces", "gradientSubtractWalls"] {
            guard let function = library.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else { return nil }
            pipelines[name] = state
        }
        self.device = device
        self.settings = settings
        self.library = library
        self.pipelines = pipelines
    }

    /// Size the grids for a canvas of this shape. Cheap to call every frame:
    /// textures are only rebuilt when the shape or settings change.
    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let newAspect = Float(width) / Float(height)
        let sim = Self.gridSize(shortSide: settings.simResolution, aspect: newAspect)
        let dyeSize = Self.gridSize(shortSide: settings.dyeResolution, aspect: newAspect)
        if let v = velocity?.read, v.width == sim.0, v.height == sim.1,
           let d = dye?.read, d.width == dyeSize.0, d.height == dyeSize.1 { return }
        aspect = newAspect
        velocity = makePair(.rg16Float, sim)
        // 32-bit: tilt builds up hydrostatic pressure past half-float's 65504.
        pressure = makePair(.r32Float, sim)
        divergenceTex = makeTexture(.r32Float, sim)
        curlTex = makeTexture(.r16Float, sim)
        dye = makePair(.rgba16Float, dyeSize, mipmapped: true)
        uncleared = [velocity?.read, velocity?.write, pressure?.read, pressure?.write, divergenceTex, curlTex,
                     dye?.read, dye?.write].compactMap { $0 }
    }

    /// Short side fixed, long side scaled by the aspect ratio.
    static func gridSize(shortSide: Int, aspect: Float) -> (Int, Int) {
        let s = max(8, shortSide)
        let long = max(s, Int((Float(s) * max(aspect, 1 / aspect)).rounded()))
        return aspect >= 1 ? (long, s) : (s, long)
    }

    public func add(_ splat: FluidSplat) { add([splat]) }
    public func add(_ splats: [FluidSplat]) {
        pendingVelocity.append(contentsOf: splats)
        pendingDye.append(contentsOf: splats)
    }

    /// One full time step: physics, then colour.
    public func step(_ commandBuffer: MTLCommandBuffer, dt: Float) {
        stepPhysics(commandBuffer, dt: dt)
        moveColour(commandBuffer, dt: dt)
    }

    /// The flow itself (small grid): pending pushes, swirl, pressure. Cheap
    /// enough to run 240 times a second.
    public func stepPhysics(_ commandBuffer: MTLCommandBuffer, dt: Float) {
        guard var velocity, var pressure, let divergenceTex, let curlTex,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var p = params(dt: dt)
        for t in uncleared { run(encoder, "clear", [t], nil, size: t) }
        uncleared.removeAll()

        for s in pendingVelocity {
            place(&p, s)
            p.value = SIMD4(Float(s.dx), Float(s.dy), 0, 0)
            run(encoder, "splat", [velocity.read, velocity.write], p, size: velocity.write); velocity.swap()
        }
        pendingVelocity.removeAll()
        if gravity != .zero || !wells.isEmpty, let dye = dye?.read {
            var f = ForceParams(gravity: gravity, dt: dt, aspect: aspect, wellCount: Int32(min(8, wells.count)))
            withUnsafeMutableBytes(of: &f.wells) { raw in
                let slots = raw.bindMemory(to: SIMD4<Float>.self)
                for (i, w) in wells.prefix(8).enumerated() { slots[i] = w }
            }
            encoder.setComputePipelineState(pipelines["forces"]!)
            encoder.setTexture(velocity.read, index: 0)
            encoder.setTexture(dye, index: 1)
            encoder.setTexture(velocity.write, index: 2)
            encoder.setBytes(&f, length: MemoryLayout<ForceParams>.stride, index: 0)
            dispatch(encoder, pipelines["forces"]!, width: velocity.write.width, height: velocity.write.height)
            velocity.swap()
        }

        run(encoder, "curl", [velocity.read, curlTex], nil, size: curlTex)
        run(encoder, "vorticity", [velocity.read, curlTex, velocity.write], p, size: velocity.write); velocity.swap()
        run(encoder, "divergence", [velocity.read, divergenceTex], nil, size: divergenceTex)
        run(encoder, "scale", [pressure.read, pressure.write], p, size: pressure.write); pressure.swap()
        for _ in 0..<settings.pressureIterations {
            run(encoder, "jacobi", [pressure.read, divergenceTex, pressure.write], nil, size: pressure.write); pressure.swap()
        }
        run(encoder, walls ? "gradientSubtractWalls" : "gradientSubtract", [pressure.read, velocity.read, velocity.write], nil, size: velocity.write); velocity.swap()
        p.dissipation = settings.velocityDissipation
        run(encoder, "advect", [velocity.read, velocity.read, velocity.write], p, size: velocity.write); velocity.swap()
        encoder.endEncoding()
        self.velocity = velocity
        self.pressure = pressure
    }

    /// Carries the colour along the flow (big texture), once per drawn frame:
    /// colour only has to move as often as it's seen. Splats touch just their patch.
    public func moveColour(_ commandBuffer: MTLCommandBuffer, dt: Float) {
        guard let velocity, var dye, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var p = params(dt: dt)
        for s in pendingDye {
            place(&p, s)
            p.value = SIMD4(s.color, 1)
            // exp(-9) ≈ 0.0001: past three "radii" a splat adds nothing visible.
            let reachY = sqrt(9 * p.radius), reachX = reachY / aspect
            let w = Float(dye.read.width), h = Float(dye.read.height)
            let x0 = max(0, Int((p.point.x - reachX) * w)), x1 = min(Int(w), Int(((p.point.x + reachX) * w).rounded(.up)))
            let y0 = max(0, Int((p.point.y - reachY) * h)), y1 = min(Int(h), Int(((p.point.y + reachY) * h).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            p.origin = SIMD2(UInt32(x0), UInt32(y0))
            run(encoder, "splatPatch", [dye.read], p, width: x1 - x0, height: y1 - y0)
        }
        pendingDye.removeAll()
        p.origin = .zero
        p.dissipation = settings.dyeDissipation
        run(encoder, "advect", [velocity.read, dye.read, dye.write], p, size: dye.write); dye.swap()
        encoder.endEncoding()
        self.dye = dye
        mipsStale = true
    }

    /// Set when the colour moved; the next draw rebuilds the mipmaps once.
    private var mipsStale = true

    private func params(dt: Float) -> Params {
        guard let v = velocity?.read else { return Params() }
        return Params(simTexel: SIMD2(1 / Float(v.width), 1 / Float(v.height)), dt: dt, aspect: aspect,
                      curl: settings.curl, pressureDecay: settings.pressureDecay)
    }

    private func place(_ p: inout Params, _ s: FluidSplat) {
        p.point = SIMD2(Float(s.x), Float(s.y))
        p.radius = Float(s.radius) * (aspect > 1 ? aspect : 1)
    }

    /// The flow (cells per second) and the colour, for the renderer.
    public var velocityTexture: MTLTexture? { velocity?.read }
    public var dyeTexture: MTLTexture? { dye?.read }
    /// One over the velocity grid's size: velocity × this = canvas widths per second.
    public var simTexel: SIMD2<Float> { params(dt: 0).simTexel }
    public var canvasAspect: Float { aspect }

    /// Rebuilds the colour's mipmaps once after it moved (looks blur with them,
    /// the lights average with them).
    public func prepareMips(_ commandBuffer: MTLCommandBuffer) {
        guard mipsStale, let dye = dye?.read, dye.mipmapLevelCount > 1,
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: dye)
        blit.endEncoding()
        mipsStale = false
    }

    /// Wipes the colour and the flow (a fresh canvas).
    public func clear() {
        uncleared = [velocity?.read, velocity?.write, pressure?.read, pressure?.write, dye?.read, dye?.write].compactMap { $0 }
        pendingDye.removeAll(); pendingVelocity.removeAll()
    }

    private func run(_ encoder: MTLComputeCommandEncoder, _ name: String, _ textures: [MTLTexture],
                     _ params: Params?, size: MTLTexture) {
        run(encoder, name, textures, params, width: size.width, height: size.height)
    }

    private func run(_ encoder: MTLComputeCommandEncoder, _ name: String, _ textures: [MTLTexture],
                     _ params: Params?, width: Int, height: Int) {
        guard let state = pipelines[name] else { return }
        encoder.setComputePipelineState(state)
        for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
        if var params { encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0) }
        dispatch(encoder, state, width: width, height: height)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState, width: Int, height: Int) {
        let w = state.threadExecutionWidth, h = max(1, state.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func makeTexture(_ format: MTLPixelFormat, _ size: (Int, Int), mipmapped: Bool = false) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.0, height: size.1, mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func makePair(_ format: MTLPixelFormat, _ size: (Int, Int), mipmapped: Bool = false) -> Pair? {
        guard let a = makeTexture(format, size, mipmapped: mipmapped),
              let b = makeTexture(format, size, mipmapped: mipmapped) else { return nil }
        return Pair(read: a, write: b)
    }
}
#endif
