#if os(macOS)
import Foundation
import CoreGraphics
import Metal
import IOKit
import IOSurface

/// Experimental module for investigating macOS display capture capabilities.
/// This module probes various system APIs to document what's accessible.
///
/// IMPORTANT: This is for research/diagnostics only. Based on comprehensive research,
/// direct framebuffer access is not viable on Apple Silicon through public APIs.
/// Protected video content uses compositor-level protection that cannot be bypassed
/// without circumventing DRM, which is explicitly out of scope.
@MainActor
public final class ExperimentalDisplayCapture: ObservableObject {
    
    // MARK: - Types
    
    public struct DisplayInfo: Identifiable, Sendable {
        public let id: CGDirectDisplayID
        public let name: String
        public let width: Int
        public let height: Int
        public let refreshRate: Double
        public let isBuiltin: Bool
        public let isMain: Bool
        public let vendorNumber: UInt32
        public let modelNumber: UInt32
        public let serialNumber: UInt32
        public let colorSpace: String
    }
    
    public struct GPUInfo: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let registryID: UInt64
        public let isLowPower: Bool
        public let isHeadless: Bool
        public let isRemovable: Bool
        public let recommendedMaxWorkingSetSize: UInt64
    }
    
    public struct ProbeResult: Sendable {
        public let api: String
        public let accessible: Bool
        public let notes: String
    }
    
    // MARK: - Published State
    
    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public private(set) var gpus: [GPUInfo] = []
    @Published public private(set) var probeResults: [ProbeResult] = []
    @Published public private(set) var isProbing = false
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Display Enumeration
    
    /// Enumerate all connected displays with detailed information.
    public func enumerateDisplays() {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        
        displays = displayIDs.map { displayID in
            let bounds = CGDisplayBounds(displayID)
            let mode = CGDisplayCopyDisplayMode(displayID)
            let refreshRate = mode?.refreshRate ?? 0
            
            let vendorNumber = CGDisplayVendorNumber(displayID)
            let modelNumber = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)
            
            let colorSpace = CGDisplayCopyColorSpace(displayID)
            let colorSpaceName = colorSpace?.name as String? ?? "Unknown"
            
            return DisplayInfo(
                id: displayID,
                name: getDisplayName(displayID) ?? "Display \(displayID)",
                width: Int(bounds.width),
                height: Int(bounds.height),
                refreshRate: refreshRate,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isMain: CGDisplayIsMain(displayID) != 0,
                vendorNumber: vendorNumber,
                modelNumber: modelNumber,
                serialNumber: serialNumber,
                colorSpace: colorSpaceName
            )
        }
    }
    
    private func getDisplayName(_ displayID: CGDirectDisplayID) -> String? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IODisplayConnect"),
                                           &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        
        var service: io_service_t = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service) }
            
            if let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName)).takeRetainedValue() as? [String: Any],
               let productName = info[kDisplayProductName] as? [String: String],
               let name = productName.values.first {
                return name
            }
            
            service = IOIteratorNext(iter)
        }
        
        return nil
    }
    
    // MARK: - GPU Enumeration
    
    /// Enumerate all Metal-capable GPUs.
    public func enumerateGPUs() {
        let devices = MTLCopyAllDevices()
        gpus = devices.enumerated().map { index, device in
            GPUInfo(
                id: index,
                name: device.name,
                registryID: device.registryID,
                isLowPower: device.isLowPower,
                isHeadless: device.isHeadless,
                isRemovable: device.isRemovable,
                recommendedMaxWorkingSetSize: device.recommendedMaxWorkingSetSize
            )
        }
    }
    
    // MARK: - API Probing
    
    /// Probe various display/capture APIs to document what's accessible.
    public func probeAPIs() async {
        isProbing = true
        defer { isProbing = false }
        
        var results: [ProbeResult] = []
        
        // 1. ScreenCaptureKit
        results.append(await probeScreenCaptureKit())
        
        // 2. CGDisplayStream (legacy)
        results.append(probeCGDisplayStream())
        
        // 3. CGWindowListCreateImage
        results.append(probeCGWindowListCreateImage())
        
        // 4. IOSurface from display
        results.append(probeIOSurfaceFromDisplay())
        
        // 5. Metal texture from display
        results.append(probeMetalFromDisplay())
        
        // 6. IOFramebuffer
        results.append(probeIOFramebuffer())
        
        // 7. CGDisplayCreateImage
        results.append(probeCGDisplayCreateImage())
        
        probeResults = results
    }
    
    private func probeScreenCaptureKit() async -> ProbeResult {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayCount = content.displays.count
            return ProbeResult(
                api: "ScreenCaptureKit",
                accessible: true,
                notes: "Available. Found \(displayCount) display(s). Primary capture method. Respects DRM protection."
            )
        } catch {
            return ProbeResult(
                api: "ScreenCaptureKit",
                accessible: false,
                notes: "Error: \(error.localizedDescription)"
            )
        }
    }
    
    private func probeCGDisplayStream() -> ProbeResult {
        guard let mainDisplay = displays.first(where: { $0.isMain }) ?? displays.first else {
            return ProbeResult(api: "CGDisplayStream", accessible: false, notes: "No display available")
        }
        
        var frameReceived = false
        let semaphore = DispatchSemaphore(value: 0)
        
        let properties: [CFString: Any] = [
            CGDisplayStream.preserveAspectRatio: true,
            CGDisplayStream.minimumFrameTime: 1.0/30.0
        ]
        
        if let stream = CGDisplayStream(
            dispatchQueueDisplay: mainDisplay.id,
            outputWidth: 64,
            outputHeight: 36,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties as CFDictionary,
            queue: DispatchQueue.global(qos: .userInteractive),
            handler: { status, timestamp, surface, _ in
                if status == .frameComplete && surface != nil {
                    frameReceived = true
                }
                semaphore.signal()
            }
        ) {
            stream.start()
            _ = semaphore.wait(timeout: .now() + 1.0)
            stream.stop()
            
            return ProbeResult(
                api: "CGDisplayStream",
                accessible: frameReceived,
                notes: frameReceived
                    ? "Available. Legacy API, uses same path as ScreenCaptureKit. Respects DRM."
                    : "Stream created but no frame received. May require Screen Recording permission."
            )
        }
        
        return ProbeResult(
            api: "CGDisplayStream",
            accessible: false,
            notes: "Failed to create stream. Requires Screen Recording permission."
        )
    }
    
    private func probeCGWindowListCreateImage() -> ProbeResult {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        if let image = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, .bestResolution) {
            let width = image.width
            let height = image.height
            return ProbeResult(
                api: "CGWindowListCreateImage",
                accessible: true,
                notes: "Available. Creates \(width)x\(height) image. Uses same path as ScreenCaptureKit. Respects DRM."
            )
        }
        return ProbeResult(
            api: "CGWindowListCreateImage",
            accessible: false,
            notes: "Failed. Requires Screen Recording permission."
        )
    }
    
    private func probeIOSurfaceFromDisplay() -> ProbeResult {
        // IOSurface cannot be obtained from displays through public APIs
        return ProbeResult(
            api: "IOSurface (Display)",
            accessible: false,
            notes: "Not accessible. Display IOSurfaces are managed by WindowServer and not exposed to applications. Protected surfaces use kIOSurfacePurgeWhenNotInUse and aren't readable."
        )
    }
    
    private func probeMetalFromDisplay() -> ProbeResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return ProbeResult(api: "Metal (Display)", accessible: false, notes: "No Metal device available")
        }
        
        // Metal cannot access other applications' textures or the compositor output
        return ProbeResult(
            api: "Metal (Display)",
            accessible: false,
            notes: "Metal cannot access compositor output or other apps' textures. GPU=\(device.name). Metal is for rendering to own surfaces only."
        )
    }
    
    private func probeIOFramebuffer() -> ProbeResult {
        // IOFramebuffer is deprecated on Apple Silicon
        var iter: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOFramebuffer"),
            &iter
        )
        
        if result == KERN_SUCCESS {
            var count = 0
            var service = IOIteratorNext(iter)
            while service != 0 {
                count += 1
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
            
            if count > 0 {
                return ProbeResult(
                    api: "IOFramebuffer",
                    accessible: false,
                    notes: "Found \(count) IOFramebuffer service(s), but direct framebuffer access is not supported on Apple Silicon. The DCP (Display Controller Processor) manages the display pipeline."
                )
            }
        }
        
        return ProbeResult(
            api: "IOFramebuffer",
            accessible: false,
            notes: "No IOFramebuffer services found. Apple Silicon uses DCP coprocessor for display management."
        )
    }
    
    private func probeCGDisplayCreateImage() -> ProbeResult {
        guard let mainDisplay = displays.first(where: { $0.isMain }) ?? displays.first else {
            return ProbeResult(api: "CGDisplayCreateImage", accessible: false, notes: "No display available")
        }
        
        if let image = CGDisplayCreateImage(mainDisplay.id) {
            let width = image.width
            let height = image.height
            return ProbeResult(
                api: "CGDisplayCreateImage",
                accessible: true,
                notes: "Available. Creates \(width)x\(height) screenshot. Single-frame capture, not streaming. Respects DRM protection."
            )
        }
        
        return ProbeResult(
            api: "CGDisplayCreateImage",
            accessible: false,
            notes: "Failed. Requires Screen Recording permission."
        )
    }
    
    // MARK: - Research Summary
    
    /// Get a summary of findings based on probes and research.
    public func getResearchSummary() -> String {
        """
        DISPLAY CAPTURE RESEARCH SUMMARY
        ================================
        
        System: macOS on Apple Silicon
        Displays: \(displays.count) connected
        GPUs: \(gpus.count) available
        
        ACCESSIBLE APIs (all respect DRM):
        • ScreenCaptureKit - Primary method, efficient streaming
        • CGDisplayStream - Legacy, same underlying path
        • CGWindowListCreateImage - Single frame capture
        • CGDisplayCreateImage - Screenshot API
        
        INACCESSIBLE APIs:
        • Direct IOSurface - WindowServer managed, not exposed
        • Metal compositor - Cannot read other apps' textures
        • IOFramebuffer - Deprecated, DCP coprocessor on Apple Silicon
        • GPU overlays - Hardware-protected, not readable
        
        DRM PROTECTION:
        Protected video (Netflix, Prime, etc.) uses:
        • Widevine L1/L3 (Chrome/Firefox/Edge)
        • FairPlay (Safari)
        
        Both systems render to protected IOSurfaces that are
        explicitly excluded from screen capture at the compositor level.
        
        WORKAROUND (Chromium browsers only):
        Disable hardware acceleration to force Widevine L3 (software).
        This allows capture but limits quality to 720p on some services.
        
        Safari FairPlay has no workaround - content is always protected.
        
        CONCLUSION:
        There is no legitimate way to capture DRM-protected pixels through
        any public or private macOS API without circumventing DRM, which
        would be illegal and is explicitly out of scope.
        """
    }
}

#endif
