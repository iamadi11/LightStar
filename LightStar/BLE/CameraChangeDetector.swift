import AVFoundation
import CoreImage
import AppKit

final class CameraChangeDetector: NSObject, @unchecked Sendable {

    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "cam.detect")
    nonisolated(unsafe) private var latestFrame: CIImage?
    private let ctx = CIContext()
    private var previewPanel: NSPanel?

    // Observable from UI — shows which camera is active
    nonisolated(unsafe) var activeCameraName: String = "None"

    // All available video cameras. Includes Continuity Camera (iPhone), external, built-in.
    static func availableCameras() -> [AVCaptureDevice] {
        // .continuityCamera = iPhone Continuity Camera (macOS 14+)
        // .external covers USB/Thunderbolt webcams
        // .builtInWideAngleCamera = MacBook FaceTime camera
        let types: [AVCaptureDevice.DeviceType] = [
            .continuityCamera, .external, .builtInWideAngleCamera
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // Starts with the preferred device (nil = auto: Continuity Camera first, then built-in)
    func start(preferredDeviceID: String? = nil) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            throw NSError(domain: "CameraDetector", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"])
        }

        let cameras = Self.availableCameras()
        let device: AVCaptureDevice?
        if let id = preferredDeviceID {
            device = cameras.first(where: { $0.uniqueID == id }) ?? cameras.first
        } else {
            // Prefer Continuity Camera (iPhone) over everything else
            device = cameras.first(where: { $0.deviceType == .continuityCamera })
                    ?? cameras.first(where: { $0.deviceType == .external })
                    ?? cameras.first
        }

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device) else {
            throw NSError(domain: "CameraDetector", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera available"])
        }

        activeCameraName = device.localizedName

        let s = AVCaptureSession()
        s.sessionPreset = .low
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(out)
        s.startRunning()
        session = s
        let name = device.localizedName
        // AVCaptureSession isn't Sendable; stash before hopping to MainActor.
        nonisolated(unsafe) let sendableSession = s
        await MainActor.run { self.showPreview(session: sendableSession, cameraName: name) }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        latestFrame = nil
        activeCameraName = "None"
        DispatchQueue.main.async { self.hidePreview() }
    }

    func snapshot(afterMs: UInt64 = 200) async -> (brightness: Double, hue: Double) {
        try? await Task.sleep(nanoseconds: afterMs * 1_000_000)
        return await withCheckedContinuation { cont in
            queue.async {
                guard let frame = self.latestFrame else { cont.resume(returning: (0, 0)); return }
                cont.resume(returning: Self.avgPixel(frame, ctx: self.ctx))
            }
        }
    }

    // MARK: - Preview panel

    @MainActor
    private func showPreview(session: AVCaptureSession, cameraName: String) {
        let isPhone = cameraName.lowercased().contains("iphone")
        let label = isPhone
            ? "🔴 iPhone — point at LED strip"
            : "🔴 LIVE — aim at LED strip"

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 196),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = isPhone ? "iPhone Camera" : "Camera — \(cameraName)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let videoView = NSView(frame: NSRect(x: 0, y: 28, width: 240, height: 168))
        videoView.wantsLayer = true
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = videoView.bounds
        videoView.layer?.addSublayer(previewLayer)

        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: 0, y: 6, width: 240, height: 18)
        labelField.alignment = .center
        labelField.font = .systemFont(ofSize: 11, weight: .medium)
        labelField.textColor = .secondaryLabelColor

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 196))
        contentView.addSubview(videoView)
        contentView.addSubview(labelField)
        panel.contentView = contentView

        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 260,
                                         y: screen.visibleFrame.maxY - 216))
        }
        panel.orderFront(nil)
        previewPanel = panel
    }

    @MainActor
    private func hidePreview() {
        previewPanel?.close()
        previewPanel = nil
    }
}

extension CameraChangeDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestFrame = CIImage(cvPixelBuffer: pb)
    }
}

private extension CameraChangeDetector {
    static func avgPixel(_ image: CIImage, ctx: CIContext) -> (brightness: Double, hue: Double) {
        guard let filter = CIFilter(name: "CIAreaAverage") else { return (0, 0) }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let out = filter.outputImage else { return (0, 0) }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out,
                   toBitmap: &px,
                   rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8,
                   colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Double(px[0]) / 255, g = Double(px[1]) / 255, b = Double(px[2]) / 255
        let brightness = (r + g + b) / 3
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var hue = 0.0
        if d > 0.01 {
            if mx == r { hue = (g - b) / d }
            else if mx == g { hue = 2 + (b - r) / d }
            else { hue = 4 + (r - g) / d }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
        }
        return (brightness, hue)
    }
}
