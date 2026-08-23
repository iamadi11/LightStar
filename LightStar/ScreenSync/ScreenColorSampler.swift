import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

@MainActor
final class ScreenColorSampler: NSObject {

    var onColor: ((Double, Double, Double) -> Void)?
    var responsiveness: Double = 1.0   // unused, kept for API compat

    // Display selection — set before calling start()
    var selectedDisplayID: CGDirectDisplayID? = nil

    private(set) var isRunning = false
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen.sample", qos: .userInteractive)

    // Returns (displayID, localizedName) pairs for the display picker.
    static func availableDisplays() async -> [(id: CGDirectDisplayID, name: String)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [] }
        return content.displays.enumerated().map { idx, d in
            let name = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID) == d.displayID
            })?.localizedName ?? "Display \(idx + 1)"
            return (d.displayID, name)
        }
    }

    func start() async throws {
        guard !isRunning else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw NSError(domain: "ScreenSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let display = selectedDisplayID.flatMap { id in
            content.displays.first { $0.displayID == id }
        } ?? content.displays.first!

        let cfg = SCStreamConfiguration()
        // 16×9 gives better edge sampling than 8×4 with negligible CPU cost
        cfg.width  = 16
        cfg.height = 9
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.shouldBeOpaque = true

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        try? await stream?.stopCapture()
        stream = nil
        isRunning = false
    }
}

extension ScreenColorSampler: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sb: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let (h, s, v) = dominantHSV(pb)
        DispatchQueue.main.async { [weak self] in
            self?.onColor?(h, s, v)
        }
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
        }
    }

    // Pick the most weighted hue bin
    if let maxBin = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
       histogram[maxBin] > 0 {
        let h = (Double(maxBin) + 0.5) / Double(bins)
        let weight = histogram[maxBin]
        let s = binSat[maxBin] / weight * binSat[maxBin]   // representative sat
        let v = binVal[maxBin] / weight * binVal[maxBin]   // representative val
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
