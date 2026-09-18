# LightStar DRM Research Audit

> Generated: September 2026
> Environment: Cloud Agent (no hardware testing possible)
> Status: AUDIT of claims in `docs/display-capture-research.md`

---

## Audit Methodology

Each significant claim is:
1. Identified with source (if cited)
2. Source credibility assessed
3. Verified against independent sources
4. Labeled with verification status

### Verification Labels

| Label | Meaning |
|-------|---------|
| VERIFIED | Claim supported by primary sources (Apple docs, official repos) |
| PARTIALLY_VERIFIED | Claim supported by credible secondary sources |
| UNVERIFIED | Claim plausible but no independent confirmation found |
| OUTDATED | Claim may have been true but macOS/browser changes may invalidate |
| SPECULATIVE | Claim based on inference, not documented behavior |
| UNSUPPORTED | Claim contradicts known documentation |

---

## Critical Claims Audit

### Claim 1: "Chrome hardware acceleration OFF allows Netflix/Prime capture"

**Document Citation**:
> "Disabling hardware acceleration in Chrome forces Widevine L3 software rendering, which makes captured frames visible."

**Cited Sources**:
- npapoutsakis/netflix-screenshare-fix (GitHub)
- yaxit24/Netflix-Streaming (GitHub)
- Reddit thread on hardware acceleration

**Audit**:

| Source | Type | Credibility | Assessment |
|--------|------|-------------|------------|
| npapoutsakis/netflix-screenshare-fix | GitHub repo | Community | Describes Chrome extension, doesn't prove claim |
| yaxit24/Netflix-Streaming | GitHub repo | Community | Electron wrapper, not direct verification |
| Reddit thread | Forum | Low | Anecdotal, no technical proof |
| Chromium source | Primary | High | **Code confirms behavior** |

**Chromium Evidence** (from `ca_renderer_layer_tree.mm`):
```cpp
if (protected_video_type_ != gfx::ProtectedVideoType::kClear) {
    av_layer_.preventsCapture = YES;
}
```

When hardware acceleration is disabled, Widevine uses software decryption, `protected_video_type_` becomes `kClear`, and `preventsCapture` is NOT set.

**Verification Status**: **PARTIALLY_VERIFIED**

- Logic is sound based on Chromium source
- Community reports support the claim
- **NOT experimentally verified on current macOS/Chrome versions**
- May change with future Widevine/Chrome updates

**Critical Note**: This claim MUST be tested on actual Mac hardware with:
- Current Chrome version
- Current Netflix/Prime Video
- macOS 14+

### Claim 2: "Safari will always produce black frames for DRM-protected content"

**Document Citation**:
> "Safari uses Apple's FairPlay DRM, which is deeply integrated with the OS... No software fallback option."

**Cited Sources**:
- Apple Technical Note TN2454

**Audit**:

Apple's FairPlay documentation confirms:
- FairPlay is hardware-accelerated
- No user-accessible option to disable
- Integrated with Secure Enclave on Apple Silicon

**Verification Status**: **VERIFIED**

- Consistent with Apple's design philosophy
- No user-configurable software rendering mode exists
- Safari's DRM integration is OS-level

### Claim 3: "AVSampleBufferDisplayLayer.preventsCapture = true causes black in all capture methods"

**Document Citation**:
> "When this property is true... Every capture method on macOS receives black"

**Cited Source**:
- Apple Developer Documentation

**Audit**:

Apple Documentation states:
> "A Boolean value that indicates whether the layer protects media content from capture."

**Verification Status**: **VERIFIED**

- Primary source (Apple documentation)
- Behavior documented
- OBS community confirms same behavior

### Claim 4: "IOFramebuffer cannot access VRAM framebuffer since macOS 10.13"

**Document Citation**:
> "IOFramebuffer can't access VRAM framebuffer in macOS 10.13"

**Cited Source**:
- Stack Overflow question from 2017

**Audit**:

| Aspect | Assessment |
|--------|------------|
| Original claim date | 2017 (macOS 10.13) |
| Current macOS | 14+ |
| Apple Silicon architecture | Completely different from Intel |

**Verification Status**: **OUTDATED**

- The claim was about Intel Macs with macOS 10.13
- Apple Silicon has a completely different architecture (DCP coprocessor)
- On Apple Silicon, this capability never existed to begin with
- The spirit of the claim (no direct framebuffer access) remains true

### Claim 5: "Apple Silicon uses Display Coprocessor (DCP) with no user-space API"

**Document Citation**:
> "Apple Silicon Macs have a dedicated Display Coprocessor... No user-space API access to pixel data"

**Cited Sources**:
- TechBoards forum thread
- display-port-recovery-research.md

**Audit**:

| Source | Credibility | Notes |
|--------|-------------|-------|
| TechBoards forum | Medium | Technical discussion, not primary |
| GitHub research doc | Medium | Reverse-engineering findings |
| Apple documentation | N/A | Apple does not document DCP publicly |

**Verification Status**: **PARTIALLY_VERIFIED**

- No Apple documentation confirms or denies
- Consistent with observed behavior
- Reverse-engineering community has mapped DCP firmware
- No public API exists for DCP access

### Claim 6: "Metal cannot access another application's textures"

**Document Citation**:
> "Metal CANNOT access... Another app's textures"

**Cited Source**:
- Apple Metal documentation

**Audit**:

This is fundamental to macOS process isolation:
- Metal resources are per-process
- No API exists to enumerate another process's GPU resources
- Consistent with macOS sandboxing model

**Verification Status**: **VERIFIED**

- Fundamental architecture, not a workaround limitation
- No historical capability that was removed

### Claim 7: "Virtual displays don't bypass DRM protection"

**Document Citation**:
> "Putting protected content on a virtual display does not make it capturable"

**Cited Source**:
- BetterDisplay GitHub issues

**Audit**:

BetterDisplay issues confirm users attempting this workaround fail:
- `preventsCapture` flag applies regardless of display target
- WindowServer enforces protection per-layer, not per-display

**Verification Status**: **PARTIALLY_VERIFIED**

- Consistent with how `preventsCapture` works
- Community reports support
- Not independently verified experimentally

---

## Browser-Specific Claims Matrix

| Claim | Netflix Chrome HW-ON | Netflix Chrome HW-OFF | Netflix Safari | Prime Chrome HW-OFF |
|-------|---------------------|----------------------|----------------|---------------------|
| Research doc claim | Black | Visible | Black | Visible |
| Source type | Community | Community | Apple docs | Community |
| Verification | UNVERIFIED | UNVERIFIED | VERIFIED | UNVERIFIED |

**Key Gap**: The research document's core practical claim (HW accel off enables capture) is NOT verified with actual testing.

---

## OS/Browser Version Assumptions

The research document does NOT specify:
- macOS version tested
- Chrome version tested
- Netflix/Prime client version
- Date of testing

**Risk**: DRM behavior changes with:
- Chrome updates (new Widevine versions)
- macOS updates (new WindowServer behavior)
- Netflix/Prime client changes

---

## Claims Requiring Hardware Verification

| Claim | Test Required | Hardware |
|-------|---------------|----------|
| Chrome HW-off enables Netflix capture | Mac + Chrome + Netflix subscription | Mac |
| Chrome HW-off enables Prime capture | Mac + Chrome + Prime subscription | Mac |
| Safari always black | Mac + Safari + Netflix subscription | Mac |
| Black region detection works | Mac + SCK + test video | Mac |
| Metal histogram accuracy | Mac + Metal GPU | Mac |

---

## Sources Assessment

### Primary Sources (High Credibility)

| Source | What It Confirms |
|--------|------------------|
| Apple `preventsCapture` docs | Layer-level protection exists |
| Chromium source code | `preventsCapture` set based on DRM level |
| Apple Metal docs | No cross-process texture access |

### Secondary Sources (Medium Credibility)

| Source | What It Supports |
|--------|------------------|
| OBS GitHub issues | Protected content appears black |
| BetterDisplay issues | Virtual displays don't bypass |
| Stack Overflow | Historical IOFramebuffer limitations |

### Tertiary Sources (Low Credibility)

| Source | Problem |
|--------|---------|
| Reddit threads | Anecdotal, outdated |
| Forum discussions | Not verified, may be misunderstood |
| Blog posts | Often summarize without verification |

---

## Audit Conclusions

### Verified (Safe to Rely On)

1. ✅ `AVSampleBufferDisplayLayer.preventsCapture` causes black in captures
2. ✅ Safari/FairPlay has no software rendering fallback
3. ✅ Metal cannot access other processes' GPU resources
4. ✅ No public API for WindowServer compositor access

### Requires Testing (Do Not Assume True)

1. ⚠️ Chrome HW-off enables Netflix capture **on current versions**
2. ⚠️ Chrome HW-off enables Prime capture **on current versions**
3. ⚠️ Black region detection correctly identifies DRM content
4. ⚠️ Rectangular region heuristic has acceptable precision/recall

### Likely True But Unverified

1. 🔶 Apple Silicon DCP has no user-space API
2. 🔶 Virtual displays don't bypass protection
3. 🔶 IOSurface-level protection exists for DRM content

---

## Recommended Next Steps

### Before Claiming Chrome Workaround Works

Execute this test on Mac:

```bash
# Environment
macOS: [version]
Chrome: [version]
Netflix: [test video e.g. "Test Patterns"]

# Steps
1. Open LightStar with screen capture
2. Open Netflix in Chrome (HW accel ON, default)
3. Play video, observe: BLACK/VISIBLE
4. Disable HW accel in Chrome
5. Restart Chrome
6. Play same video, observe: BLACK/VISIBLE

# Record
- Frame black percentage before
- Frame black percentage after
- Video resolution maintained
- CPU usage change
```

### Never Claim Without Testing

- "LightStar works with Netflix" ❌
- "Chrome compatibility mode enables sync" (only if tested) ✅
- "Some users report success with Chrome" ✅

---

## Legal and Ethical Notes

The research document correctly states:
- LightStar does NOT circumvent DRM
- Color analysis is not decryption
- No DRM keys or licenses are accessed

This audit confirms these statements are accurate. The workaround (user disabling HW accel) is:
- A user choice, not automatic
- Does not involve modifying DRM components
- Analogous to Ambilight hardware behavior
