import CoreVideo
import CoreGraphics
import AppKit

@MainActor
final class ScreenColorSampler: NSObject {

    var onColor: ((Double, Double, Double) -> Void)?
    var responsiveness: Double = 1.0   // unused, kept for API compat

    // Display selection — set before calling start()
    var selectedDisplayID: CGDirectDisplayID? = nil

    private(set) var isRunning = false
    private var displayStream: CGDisplayStream?

    // Returns (displayID, localizedName) pairs for the display picker.
    // Uses NSScreen directly — no SCShareableContent round-trip needed.
    @MainActor
    static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return (id, screen.localizedName)
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        let displayID = selectedDisplayID ?? CGMainDisplayID()

        let props: [CFString: Any] = [
            CGDisplayStream.preserveAspectRatio: false,
            CGDisplayStream.showCursor: false,
            CGDisplayStream.minimumFrameTime: 1.0 / 60.0,
        ]

        // Deliver on main — 16×9 pixel work is <0.1ms, no background queue needed.
        // Avoids _dispatch_assert_queue_fail from cross-queue @MainActor property access.
        let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: 16, outputHeight: 9,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props as CFDictionary,
            queue: DispatchQueue.main
        ) { [weak self] status, _, surface, _ in
            guard status == .frameComplete, let surface else { return }
            var pbRef: Unmanaged<CVPixelBuffer>?
            CVPixelBufferCreateWithIOSurface(nil, surface, nil, &pbRef)
            guard let pb = pbRef?.takeRetainedValue() else { return }
            let (h, s, v) = dominantHSV(pb)
            self?.onColor?(h, s, v)
        }
        guard let stream else {
            throw NSError(domain: "ScreenSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create display stream — check Screen Recording permission"])
        }

        let err = stream.start()
        guard err == .success else {
            throw NSError(domain: "ScreenSync", code: Int(err.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "Display stream failed to start (CGError \(err.rawValue))"])
        }

        displayStream = stream
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        if let s = displayStream { s.stop() }
        displayStream = nil
        isRunning = false
    }
}

// MARK: - Pixel helpers

// Dominant color via hue histogram on edge pixels.
// Ignores dark pixels (v < 0.12) and desaturated pixels (s < 0.15) —
// black bars, white text, and letterboxing don't pollute the result.
// Falls back to weighted average brightness if no vivid pixels exist.
private func dominantHSV(_ pb: CVPixelBuffer) -> (Double, Double, Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return (0, 0, 0) }

    let w   = CVPixelBufferGetWidth(pb)
    let h   = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)

    let bins = 36   // 10° per bin
    var histogram = [Double](repeating: 0, count: bins)
    var binSat    = [Double](repeating: 0, count: bins)
    var binVal    = [Double](repeating: 0, count: bins)
    var binCount  = [Int](repeating: 0, count: bins)
    var totalV = 0.0, pixCount = 0

    for row in 0..<h {
        for col in 0..<w {
            let isEdge = row == 0 || row == h - 1 || col == 0 || col == w - 1
            let wt: Double = isEdge ? 3.0 : 1.0
            let i = row * bpr + col * 4
            let r = Double(ptr[i + 2]) / 255
            let g = Double(ptr[i + 1]) / 255
            let b = Double(ptr[i])     / 255
            let (hh, ss, vv) = rgbToHSV(r, g, b)
            totalV += vv * wt
            pixCount += 1

            // Skip dark or desaturated pixels — they're not "color"
            guard vv > 0.12, ss > 0.15 else { continue }

            let bin = min(bins - 1, Int(hh * Double(bins)))
            histogram[bin] += wt * ss * vv   // weight by saturation × brightness
            binSat[bin] += ss
            binVal[bin] += vv
            binCount[bin] += 1
        }
    }

    // Pick the most weighted hue bin
    if let maxBin = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
       histogram[maxBin] > 0, binCount[maxBin] > 0 {
        let h = (Double(maxBin) + 0.5) / Double(bins)
        let n = Double(binCount[maxBin])
        let s = binSat[maxBin] / n
        let v = binVal[maxBin] / n
        return (h, min(1, s), min(1, v))
    }

    // Fallback: screen is dark/desaturated — return average brightness as near-white
    let avgV = pixCount > 0 ? totalV / Double(pixCount) : 0
    return (0, 0, avgV)
}

private func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    let s = mx < 1e-6 ? 0.0 : d / mx
    var h = 0.0
    if d > 1e-6 {
        if mx == r      { h = (g - b) / d }
        else if mx == g { h = 2 + (b - r) / d }
        else            { h = 4 + (r - g) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
    }
    return (h, s, mx)
}
