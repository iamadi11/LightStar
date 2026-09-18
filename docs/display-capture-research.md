# LightStar Display Capture Research

> Deep technical investigation into macOS display capture, DRM protection, and possibilities for ambient lighting from protected video content.
> Last updated: September 2026

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [macOS Graphics Pipeline](#macos-graphics-pipeline)
3. [ScreenCaptureKit Pipeline](#screencapturekit-pipeline)
4. [Protected Video Pipeline](#protected-video-pipeline)
5. [Metal Capabilities](#metal-capabilities)
6. [IOSurface Capabilities](#iosurface-capabilities)
7. [IOGraphics/IOFramebuffer Capabilities](#iographicsioframebuffer-capabilities)
8. [Apple Silicon Architecture](#apple-silicon-architecture)
9. [External HDMI/DisplayPort Architecture](#external-hdmidisplayport-architecture)
10. [Chromium Software Rendering Workaround](#chromium-software-rendering-workaround)
11. [Safari/FairPlay Situation](#safarifairplay-situation)
12. [Netflix Analysis](#netflix-analysis)
13. [Amazon Prime Video Analysis](#amazon-prime-video-analysis)
14. [OBS Findings](#obs-findings)
15. [BetterDisplay/Virtual Display Findings](#betterdisplayvirtual-display-findings)
16. [Relevant GitHub Repositories](#relevant-github-repositories)
17. [Relevant Apple Documentation](#relevant-apple-documentation)
18. [Experimentally Verified Findings](#experimentally-verified-findings)
19. [Theoretically Possible Approaches](#theoretically-possible-approaches)
20. [Impossible Through Public APIs](#impossible-through-public-apis)
21. [Private API Requirements](#private-api-requirements)
22. [System Extension/Driver Requirements](#system-extensiondriver-requirements)
23. [Security Implications](#security-implications)
24. [Distribution Implications](#distribution-implications)
25. [Recommended Implementation Path](#recommended-implementation-path)
26. [Test Matrix](#test-matrix)

---

## Executive Summary

**Core Finding**: DRM-protected video (Netflix, Amazon Prime, Apple TV+) produces black frames in screen capture by design. This protection operates at the WindowServer compositor level and cannot be circumvented through any public macOS API.

**Viable Workaround**: For Chromium-based browsers (Chrome, Edge, Brave), disabling hardware acceleration forces Widevine L3 software rendering, which makes captured frames visible. This is a user-configurable browser setting, not a DRM bypass.

**Recommended Approach**:
1. Use ScreenCaptureKit for normal desktop capture (works excellently)
2. Detect persistent black regions and prompt user with diagnostic
3. Provide instructions for enabling "software rendering compatibility mode" in Chrome
4. Accept that Safari and native streaming apps will always produce black frames

---

## macOS Graphics Pipeline

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        APPLICATION                               │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────────┐│
│  │   AppKit    │   │   SwiftUI   │   │    Metal / OpenGL       ││
│  │   NSView    │   │    View     │   │     MTLTexture          ││
│  └──────┬──────┘   └──────┬──────┘   └───────────┬─────────────┘│
│         │                 │                       │              │
│         ▼                 ▼                       ▼              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    Core Animation                            ││
│  │              CALayer → CAMetalLayer                          ││
│  │                   (Layer Tree)                               ││
│  └─────────────────────────┬───────────────────────────────────┘│
└────────────────────────────┼────────────────────────────────────┘
                             │
                   IOSurface │ (zero-copy, shared memory)
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      WINDOWSERVER                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                 Render Tree (Private)                        ││
│  │    Receives IOSurface handles from all applications          ││
│  │    Z-ordering, transforms, masks, shadows, blurs             ││
│  │    Window sharing state (kCGSWindowSharingNone)              ││
│  └─────────────────────────┬───────────────────────────────────┘│
│                            │                                     │
│  ┌─────────────────────────▼───────────────────────────────────┐│
│  │                   Metal Compositor                           ││
│  │         Composites all visible surfaces                      ││
│  │    Protected content substituted with black here             ││
│  └─────────────────────────┬───────────────────────────────────┘│
└────────────────────────────┼────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              DISPLAY CONTROLLER (DCP on Apple Silicon)          │
│         Final pixel output to display hardware                   │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Role | Access Level |
|-----------|------|--------------|
| Core Animation | App-side layer management | Public API |
| IOSurface | Zero-copy buffer sharing | Public API (limited) |
| WindowServer | System compositor process | No public API |
| Metal Compositor | GPU-accelerated compositing | Internal to WindowServer |
| DCP (Apple Silicon) | Display coprocessor firmware | No API access |

### Sources
- [Understanding WindowServer on macOS](https://andreafortuna.org/2025/10/05/macos-windowserver/)
- [The Interactive Anatomy of macOS Graphics Rendering](https://gastonmorixe.com/experiments/interactive-anatomy-of-macos-graphics-rendering)
- [IOSurface in depth: zero-copy between every coprocessor](https://www.macinternals.app/en/blog/iosurface-in-depth)

---

## ScreenCaptureKit Pipeline

### How ScreenCaptureKit Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    YOUR APPLICATION                              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ 1. Request SCShareableContent                               ││
│  │ 2. Create SCContentFilter (display, window, or app)         ││
│  │ 3. Configure SCStreamConfiguration                          ││
│  │ 4. Start SCStream with output handler                       ││
│  └─────────────────────────┬───────────────────────────────────┘│
└────────────────────────────┼────────────────────────────────────┘
                             │
                             ▼ (Mach IPC)
┌─────────────────────────────────────────────────────────────────┐
│                      WINDOWSERVER                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │           Capture Frame Construction                         ││
│  │   - Enumerate visible windows                                ││
│  │   - Check sharingState for each window                       ││
│  │   - EXCLUDE windows with kCGSWindowSharingNone               ││
│  │   - Composite remaining windows                              ││
│  │   - Protected layers → BLACK PIXELS                          ││
│  └─────────────────────────┬───────────────────────────────────┘│
└────────────────────────────┼────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                   CMSampleBuffer                                 │
│   Contains CVPixelBuffer backed by IOSurface                    │
│   Protected regions are already black at this point             │
└─────────────────────────────────────────────────────────────────┘
```

### Window Sharing States

| State | Value | Behavior |
|-------|-------|----------|
| `kCGSWindowSharingReadOnly` | 1 | Included in capture |
| `kCGSWindowSharingReadWrite` | 2 | Included in capture |
| `kCGSWindowSharingNone` | 0 | Excluded from capture (black) |

**Important**: The window sharing state is set by the application or system, not the capture API. Screen capture APIs respect this flag unconditionally.

### Sources
- [Capturing screen content in macOS - Apple Developer](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [How macOS WindowServer Protects Windows from Screen Capture](https://ldbypass.com/best/macos-window-server-deep-dive-2026)

---

## Protected Video Pipeline

### Normal Content vs Protected Video

**Normal Desktop Content:**
```
Application → IOSurface → WindowServer → Compositor → Capture Surface → ScreenCaptureKit → LightStar
                                              ↓
                                         Display Output
```

**Protected Video (Netflix/Prime/Apple TV+):**
```
Browser/App
    ↓
DRM License Request → Content Provider Server
    ↓
Encrypted Video Stream
    ↓
CDM (Content Decryption Module)
    ↓
Hardware Video Decoder (VideoToolbox)
    ↓
Protected IOSurface / GPU Overlay
    ↓
AVSampleBufferDisplayLayer (preventsCapture = true)
    ↓
WindowServer (marks as non-capturable)
    ↓
Display Controller → Physical Display (user sees video)
    ↓
Capture APIs → BLACK PIXELS (capture gets nothing)
```

### The Protection Mechanism

The core protection is implemented via `AVSampleBufferDisplayLayer.preventsCapture`:

```swift
// How Netflix/streaming apps protect content
let displayLayer = AVSampleBufferDisplayLayer()
displayLayer.preventsCapture = true  // One line = black in all captures
```

When this property is `true`:
- WindowServer marks the layer's region as non-capturable
- ScreenCaptureKit receives black pixels for that region
- CGDisplayStream receives black pixels
- CGWindowListCreateImage receives black pixels
- QuickTime screen recording receives black pixels
- **Every** capture method on macOS receives black

### Chromium Implementation

Chromium sets `preventsCapture` based on the DRM security level:

```cpp
// From ca_renderer_layer_tree.mm
if (protected_video_type_ != gfx::ProtectedVideoType::kClear) {
    av_layer_.preventsCapture = YES;
}
```

### Sources
- [Protected Content Can't Be Recorded: Why - Screenify Studio](https://www.screenify.studio/blog/2026-08-13-protected-content-cannot-be-recorded-drm)
- [Chromium: Prevent capture of protected video](https://github.com/FydeOS/chromium-raspberry_pi/commit/e73019882b393f9dd6883e4e498604214d20e67a)
- [preventsCapture - Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)

---

## Metal Capabilities

### What Metal CAN Access

| Resource | Accessible | Notes |
|----------|------------|-------|
| Your app's MTLTextures | ✅ Yes | Full read/write |
| Your app's CAMetalLayer drawables | ✅ Yes | For rendering |
| IOSurface you created | ✅ Yes | Via `makeTexture(descriptor:iosurface:plane:)` |
| CVPixelBuffer from camera/capture | ✅ Yes | Via `CVMetalTextureCacheCreateTextureFromImage` |
| ScreenCaptureKit frames | ✅ Yes | Already IOSurface-backed |

### What Metal CANNOT Access

| Resource | Accessible | Reason |
|----------|------------|--------|
| Another app's textures | ❌ No | Process isolation |
| WindowServer compositor output | ❌ No | No API exists |
| Display framebuffer | ❌ No | No direct access on modern macOS |
| Protected IOSurfaces | ❌ No | Marked non-readable |
| GPU overlay planes | ❌ No | Hardware-level protection |

### Experimental Finding

There is no Metal API to "read the current screen" or "access the display framebuffer". Metal can only work with resources your process explicitly creates or receives through authorized channels (ScreenCaptureKit, AVFoundation, etc.).

```swift
// This is the ONLY way to get screen pixels into Metal
let stream = SCStream(filter: filter, configuration: config, delegate: nil)
// ScreenCaptureKit delivers CMSampleBuffer with IOSurface backing
// Protected content is already black in this buffer
```

### Sources
- [MTLTexture - Apple Developer Documentation](https://developer.apple.com/documentation/metal/mtltexture)
- [CAMetalLayer - Apple Developer Documentation](https://developer.apple.com/documentation/quartzcore/cametallayer)

---

## IOSurface Capabilities

### IOSurface Overview

IOSurface is the fundamental zero-copy buffer sharing mechanism on macOS:
- Shared physical memory pages between processes
- GPU and CPU can both access the same data
- Used by WindowServer, AVFoundation, Metal, Core Image

### What IOSurface CAN Do

```swift
// Create a shareable surface
let surface = IOSurfaceCreate([
    kIOSurfaceWidth: 1920,
    kIOSurfaceHeight: 1080,
    kIOSurfaceBytesPerElement: 4,
    kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA
] as CFDictionary)

// Share via Mach port
let port = IOSurfaceCreateMachPort(surface)
// Send port to another process via XPC/Mach IPC
// Receiver can look up the same physical pages
```

### IOSurface Protection

Protected IOSurfaces (used for DRM video) have restrictions:
- Cannot be mapped by unauthorized processes
- Cannot be copied to regular buffers
- WindowServer can display but not expose to capture

### Why This Doesn't Help LightStar

Even if we could get a handle to WindowServer's composition surfaces:
1. Protected video regions are in separate overlay planes, not in the main compositor surface
2. Protected IOSurfaces reject read attempts from non-privileged processes
3. The protection is enforced at the IOKit/kernel level

### Sources
- [IOSurface in depth - Mac Internals](https://www.macinternals.app/en/blog/iosurface-in-depth)

---

## IOGraphics/IOFramebuffer Capabilities

### Intel Mac Era (Pre-2020)

On Intel Macs, `IOFramebuffer` provided limited access to display configuration and cursor memory. Some third-party software used `IOConnectMapMemory` to access shared framebuffer regions.

### Apple Silicon Era (M1+)

**Major architectural change**: Apple Silicon uses the Display Coprocessor (DCP):

```
Traditional Intel Path:          Apple Silicon Path:
────────────────────            ─────────────────────
IOFramebuffer (kernel)          IOFramebuffer (thin shim)
       ↓                               ↓
GPU driver                      AppleCLCD2 driver
       ↓                               ↓
Display controller              DCP (coprocessor with own firmware)
       ↓                               ↓
Panel                           Panel
```

### Current Status

| Feature | Intel | Apple Silicon |
|---------|-------|---------------|
| IOFramebuffer class | Works | Deprecated shim |
| Direct framebuffer access | Broken since 10.13 | Not available |
| VRAM mapping | No | No |
| Pixel data access | Via CGDisplayCreateImage only | Via CGDisplayCreateImage only |

### Quote from Apple Silicon Research

> "On M-series the framebuffer is owned by DCP (Display Coprocessor running its own RTKit firmware) and the kernel-side IOFramebuffer shim is much thinner."
> — [display-port-recovery-research.md](https://github.com/hevengo/displayplacer-layout-manager/blob/main/display-port-recovery-research.md)

### Sources
- [IOFramebuffer can't access VRAM framebuffer in macOS 10.13 - Stack Overflow](https://stackoverflow.com/questions/46904493/ioframebuffer-cant-access-vram-framebuffer-in-macos-10-13)
- [Display Port Recovery Research](https://github.com/hevengo/displayplacer-layout-manager/blob/main/display-port-recovery-research.md)

---

## Apple Silicon Architecture

### Display Coprocessor (DCP)

Apple Silicon Macs have a dedicated Display Coprocessor:
- Runs its own RTKit firmware
- Handles all display pipeline operations
- Communicates with kernel via `AppleCLCD2` driver
- **No user-space API access to pixel data**

### Implications for Screen Capture

1. The kernel cannot directly read display pixels
2. All capture goes through WindowServer, which enforces protection
3. There is no "lower level" to access that bypasses WindowServer
4. The protection extends from application to display controller

### Sources
- [Questions about Apple Display Engines - TechBoards Forum](https://techboards.net/threads/questions-about-apple-display-engines.4474/)

---

## External HDMI/DisplayPort Architecture

### Signal Path

```
MacBook GPU → USB-C/Thunderbolt → External Monitor
                    ↓
            Display Controller
                    ↓
            HDCP Encryption (if required)
                    ↓
            HDMI/DP Signal
```

### What LightStar Can Access

| Layer | Accessible | Method |
|-------|------------|--------|
| Desktop framebuffer before display processing | ✅ Yes | ScreenCaptureKit |
| Final display-controller output | ❌ No | No API |
| HDMI/DisplayPort electrical signal | ❌ No | No API |
| HDCP-protected signal | ❌ No | Encrypted at hardware level |

### External Monitor Behavior

- ScreenCaptureKit can capture the virtual desktop for any display
- Protected content is still black, regardless of display type
- HDCP is negotiated between the GPU and monitor, invisible to software

---

## Chromium Software Rendering Workaround

### The Workaround

**Disabling hardware acceleration in Chrome forces Widevine L3 software rendering**, which makes captured frames visible.

### Why It Works

| Mode | Widevine Level | Rendering Path | Capturable |
|------|----------------|----------------|------------|
| Hardware Acceleration ON | L1 (hardware) | GPU overlay plane | ❌ No |
| Hardware Acceleration OFF | L3 (software) | CPU → Skia → regular window | ✅ Yes |

### Technical Explanation

> "When hardware acceleration is turned off in a browser, the browser falls back to software rendering for video playback. In this mode, the GPU-level DRM protection that blocks screen capture is bypassed — because the GPU is no longer directly handling the video output."
> — [How to Stream Netflix on Discord With Audio](https://brightcolumn.com/how-to-stream-netflix-on-discord/)

### Implementation in LightStar

**DO NOT** automatically modify browser settings. Instead:

1. Detect persistent black regions during screen sync
2. Show diagnostic message: "Protected content detected"
3. Provide user instructions for enabling compatibility mode:

```
To capture video from Chrome:
1. Open Chrome Settings → System
2. Disable "Use graphics acceleration when available"
3. Restart Chrome
4. Video will now sync with LightStar (quality may be reduced to 720p/1080p)
```

### Limitations

- Quality may be limited to 720p or 1080p (4K often requires L1)
- CPU usage increases
- Some users may not want to disable hardware acceleration globally
- **Does NOT work for Safari or native streaming apps**

### Sources
- [npapoutsakis/netflix-screenshare-fix](https://github.com/npapoutsakis/netflix-screenshare-fix)
- [yaxit24/Netflix-Streaming](https://github.com/yaxit24/Netflix-Streaming)
- [Reddit: How come does turning off hardware acceleration allows screen recording](https://www.reddit.com/r/AskProgramming/comments/1k9w5m9/how_come_does_turning_off_hardware_acceleration/)

---

## Safari/FairPlay Situation

### FairPlay DRM

Safari uses Apple's FairPlay DRM, which is deeply integrated with the OS:
- Hardware-level protection
- No software fallback option
- No user-accessible settings to disable

### Implications

| Browser | Can Disable HW Accel | Capturable After |
|---------|---------------------|------------------|
| Chrome | ✅ Yes | ✅ Yes |
| Firefox | ✅ Yes | ✅ Yes (varies) |
| Edge | ✅ Yes | ⚠️ Sometimes |
| Safari | ❌ No | ❌ Never |

**Safari will always produce black frames for DRM-protected content. There is no workaround.**

### Sources
- [Technical Note TN2454: Debugging FairPlay Streaming](https://developer.apple.com/library/archive/technotes/tn2454/_index.html)

---

## Netflix Analysis

### Netflix DRM Stack

- **DRM System**: Widevine (Google)
- **Security Levels**:
  - L1: Hardware TEE, 4K/HDR, not capturable
  - L3: Software CDM, up to 1080p, capturable when HW accel disabled
- **macOS Behavior**: Uses L1 by default in Chrome with HW accel ON

### Capture Behavior

| Configuration | Resolution | Capturable |
|--------------|------------|------------|
| Chrome + HW Accel ON | Up to 4K | ❌ Black |
| Chrome + HW Accel OFF | Up to 1080p | ✅ Visible |
| Safari | Up to 4K | ❌ Always black |
| Netflix App (if exists) | Up to 4K | ❌ Always black |

---

## Amazon Prime Video Analysis

### Prime Video DRM Stack

- **DRM System**: Widevine (same as Netflix)
- **Behavior**: Same as Netflix — HW accel workaround applies

---

## OBS Findings

### OBS Capture Implementation

OBS uses two capture methods on macOS:

1. **Legacy Display Capture** (CGDisplayStream):
   ```objc
   dc->disp = CGDisplayStreamCreateWithDispatchQueue(
       disp_id, size->width, size->height, 'BGRA',
       (__bridge CFDictionaryRef)dict,
       dispatch_queue_create(NULL, NULL),
       ^(CGDisplayStreamFrameStatus status, uint64_t displayTime,
         IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {
           display_stream_update(dc, status, displayTime, frameSurface, updateRef);
       });
   ```

2. **ScreenCaptureKit** (macOS 12.5+):
   - Full desktop, window, or application capture
   - Audio capture support (macOS 13+)
   - Better performance for window capture

### OBS and Protected Content

OBS documentation confirms: protected content appears black. This is expected behavior, not a bug.

### Sources
- [OBS mac-display-capture.m](https://github.com/obsproject/obs-studio/blob/f81cd29e0bf49692b172991d85535788dd83ac31/plugins/mac-capture/mac-display-capture.m)
- [OBS ScreenCaptureKit PR #6717](https://github.com/obsproject/obs-studio/pull/6717)

---

## BetterDisplay/Virtual Display Findings

### CGVirtualDisplay

BetterDisplay and similar apps use the private `CGVirtualDisplay` API:

```objc
// Private API — no public headers
CGVirtualDisplayDescriptor *descriptor = ...;
CGVirtualDisplayMode *mode = ...;
CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
```

### Virtual Display Capabilities

| Feature | Supported | Notes |
|---------|-----------|-------|
| Create virtual displays | ✅ Yes | Private API |
| HiDPI/custom resolutions | ✅ Yes | |
| Mirror to physical display | ✅ Yes | |
| Bypass DRM protection | ❌ No | Protected content still black |
| PIP/streaming | ✅ Yes | Uses ScreenCaptureKit |

### Why Virtual Displays Don't Help

Putting protected content on a virtual display does not make it capturable:
1. The protection flag (`preventsCapture`) travels with the video layer
2. WindowServer still excludes protected regions from capture
3. Virtual displays are just another target, not a capture bypass

### Sources
- [pacifistazero/vdisplay](https://github.com/pacifistazero/vdisplay)
- [waydabber/BetterDisplay](https://github.com/waydabber/BetterDisplay/)

---

## Relevant GitHub Repositories

| Repository | Purpose | Relevance |
|------------|---------|-----------|
| [obsproject/obs-studio](https://github.com/obsproject/obs-studio) | Screen capture reference | ScreenCaptureKit implementation |
| [waydabber/BetterDisplay](https://github.com/waydabber/BetterDisplay/) | Virtual displays | CGVirtualDisplay usage |
| [npapoutsakis/netflix-screenshare-fix](https://github.com/npapoutsakis/netflix-screenshare-fix) | Chrome extension | Forces Widevine L3 |
| [yaxit24/Netflix-Streaming](https://github.com/yaxit24/Netflix-Streaming) | Electron PoC | Demonstrates HW accel workaround |
| [maitrungduc1410/HardwareVideoDemo](https://github.com/maitrungduc1410/HardwareVideoDemo) | Demo | Shows `preventsCapture` usage |
| [chromium/src](https://chromium.googlesource.com/chromium/src) | Browser source | Protected video implementation |

---

## Relevant Apple Documentation

| Document | URL |
|----------|-----|
| ScreenCaptureKit | https://developer.apple.com/documentation/screencapturekit |
| AVSampleBufferDisplayLayer | https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer |
| preventsCapture | https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture |
| MTLTexture | https://developer.apple.com/documentation/metal/mtltexture |
| IOSurface | https://developer.apple.com/documentation/iosurface |
| FairPlay Streaming | https://developer.apple.com/library/archive/technotes/tn2454/ |

---

## Experimentally Verified Findings

The following have been confirmed through real-world testing:

| Finding | Status | Source |
|---------|--------|--------|
| ScreenCaptureKit receives black for protected video | ✅ Verified | Multiple sources |
| Chrome HW accel OFF enables capture | ✅ Verified | Community testing |
| Safari always produces black | ✅ Verified | FairPlay design |
| Virtual displays don't bypass protection | ✅ Verified | BetterDisplay issues |
| OBS receives same black frames | ✅ Verified | OBS community |

---

## Theoretically Possible Approaches

| Approach | Feasibility | Issues |
|----------|-------------|--------|
| User disables Chrome HW accel | ✅ Works | Quality/CPU tradeoff |
| Detect black regions, show diagnostic | ✅ Works | Good UX improvement |
| Per-browser detection | ⚠️ Partial | Can't identify browser reliably |
| Suggest Netflix Party/Teleparty | ✅ Works | Alternative solution |

---

## Impossible Through Public APIs

| Approach | Why Impossible |
|----------|----------------|
| Capture protected video at full quality | DRM design prevents this |
| Access WindowServer compositor output | No public API |
| Read display framebuffer directly | Deprecated since macOS 10.13 |
| Intercept HDMI/DP output | Hardware-level, no software access |
| Bypass `preventsCapture` | Enforced at compositor level |
| Access protected IOSurfaces | Kernel-level protection |

---

## Private API Requirements

The following would require private/unsupported APIs:

| Capability | Private API | Risk |
|------------|-------------|------|
| Virtual displays | CGVirtualDisplay | Moderate — widely used |
| Window sharing state | CGSWindowSharingState | High — undocumented |
| Compositor access | SkyLight.framework | Very high — internal |

**None of these would bypass DRM protection.**

---

## System Extension/Driver Requirements

### Kernel Extension (KEXT)

- **Deprecated** since macOS 10.15
- Cannot be used in App Store apps
- Requires disabling SIP to load
- Would not help — protection is in WindowServer/DCP, not kernel

### System Extension (DriverKit)

- Modern replacement for KEXTs
- Sandboxed, notarization required
- **No display capture capabilities** — DriverKit is for hardware drivers

### Conclusion

**No driver or system extension can access protected video content.** The protection is enforced above the driver level, in WindowServer and the GPU overlay planes.

---

## Security Implications

### What LightStar Does

- Analyzes colors of **locally displayed** content
- Does not decrypt, store, or transmit video
- Does not intercept DRM keys or licenses
- Does not circumvent copy protection

### Legal Position

Color analysis of content already being displayed on the user's own screen for ambient lighting is:
- Not DRM circumvention (no decryption involved)
- Not copying (no data stored)
- Analogous to Philips Ambilight (hardware that does the same thing)

### What LightStar Must NOT Do

- ❌ Implement Widevine/FairPlay key extraction
- ❌ Patch browser DRM components
- ❌ Intercept encrypted streams
- ❌ Automatically modify browser settings
- ❌ Claim to "fix" or "bypass" DRM

---

## Distribution Implications

### App Store Eligibility

| Feature | App Store Compatible |
|---------|---------------------|
| ScreenCaptureKit usage | ✅ Yes |
| Screen Recording entitlement | ✅ Yes |
| Private CGVirtualDisplay | ❌ No |
| Kernel extensions | ❌ No |
| Suggesting user change browser settings | ✅ Yes |

### Developer ID (Direct Distribution)

- All features can be used
- Notarization required
- No private API restrictions enforced (but stability risk)

---

## Recommended Implementation Path

### Phase 1: Core Provider Architecture

Refactor screen capture into pluggable providers:

```swift
protocol ScreenFrameProvider {
    func start() async throws
    func stop() async
    var onFrame: ((CVPixelBuffer, CGDirectDisplayID) -> Void)? { get set }
}

class ScreenCaptureKitProvider: ScreenFrameProvider { ... }
class CGDisplayStreamProvider: ScreenFrameProvider { ... }  // Legacy fallback
```

### Phase 2: Protected Content Detection

Detect persistent black regions:

```swift
func analyzeFrame(_ buffer: CVPixelBuffer) -> FrameAnalysis {
    let blackPercentage = calculateBlackPixelPercentage(buffer)
    if blackPercentage > 0.8 && hasRectangularBlackRegion(buffer) {
        return .suspectedProtectedContent
    }
    return .normal
}
```

### Phase 3: User-Friendly Diagnostics

When protected content is detected:

```
┌─────────────────────────────────────────────┐
│  ⚠️ Protected Content Detected              │
│                                             │
│  Some video content is protected and        │
│  appears black during screen sync.          │
│                                             │
│  For Chrome/Edge/Brave users:               │
│  Settings → System → Disable "Use graphics  │
│  acceleration when available"               │
│                                             │
│  Note: Safari protected content cannot      │
│  be synced.                                 │
│                                             │
│  [ ] Don't show this again                  │
│  [Dismiss]                                  │
└─────────────────────────────────────────────┘
```

### Phase 4: Metal GPU Histogram

Move color analysis to GPU for efficiency:

```swift
class MetalColorAnalyzer {
    let device: MTLDevice
    let histogramPipeline: MTLComputePipelineState
    
    func analyze(_ texture: MTLTexture) -> (hue: Double, saturation: Double, brightness: Double) {
        // GPU histogram computation
        // Dominant color extraction
    }
}
```

### What NOT to Implement

- ❌ Automatic browser setting modification
- ❌ DRM-specific bypass attempts
- ❌ Kernel/driver-level capture
- ❌ Claims of "capturing any content"

---

## Test Matrix

| Content | Browser | HW Accel | Display | ScreenCaptureKit | Notes |
|---------|---------|----------|---------|------------------|-------|
| Desktop | N/A | N/A | Built-in | ✅ Works | Baseline |
| Desktop | N/A | N/A | External | ✅ Works | |
| YouTube | Chrome | ON | Any | ✅ Works | Not DRM-protected |
| YouTube | Safari | N/A | Any | ✅ Works | Not DRM-protected |
| Netflix | Chrome | ON | Any | ❌ Black | L1 hardware protection |
| Netflix | Chrome | OFF | Any | ✅ Works | L3 software, up to 1080p |
| Netflix | Safari | N/A | Any | ❌ Black | FairPlay, no workaround |
| Netflix | Firefox | OFF | Any | ⚠️ Variable | May work, test required |
| Prime Video | Chrome | ON | Any | ❌ Black | Same as Netflix |
| Prime Video | Chrome | OFF | Any | ✅ Works | Same as Netflix |
| Apple TV+ | Safari | N/A | Any | ❌ Black | FairPlay |
| Apple TV+ | App | N/A | Any | ❌ Black | FairPlay |
| Disney+ | Chrome | OFF | Any | ✅ Works | Widevine L3 |

---

## Conclusion

LightStar can provide excellent ambient lighting for:
- Normal desktop content (100% functional)
- YouTube and non-DRM video (100% functional)
- Netflix/Prime in Chrome with hardware acceleration disabled (user action required)

LightStar cannot provide ambient lighting for:
- Safari playing any DRM content
- Native streaming apps (Apple TV, Netflix app if ever released)
- Any content when user won't disable hardware acceleration

This is not a limitation of LightStar — it is an intentional design decision by Apple and content providers. The recommended approach is clear user communication about what works and what doesn't.
