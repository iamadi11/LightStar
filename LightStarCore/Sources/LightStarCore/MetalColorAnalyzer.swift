#if os(macOS)
import Metal
import MetalKit
import CoreVideo
import simd

/// GPU-accelerated color analysis using Metal compute shaders.
/// Provides significant performance improvement for larger frame sizes.
public final class MetalColorAnalyzer: @unchecked Sendable {
    
    private let analysisLock = NSLock()
    
    public static let shared: MetalColorAnalyzer? = {
        do {
            return try MetalColorAnalyzer()
        } catch {
            print("[MetalColorAnalyzer] Failed to initialize: \(error)")
            return nil
        }
    }()
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let histogramPipeline: MTLComputePipelineState
    private let rowDarknessPipeline: MTLComputePipelineState
    private let colDarknessPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    
    // Buffers for histogram data (reused across frames)
    private let histogramBuffer: MTLBuffer      // 36 bins
    private let binSatSumBuffer: MTLBuffer      // 36 bins
    private let binValSumBuffer: MTLBuffer      // 36 bins
    private let binCountBuffer: MTLBuffer       // 36 bins
    private let blackCountBuffer: MTLBuffer     // 1 value
    private let totalPixelsBuffer: MTLBuffer    // 1 value
    private let darkRowCountBuffer: MTLBuffer   // 1 value
    private let darkColCountBuffer: MTLBuffer   // 1 value
    
    private let histogramBins = 36
    
    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.noDevice
        }
        self.device = device
        
        guard let queue = device.makeCommandQueue() else {
            throw MetalError.noCommandQueue
        }
        self.commandQueue = queue
        
        // Load Metal library from bundle
        let library: MTLLibrary
        if let bundleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = bundleLib
        } else if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
        } else {
            throw MetalError.noLibrary
        }
        
        // Create compute pipelines
        guard let histogramFunc = library.makeFunction(name: "computeHistogram"),
              let rowDarknessFunc = library.makeFunction(name: "analyzeRowDarkness"),
              let colDarknessFunc = library.makeFunction(name: "analyzeColumnDarkness"),
              let downsampleFunc = library.makeFunction(name: "downsampleTexture") else {
            throw MetalError.noFunction
        }
        
        self.histogramPipeline = try device.makeComputePipelineState(function: histogramFunc)
        self.rowDarknessPipeline = try device.makeComputePipelineState(function: rowDarknessFunc)
        self.colDarknessPipeline = try device.makeComputePipelineState(function: colDarknessFunc)
        self.downsamplePipeline = try device.makeComputePipelineState(function: downsampleFunc)
        
        // Create texture cache for CVPixelBuffer conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            throw MetalError.noTextureCache
        }
        self.textureCache = textureCache
        
        // Pre-allocate buffers
        let binBytes = histogramBins * MemoryLayout<UInt32>.size
        guard let histogram = device.makeBuffer(length: binBytes, options: .storageModeShared),
              let binSatSum = device.makeBuffer(length: binBytes, options: .storageModeShared),
              let binValSum = device.makeBuffer(length: binBytes, options: .storageModeShared),
              let binCount = device.makeBuffer(length: binBytes, options: .storageModeShared),
              let blackCount = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let totalPixels = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let darkRowCount = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let darkColCount = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) else {
            throw MetalError.noBuffer
        }
        
        self.histogramBuffer = histogram
        self.binSatSumBuffer = binSatSum
        self.binValSumBuffer = binValSum
        self.binCountBuffer = binCount
        self.blackCountBuffer = blackCount
        self.totalPixelsBuffer = totalPixels
        self.darkRowCountBuffer = darkRowCount
        self.darkColCountBuffer = darkColCount
    }
    
    /// Analyze a CVPixelBuffer and extract dominant color using GPU.
    /// - Parameter pixelBuffer: The input pixel buffer (BGRA format)
    /// - Returns: Frame analysis with dominant color and black pixel detection
    public func analyze(_ pixelBuffer: CVPixelBuffer) -> FrameAnalysis {
        analysisLock.lock()
        defer { analysisLock.unlock() }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create Metal texture from pixel buffer
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            // Fall back to CPU analysis if Metal texture creation fails
            return cpuFallbackAnalysis(pixelBuffer)
        }
        
        // Clear buffers
        clearBuffers()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return cpuFallbackAnalysis(pixelBuffer)
        }
        
        // Run histogram computation
        computeEncoder.setComputePipelineState(histogramPipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(binSatSumBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(binValSumBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(binCountBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(blackCountBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(totalPixelsBuffer, offset: 0, index: 5)
        
        let histogramThreadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let histogramThreadsPerGroup = MTLSize(
            width: min(16, histogramPipeline.maxTotalThreadsPerThreadgroup),
            height: min(16, histogramPipeline.maxTotalThreadsPerThreadgroup / 16),
            depth: 1
        )
        computeEncoder.dispatchThreads(histogramThreadsPerGrid, threadsPerThreadgroup: histogramThreadsPerGroup)
        
        // Run row darkness analysis
        computeEncoder.setComputePipelineState(rowDarknessPipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(darkRowCountBuffer, offset: 0, index: 0)
        
        let rowThreadsPerGrid = MTLSize(width: height, height: 1, depth: 1)
        let rowThreadsPerGroup = MTLSize(width: min(64, height), height: 1, depth: 1)
        computeEncoder.dispatchThreads(rowThreadsPerGrid, threadsPerThreadgroup: rowThreadsPerGroup)
        
        // Run column darkness analysis
        computeEncoder.setComputePipelineState(colDarknessPipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(darkColCountBuffer, offset: 0, index: 0)
        
        let colThreadsPerGrid = MTLSize(width: width, height: 1, depth: 1)
        let colThreadsPerGroup = MTLSize(width: min(64, width), height: 1, depth: 1)
        computeEncoder.dispatchThreads(colThreadsPerGrid, threadsPerThreadgroup: colThreadsPerGroup)
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        CVMetalTextureCacheFlush(textureCache, 0)

        // Read results from GPU
        return extractResults(width: width, height: height)
    }
    
    private func clearBuffers() {
        memset(histogramBuffer.contents(), 0, histogramBins * MemoryLayout<UInt32>.size)
        memset(binSatSumBuffer.contents(), 0, histogramBins * MemoryLayout<UInt32>.size)
        memset(binValSumBuffer.contents(), 0, histogramBins * MemoryLayout<UInt32>.size)
        memset(binCountBuffer.contents(), 0, histogramBins * MemoryLayout<UInt32>.size)
        memset(blackCountBuffer.contents(), 0, MemoryLayout<UInt32>.size)
        memset(totalPixelsBuffer.contents(), 0, MemoryLayout<UInt32>.size)
        memset(darkRowCountBuffer.contents(), 0, MemoryLayout<UInt32>.size)
        memset(darkColCountBuffer.contents(), 0, MemoryLayout<UInt32>.size)
    }
    
    private func extractResults(width: Int, height: Int) -> FrameAnalysis {
        let histogram = histogramBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let binSatSum = binSatSumBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let binValSum = binValSumBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let binCount = binCountBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let blackCount = blackCountBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee
        let totalPixels = totalPixelsBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee
        let darkRowCount = darkRowCountBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee
        let darkColCount = darkColCountBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee
        
        // Find dominant bin
        var maxBin = 0
        var maxVote: UInt32 = 0
        for i in 0..<histogramBins {
            if histogram[i] > maxVote {
                maxVote = histogram[i]
                maxBin = i
            }
        }
        
        let blackPercentage = totalPixels > 0 ? Double(blackCount) / Double(totalPixels) : 0
        let hasRectangularBlackRegion = Int(darkRowCount) > height / 3 || Int(darkColCount) > width / 3
        
        if maxVote > 0 && binCount[maxBin] > 0 {
            let hue = (Double(maxBin) + 0.5) / Double(histogramBins)
            let count = Double(binCount[maxBin])
            let sat = Double(binSatSum[maxBin]) / count / 10000.0
            let val = Double(binValSum[maxBin]) / count / 10000.0
            
            return FrameAnalysis(
                dominantHue: hue,
                dominantSaturation: min(1, sat),
                dominantBrightness: min(1, val),
                blackPixelPercentage: blackPercentage,
                hasRectangularBlackRegion: hasRectangularBlackRegion
            )
        }
        
        return FrameAnalysis(
            dominantHue: 0,
            dominantSaturation: 0,
            dominantBrightness: 0,
            blackPixelPercentage: blackPercentage,
            hasRectangularBlackRegion: hasRectangularBlackRegion
        )
    }
    
    /// CPU fallback when Metal is unavailable
    private func cpuFallbackAnalysis(_ pixelBuffer: CVPixelBuffer) -> FrameAnalysis {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return FrameAnalysis(dominantHue: 0, dominantSaturation: 0, dominantBrightness: 0)
        }
        
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        
        var histogram = [Double](repeating: 0, count: histogramBins)
        var binSat = [Double](repeating: 0, count: histogramBins)
        var binVal = [Double](repeating: 0, count: histogramBins)
        var binCount = [Int](repeating: 0, count: histogramBins)
        var blackCount = 0
        var pixCount = 0
        var darkRows = 0
        
        for row in 0..<h {
            var rowBlackCount = 0
            for col in 0..<w {
                let i = row * bpr + col * 4
                let r = Double(ptr[i + 2]) / 255
                let g = Double(ptr[i + 1]) / 255
                let b = Double(ptr[i]) / 255
                let (hh, ss, vv) = Self.rgbToHSV(r, g, b)
                
                pixCount += 1
                if vv < 0.05 {
                    blackCount += 1
                    rowBlackCount += 1
                }
                guard vv > 0.12, ss > 0.15 else { continue }
                
                let bin = min(histogramBins - 1, Int(hh * Double(histogramBins)))
                histogram[bin] += ss * vv
                binSat[bin] += ss
                binVal[bin] += vv
                binCount[bin] += 1
            }
            if rowBlackCount > w * 8 / 10 { darkRows += 1 }
        }
        
        var darkCols = 0
        for col in 0..<w {
            var colBlackCount = 0
            for row in 0..<h {
                let i = row * bpr + col * 4
                let r = Double(ptr[i + 2]) / 255
                let g = Double(ptr[i + 1]) / 255
                let b = Double(ptr[i]) / 255
                let (_, _, vv) = Self.rgbToHSV(r, g, b)
                if vv < 0.05 { colBlackCount += 1 }
            }
            if colBlackCount > h * 8 / 10 { darkCols += 1 }
        }
        
        let blackPercentage = pixCount > 0 ? Double(blackCount) / Double(pixCount) : 0
        let hasRectangularBlackRegion = darkRows > h / 3 || darkCols > w / 3
        
        if let maxBin = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
           histogram[maxBin] > 0, binCount[maxBin] > 0 {
            let hue = (Double(maxBin) + 0.5) / Double(histogramBins)
            let n = Double(binCount[maxBin])
            return FrameAnalysis(
                dominantHue: hue,
                dominantSaturation: min(1, binSat[maxBin] / n),
                dominantBrightness: min(1, binVal[maxBin] / n),
                blackPixelPercentage: blackPercentage,
                hasRectangularBlackRegion: hasRectangularBlackRegion
            )
        }
        
        return FrameAnalysis(
            dominantHue: 0,
            dominantSaturation: 0,
            dominantBrightness: 0,
            blackPixelPercentage: blackPercentage,
            hasRectangularBlackRegion: hasRectangularBlackRegion
        )
    }
    
    private static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let s = mx < 1e-6 ? 0.0 : d / mx
        var h = 0.0
        if d > 1e-6 {
            if mx == r { h = (g - b) / d }
            else if mx == g { h = 2 + (b - r) / d }
            else { h = 4 + (r - g) / d }
            h = h.truncatingRemainder(dividingBy: 6) / 6
            if h < 0 { h += 1 }
        }
        return (h, s, mx)
    }
}

// MARK: - Errors

enum MetalError: Error, LocalizedError {
    case noDevice
    case noCommandQueue
    case noLibrary
    case noFunction
    case noTextureCache
    case noBuffer
    
    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device available"
        case .noCommandQueue: return "Failed to create command queue"
        case .noLibrary: return "Failed to load Metal library"
        case .noFunction: return "Failed to find Metal function"
        case .noTextureCache: return "Failed to create texture cache"
        case .noBuffer: return "Failed to create buffer"
        }
    }
}

#endif
