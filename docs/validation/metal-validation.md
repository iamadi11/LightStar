# LightStar Metal GPU Validation

> Generated: September 2026
> Environment: Cloud Agent (code inspection only)
> Status: NOT_VERIFIED — Metal shader compilation and execution require macOS hardware

---

## 1. Metal Implementation Overview

### Files

| File | Purpose | Lines |
|------|---------|-------|
| `MetalColorAnalyzer.swift` | Swift wrapper, buffer management | ~340 |
| `MetalColorAnalyzer.metal` | Compute shaders | ~170 |

### Shaders Implemented

| Shader | Function | Description |
|--------|----------|-------------|
| `computeHistogram` | Color analysis | Per-pixel HSV histogram |
| `analyzeRowDarkness` | DRM detection | Row-wise black pixel counting |
| `analyzeColumnDarkness` | DRM detection | Column-wise black pixel counting |
| `downsampleTexture` | Preprocessing | Box filter downsampling |

---

## 2. Shader Compilation Status

**Status**: BLOCKED_ENVIRONMENT — Cannot verify in cloud

The Metal shader file is included as a resource in `Package.swift`:

```swift
.target(
    name: "LightStarCore",
    resources: [
        .process("MetalColorAnalyzer.metal")
    ]
),
```

### Initialization Path

```swift
let library: MTLLibrary
if let bundleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
    library = bundleLib
} else if let defaultLib = device.makeDefaultLibrary() {
    library = defaultLib
} else {
    throw MetalError.noLibrary
}
```

**Concern**: Falls back to `makeDefaultLibrary()` which may not find bundled shaders in all contexts.

---

## 3. Input Format Analysis

### Texture Creation

```swift
CVMetalTextureCacheCreateTextureFromImage(
    nil, textureCache, pixelBuffer, nil,
    .bgra8Unorm, width, height, 0, &cvTexture
)
```

| Property | Value | Notes |
|----------|-------|-------|
| Format | BGRA8Unorm | Standard macOS capture format |
| Width | CVPixelBuffer width | Typically 48 from SCK config |
| Height | CVPixelBuffer height | Typically 27 from SCK config |

### Shader Input Expectation

```metal
texture2d<float, access::read> inputTexture [[texture(0)]]
```

The shader reads RGBA values (0-1 normalized). BGRA format is handled by Metal's texture sampling which swizzles correctly.

---

## 4. Output Buffer Analysis

### Buffer Layout

| Buffer | Size | Type | Purpose |
|--------|------|------|---------|
| `histogramBuffer` | 36 × 4 = 144 bytes | UInt32[36] | Weighted votes per hue bin |
| `binSatSumBuffer` | 144 bytes | UInt32[36] | Saturation sum (fixed-point) |
| `binValSumBuffer` | 144 bytes | UInt32[36] | Value sum (fixed-point) |
| `binCountBuffer` | 144 bytes | UInt32[36] | Pixel count per bin |
| `blackCountBuffer` | 4 bytes | UInt32 | Total black pixels |
| `totalPixelsBuffer` | 4 bytes | UInt32 | Total processed pixels |
| `darkRowCountBuffer` | 4 bytes | UInt32 | Rows that are >80% black |
| `darkColCountBuffer` | 4 bytes | UInt32 | Columns that are >80% black |

### Fixed-Point Encoding

Saturation and value are stored as fixed-point (× 10000):

```metal
uint satFixed = uint(s * 10000.0);
uint valFixed = uint(v * 10000.0);
```

Decoded in Swift:

```swift
let sat = Double(binSatSum[maxBin]) / count / 10000.0
```

**Concern**: This limits precision to 4 decimal places. Acceptable for color analysis.

---

## 5. Threadgroup Configuration

### Histogram Kernel

```swift
let histogramThreadsPerGrid = MTLSize(width: width, height: height, depth: 1)
let histogramThreadsPerGroup = MTLSize(
    width: min(16, histogramPipeline.maxTotalThreadsPerThreadgroup),
    height: min(16, histogramPipeline.maxTotalThreadsPerThreadgroup / 16),
    depth: 1
)
```

For 48×27 texture: Grid = 48×27, Threadgroup = 16×16 (or smaller)

### Row/Column Analysis

```swift
let rowThreadsPerGrid = MTLSize(width: height, height: 1, depth: 1)  // 27 threads
let rowThreadsPerGroup = MTLSize(width: min(64, height), height: 1, depth: 1)  // 27 threads
```

**Concern**: Using `dispatchThreads` which requires Metal 2.0+. Should be fine for macOS 14.0+.

---

## 6. Synchronization Analysis

### GPU-CPU Sync

```swift
commandBuffer.commit()
commandBuffer.waitUntilCompleted()  // BLOCKING CALL
```

**Issue**: `waitUntilCompleted()` blocks the calling thread until GPU finishes. For real-time color analysis at 30-60 fps:

- Frame time budget: ~16-33ms
- GPU compute time: Unknown (not measured)
- Blocking call may cause frame drops

**Recommendation**: Use double/triple buffering with completion handlers instead of blocking.

### Atomic Operations

All histogram updates use `atomic_fetch_add_explicit`:

```metal
atomic_fetch_add_explicit(&histogram[bin], weightedVote, memory_order_relaxed);
```

`memory_order_relaxed` is appropriate since:
- No ordering dependencies between pixels
- Final result read after `waitUntilCompleted`

---

## 7. Correctness Analysis

### RGB to HSV Conversion

**Metal implementation** (`MetalColorAnalyzer.metal:8-30`):

```metal
float3 rgbToHSV(float3 rgb) {
    float r = rgb.r, g = rgb.g, b = rgb.b;
    float mx = max(max(r, g), b);
    float mn = min(min(r, g), b);
    float d = mx - mn;
    
    float h = 0.0;
    float s = mx < 0.000001 ? 0.0 : d / mx;
    float v = mx;
    
    if (d > 0.000001) {
        if (mx == r) { h = (g - b) / d; }
        else if (mx == g) { h = 2.0 + (b - r) / d; }
        else { h = 4.0 + (r - g) / d; }
        h = fmod(h / 6.0, 1.0);
        if (h < 0.0) h += 1.0;
    }
    return float3(h, s, v);
}
```

**CPU implementation** (`MetalColorAnalyzer.swift:300-313`):

```swift
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
```

**Assessment**: Both implementations use the same algorithm. Minor differences:
- Epsilon: 0.000001 (Metal) vs 1e-6 (Swift) — equivalent
- Float precision (Metal) vs Double precision (Swift)

**Potential Issue**: Float precision may cause slight differences for near-black pixels.

### Histogram Binning

```metal
int bin = min(HISTOGRAM_BINS - 1, int(h * float(HISTOGRAM_BINS)));
```

For h ∈ [0, 1), this produces bins 0-35. Edge case h=1.0 is clamped to bin 35.

### Black Pixel Detection

```metal
if (v < 0.05) {
    atomic_fetch_add_explicit(blackCount, 1, memory_order_relaxed);
}
```

Threshold: Value < 5% is "black". This is reasonable.

### Rectangular Black Region Detection

```swift
let hasRectangularBlackRegion = Int(darkRowCount) > height / 3 || Int(darkColCount) > width / 3
```

If more than 1/3 of rows or columns are >80% black, flag as rectangular region (likely DRM).

---

## 8. Synthetic Test Vectors

### Test Cases to Verify

| Test | Input | Expected Output |
|------|-------|-----------------|
| Pure Red | All pixels (255, 0, 0) | Hue ≈ 0.0, Sat = 1.0, Val = 1.0 |
| Pure Green | All pixels (0, 255, 0) | Hue ≈ 0.33, Sat = 1.0, Val = 1.0 |
| Pure Blue | All pixels (0, 0, 255) | Hue ≈ 0.67, Sat = 1.0, Val = 1.0 |
| Pure White | All pixels (255, 255, 255) | Sat = 0.0, Val = 1.0 (excluded from histogram) |
| Pure Black | All pixels (0, 0, 0) | blackPixelPercentage = 1.0, hasRectangularBlackRegion = true |
| 50% Red/Blue | Left red, right blue | Hue varies, should pick dominant |
| Gradient | Red→Blue horizontal | Hue distributed across bins |
| Dark gradient | Low value gradient | Most pixels excluded (v < 0.12 threshold) |

### Implementation for Mac Testing

```swift
func createSyntheticPixelBuffer(color: (UInt8, UInt8, UInt8), width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
    
    guard let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bpr + x * 4
            base[i] = color.2      // B
            base[i+1] = color.1    // G
            base[i+2] = color.0    // R
            base[i+3] = 255        // A
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
```

---

## 9. GPU Resource Lifecycle

### Allocation

Resources allocated once in `init()`:
- `MTLDevice` — system default
- `MTLCommandQueue` — single queue
- `MTLComputePipelineState` × 4 — one per shader
- `CVMetalTextureCache` — for buffer conversion
- `MTLBuffer` × 8 — for histogram data

### Per-Frame Operations

1. Clear all buffers (`memset`)
2. Create `MTLCommandBuffer`
3. Create `MTLComputeCommandEncoder`
4. Create `CVMetalTexture` from `CVPixelBuffer`
5. Dispatch compute kernels
6. Wait for completion
7. Read results from buffers

### Cleanup

No explicit cleanup. Resources released when `MetalColorAnalyzer` is deallocated.

**Concern**: `CVMetalTexture` created each frame is autoreleased. May cause memory pressure under high frame rates.

---

## 10. Performance Considerations

### Theoretical Analysis

For 48×27 texture:
- Total pixels: 1,296
- Histogram kernel: 1,296 threads (parallel)
- Row analysis: 27 threads × 48 reads
- Column analysis: 48 threads × 27 reads

Expected GPU time: Sub-millisecond on modern Apple Silicon.

### Actual Performance

**Status**: NOT_VERIFIED — Requires hardware execution

### Optimization Opportunities

1. **Double buffering**: Avoid blocking `waitUntilCompleted()`
2. **Shared memory histogram**: Reduce atomic contention
3. **Downsampling integration**: Currently unused for small textures
4. **Fused kernel**: Combine row/col analysis into histogram pass

---

## 11. CPU Fallback Analysis

The CPU fallback (`cpuFallbackAnalysis`) is functionally equivalent but:
- Uses Double precision vs Float
- No edge weighting (unlike GPU)
- No rectangular region detection

**Discrepancy**: GPU gives 3× weight to edge pixels; CPU does not. This could cause different dominant color selection.

---

## 12. Validation Status

| Check | Status | Notes |
|-------|--------|-------|
| Shader syntax | ✅ Valid Metal | Code review |
| Algorithm correctness | ✅ Correct | RGB→HSV standard |
| Buffer sizing | ✅ Correct | Matches bin count |
| Threadgroup config | ✅ Valid | Uses dispatchThreads |
| Atomic operations | ✅ Correct | memory_order_relaxed |
| CPU/GPU parity | ⚠️ Differs | Edge weighting, precision |
| Compilation | ❌ NOT_VERIFIED | Requires Mac |
| Execution | ❌ NOT_VERIFIED | Requires Mac |
| Performance | ❌ NOT_VERIFIED | Requires Mac |

---

## 13. Commands for Mac Verification

```bash
# Build and run Metal tests
cd /path/to/LightStar
swift test --package-path LightStarCore --filter MetalTests

# Manual shader compilation check
xcrun metal -c LightStarCore/Sources/LightStarCore/MetalColorAnalyzer.metal -o /tmp/metal-test.air
xcrun metallib -o /tmp/metal-test.metallib /tmp/metal-test.air
echo "Shader compilation: $?"
```
