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
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
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
        let (r, g, b) = edgeWeightedRGB(pb)
        let (h, s, v) = rgbToHSV(r, g, b)
        DispatchQueue.main.async { [weak self] in
            self?.onColor?(h, s, v)
        }
    }
}

// MARK: - Pixel helpers

// Weights border pixels 3× — approximates Ambilight edge sampling.
private func edgeWeightedRGB(_ pb: CVPixelBuffer) -> (Double, Double, Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return (0, 0, 0) }

    let w   = CVPixelBufferGetWidth(pb)
    let h   = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let ptr = base.assumingMemoryBound(to: UInt8.self)

    var sumR = 0.0, sumG = 0.0, sumB = 0.0, total = 0.0
    for row in 0..<h {
        for col in 0..<w {
            let isEdge = row == 0 || row == h - 1 || col == 0 || col == w - 1
            let wt: Double = isEdge ? 3.0 : 1.0
            let i = row * bpr + col * 4   // BGRA
            sumB += wt * Double(ptr[i])
            sumG += wt * Double(ptr[i + 1])
            sumR += wt * Double(ptr[i + 2])
            total += wt
        }
    }
    let n = total * 255
    return (sumR / n, sumG / n, sumB / n)
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
