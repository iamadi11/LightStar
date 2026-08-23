import ScreenCaptureKit
import CoreMedia
import CoreVideo

// Captures primary display at 30 fps into an 8×4 thumbnail,
// averages pixels → HSV, fires onColor on MainActor with no smoothing.
// Smoothing was removed — EMA at 10fps caused 800ms+ lag.
@MainActor
final class ScreenColorSampler: NSObject {

    // Called on MainActor at each frame. H/S/B each 0–1.
    var onColor: ((Double, Double, Double) -> Void)?

    // unused — kept so callers don't break; EMA removed
    var responsiveness: Double = 1.0

    private(set) var isRunning = false
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "screen.sample", qos: .userInteractive)

    func start() async throws {
        guard !isRunning else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let cfg = SCStreamConfiguration()
        cfg.width  = 8
        cfg.height = 4
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps
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
        let (r, g, b) = avgRGB(pb)
        let (h, s, v) = rgbToHSV(r, g, b)
        DispatchQueue.main.async { [weak self] in
            self?.onColor?(h, s, v)
        }
    }
}

// MARK: - Pixel helpers

private func avgRGB(_ pb: CVPixelBuffer) -> (Double, Double, Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pb) else { return (0, 0, 0) }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let pixels = w * h

    var sumR: Double = 0, sumG: Double = 0, sumB: Double = 0
    let ptr = base.assumingMemoryBound(to: UInt8.self)

    for row in 0..<h {
        for col in 0..<w {
            let i = row * bpr + col * 4
            // kCVPixelFormatType_32BGRA: byte order B G R A
            sumB += Double(ptr[i])
            sumG += Double(ptr[i + 1])
            sumR += Double(ptr[i + 2])
        }
    }
    let n = Double(pixels) * 255
    return (sumR / n, sumG / n, sumB / n)
}

private func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    let v = mx
    let s = mx < 1e-6 ? 0.0 : d / mx
    var h = 0.0
    if d > 1e-6 {
        if mx == r      { h = (g - b) / d }
        else if mx == g { h = 2 + (b - r) / d }
        else            { h = 4 + (r - g) / d }
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
    }
    return (h, s, v)
}
