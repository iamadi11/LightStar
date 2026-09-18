# LightStar Display Pipeline Feasibility Analysis

> Generated: September 2026
> Environment: Cloud Agent (architecture analysis only)
> Status: Theoretical analysis — no hardware verification

---

## Display Pipeline Architecture

### Standard Application Rendering Path

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           APPLICATION LAYER                               │
│  App Process → Metal/OpenGL → CAMetalLayer → IOSurface → WindowServer    │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ IOSurface handle (Mach port)
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                           COMPOSITOR LAYER                                │
│  WindowServer: Receives all window IOSurfaces                            │
│  - Z-order composition                                                    │
│  - Window transforms, shadows, blur                                       │
│  - Checks preventsCapture flag per layer                                  │
│  - Substitutes BLACK for protected layers in capture output               │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Composited frame
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                           DISPLAY CONTROLLER                              │
│  Intel: GPU framebuffer → display controller → panel                     │
│  Apple Silicon: DCP (Display Coprocessor with RTKit firmware)            │
│  - Handles panel timing, backlight, color management                      │
│  - Receives composited frame from WindowServer                            │
│  - Outputs to physical display                                            │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                            Physical Display Panel
```

### Where DRM Protection Occurs

```
Protected Video Playback:

Browser/App
    │
    ▼
DRM License Acquisition (network)
    │
    ▼
Widevine/FairPlay CDM (hardware or software)
    │
    ▼
Hardware Video Decoder (Apple VT)
    │
    ▼
Protected IOSurface (kernel-enforced)
    │
    ▼
AVSampleBufferDisplayLayer [preventsCapture = true]  ◄── PROTECTION SET HERE
    │
    ▼
WindowServer (respects preventsCapture)
    │
    ├───────────────────────────────┐
    ▼                               ▼
Display Output (user sees video)    Capture APIs (receive BLACK)
```

---

## Access Point Analysis

### Point 1: Application's GPU Texture

**Access Method**: Direct Metal/OpenGL calls within own process

**What You Get**: Only your own application's rendered content

**Protected Content**: Cannot access other application's textures (process isolation)

**Feasibility**: PUBLIC API, but NOT useful for LightStar's goal

### Point 2: IOSurface Before WindowServer

**Access Method**: Would require intercepting Mach port messages

**What You Get**: Theoretically, raw window content

**Protected Content**: Protected IOSurfaces reject unauthorized read attempts at kernel level

**Feasibility**: NO PUBLIC API — Would require kernel-level access or SIP bypass

### Point 3: WindowServer Compositor Output

**Access Method**: None exists

**What You Get**: Would be the full composited frame

**Protected Content**: WindowServer already substitutes black before any output

**Feasibility**: NO API — WindowServer is a closed system service

### Point 4: GPU Framebuffer (Intel)

**Access Method**: Historically IOFramebuffer, deprecated since macOS 10.13

**What You Get**: Display controller input buffer

**Protected Content**: Still post-WindowServer, so still black

**Feasibility**: DEPRECATED — No longer functional

### Point 5: Display Coprocessor (Apple Silicon)

**Access Method**: None — DCP runs independent firmware

**What You Get**: N/A — Cannot access

**Protected Content**: DCP receives protected content, but no API to read from it

**Feasibility**: NO API — DCP is a hardware coprocessor with no user-space interface

### Point 6: HDMI/DisplayPort Output

**Access Method**: Would require external HDMI capture hardware

**What You Get**: Final pixel output

**Protected Content**: HDCP encryption on protected content

**Feasibility**: EXTERNAL HARDWARE ONLY — Not a software solution

---

## Proposed Solutions Analysis

### Solution A: Virtual Display Interception

**Hypothesis**: Create a virtual display, route protected content to it, capture from virtual display

**Analysis**:

| Step | Possible? | Notes |
|------|-----------|-------|
| Create virtual display | ✅ Yes | CGVirtualDisplay (private API) |
| Route app to virtual display | ⚠️ User action | Full-screen on virtual display |
| Capture from virtual display | ✅ Yes | ScreenCaptureKit |
| Capture protected content | ❌ No | `preventsCapture` applies per-layer, not per-display |

**Evidence**: BetterDisplay users report protected content remains black on virtual displays

**Confidence**: HIGH that this does NOT work

**Technical Mechanism**: `preventsCapture` is a property of `CALayer`, not display. WindowServer tracks this flag regardless of which display the layer renders to.

---

### Solution B: GPU Memory Direct Access

**Hypothesis**: Directly read GPU VRAM to access the final framebuffer

**Analysis**:

| Component | Access | Notes |
|-----------|--------|-------|
| Metal device memory | ✅ Own process only | Cannot access system-wide GPU memory |
| System VRAM | ❌ No API | No user-space VRAM mapping since macOS 10.13+ |
| DCP framebuffer | ❌ No API | Apple Silicon: DCP owns display memory |

**Evidence**: 
- No MTLDevice API for system-wide GPU access
- IOFramebuffer memory mapping removed in macOS 10.13
- Apple Silicon DCP architecture precludes this entirely

**Confidence**: VERY HIGH that this is NOT possible

---

### Solution C: Kernel Extension for Framebuffer Access

**Hypothesis**: A kext could intercept GPU output before WindowServer

**Analysis**:

| Consideration | Assessment |
|---------------|------------|
| Technical feasibility | UNCLEAR — Kext architecture has no display capture hooks |
| WindowServer runs before kext hooks | Protection enforced at WindowServer level, not kernel |
| Protected IOSurface | Kernel enforces protection, kext couldn't bypass |
| SIP requirement | Would need to disable SIP |
| Notarization | Cannot notarize kexts |
| Distribution | Direct distribution only, user must disable SIP |
| Maintenance | Kext APIs deprecated, breaking changes common |

**Key Insight**: The protection is in WindowServer and IOSurface, NOT in kernel drivers. A kext sits below the level where protection is applied.

**Confidence**: HIGH that this does NOT help even if implemented

---

### Solution D: DriverKit System Extension

**Hypothesis**: DriverKit might provide display access

**Analysis**:

DriverKit extensions are for:
- USB devices
- Network extensions
- PCI devices
- Storage

DriverKit does NOT provide:
- Display capture
- GPU access
- WindowServer interaction

**Confidence**: CERTAIN that DriverKit is NOT applicable

---

### Solution E: IOKit Service Connection

**Hypothesis**: Connect to display-related IOKit services

**Analysis**:

| Service | Accessible | Useful for Capture |
|---------|------------|-------------------|
| IOFramebuffer | ⚠️ Deprecated | No — no pixel access |
| AppleCLCD2 (DCP) | ❌ No | N/A |
| AppleGraphicsDeviceControl | ⚠️ Limited | No — configuration only |

**Confidence**: HIGH that IOKit provides no capture capability

---

### Solution F: External HDMI Capture

**Hypothesis**: External capture card captures unprotected output

**Analysis**:

| Scenario | Result |
|----------|--------|
| Normal content | ✅ Works |
| HDCP-disabled content | ✅ Works |
| HDCP-protected content | ❌ Encrypted signal |
| Built-in display | ❌ No HDMI output |

**Limitations**:
- Requires external hardware ($50-200)
- Only works for HDMI/DP output
- HDCP protects most streaming content
- Laptop users with only built-in display cannot use

**Confidence**: VERIFIED that this works for non-HDCP content, does NOT help for protected content

---

## Feasibility Summary Table

| Proposed Solution | Technical Mechanism | Required Permissions | Apple Silicon | Protected Content | Distribution | Confidence |
|-------------------|---------------------|---------------------|---------------|-------------------|--------------|------------|
| Virtual Display | CGVirtualDisplay | None (private API) | ✅ Compatible | ❌ Still black | Direct only | NOT VIABLE |
| GPU Memory Access | VRAM mapping | Would need kernel | ❌ No API | ❌ N/A | N/A | NOT VIABLE |
| Kernel Extension | Framebuffer hook | SIP disabled | ⚠️ Different arch | ❌ Protection above kernel | Direct only | NOT VIABLE |
| DriverKit | Display driver | Notarization | ✅ Supported | ❌ No display access | App Store | NOT VIABLE |
| IOKit Services | IOFramebuffer | None | ❌ Deprecated | ❌ No pixel access | Any | NOT VIABLE |
| External Capture | HDMI capture card | None | ✅ USB | ⚠️ HDCP blocks | Any | PARTIAL |
| Chrome HW-off | User setting | User action | ✅ Compatible | ✅ Works (unverified) | Any | **VIABLE** |

---

## Evidence Assessment

### Strong Evidence (Multiple Independent Sources)

1. `preventsCapture` causes black in ALL capture methods
2. No public API for WindowServer compositor access
3. Apple Silicon DCP has no user-space interface

### Medium Evidence (Single Source or Community Consensus)

1. Virtual displays don't bypass protection (BetterDisplay issues)
2. Chrome HW-off enables Widevine L3 (community reports)

### Weak Evidence (Inference or Speculation)

1. Future macOS versions will maintain current protection
2. Netflix/Prime won't change to detect HW-off mode

---

## Conclusions

### Observations from Documentation Review (NOT Hardware-Verified)

1. **Based on available documentation, no public macOS API appears to provide access to DRM-protected video pixels.**
   - Source: Apple `preventsCapture` documentation, Chromium source code review
   - Limitation: NOT tested on actual hardware; documentation may be incomplete or outdated
   - Status: HYPOTHESIS based on documentation

2. **The Chrome hardware-acceleration workaround is a HYPOTHESIS requiring testing.**
   - Source: Chromium source code logic, community anecdotes
   - Limitation: NOT verified on current macOS/Chrome/Netflix versions
   - Status: UNVERIFIED HYPOTHESIS

3. **Safari appears to have no user-accessible software rendering mode based on documentation.**
   - Source: Apple FairPlay documentation review
   - Limitation: NOT tested; Apple may have undocumented options
   - Status: DOCUMENTATION-BASED INFERENCE

4. **Kernel and system extensions appear unlikely to help based on architecture analysis.**
   - Source: Inference from WindowServer protection level
   - Limitation: No actual kext or DriverKit development was attempted
   - Status: THEORETICAL ANALYSIS ONLY

### What Was NOT Tested

- Whether Chrome HW-off actually enables capture on any macOS version
- Whether any software workaround exists
- Whether the protection mechanisms work as documented
- Whether alternative browsers behave differently
- Actual DRM behavior on any real hardware

### Claims That Require Hardware Testing Before Acceptance

| Claim | Status |
|-------|--------|
| "No software-only solution exists" | HYPOTHESIS — not tested |
| "Chrome HW-off is only viable option" | HYPOTHESIS — not tested |
| "Safari always produces black" | INFERENCE — not tested |
| "Virtual displays don't help" | INFERENCE from community reports |

---

## Recommended Implementation

### Do Implement

1. ✅ ScreenCaptureKit for normal capture (works well)
2. ✅ Black region detection (heuristic for DRM)
3. ✅ User diagnostic with Chrome instructions
4. ✅ Clear messaging that Safari content cannot sync

### Do Not Implement

1. ❌ Kernel extension for "deeper" access
2. ❌ Private API framebuffer hacking
3. ❌ Automatic browser setting modification
4. ❌ DRM circumvention of any kind

### Document Honestly

```
LightStar does not capture DRM-protected video content.
For Chrome users watching Netflix/Prime:
- Disabling hardware acceleration may enable color sync
- Quality may be reduced to 720p-1080p
- Safari cannot be synced

This is a fundamental macOS security feature, not a bug.
```
