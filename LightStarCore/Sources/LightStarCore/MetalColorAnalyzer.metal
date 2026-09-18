#include <metal_stdlib>
using namespace metal;

// Histogram bin count - 36 bins for 10-degree hue resolution
constant int HISTOGRAM_BINS = 36;

// RGB to HSV conversion
float3 rgbToHSV(float3 rgb) {
    float r = rgb.r, g = rgb.g, b = rgb.b;
    float mx = max(max(r, g), b);
    float mn = min(min(r, g), b);
    float d = mx - mn;
    
    float h = 0.0;
    float s = mx < 0.000001 ? 0.0 : d / mx;
    float v = mx;
    
    if (d > 0.000001) {
        if (mx == r) {
            h = (g - b) / d;
        } else if (mx == g) {
            h = 2.0 + (b - r) / d;
        } else {
            h = 4.0 + (r - g) / d;
        }
        h = fmod(h / 6.0, 1.0);
        if (h < 0.0) h += 1.0;
    }
    
    return float3(h, s, v);
}

// Kernel: Compute per-pixel histogram contributions
// Each thread processes one pixel and atomically updates histogram bins
kernel void computeHistogram(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint* histogram [[buffer(0)]],      // 36 bins for weighted votes
    device atomic_uint* binSatSum [[buffer(1)]],      // Saturation sum per bin (fixed-point)
    device atomic_uint* binValSum [[buffer(2)]],      // Value sum per bin (fixed-point)
    device atomic_uint* binCount [[buffer(3)]],       // Count per bin
    device atomic_uint* blackCount [[buffer(4)]],     // Black pixel count
    device atomic_uint* totalPixels [[buffer(5)]],    // Total pixel count
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid.x >= width || gid.y >= height) return;
    
    float4 pixel = inputTexture.read(gid);
    float3 hsv = rgbToHSV(pixel.rgb);
    float h = hsv.x, s = hsv.y, v = hsv.z;
    
    atomic_fetch_add_explicit(totalPixels, 1, memory_order_relaxed);
    
    // Count black pixels (v < 0.05)
    if (v < 0.05) {
        atomic_fetch_add_explicit(blackCount, 1, memory_order_relaxed);
    }
    
    // Edge weighting: 3x weight for edge pixels
    bool isEdge = (gid.x == 0 || gid.x == width - 1 || gid.y == 0 || gid.y == height - 1);
    float weight = isEdge ? 3.0 : 1.0;
    
    // Only contribute to histogram if pixel is colorful enough
    if (v > 0.12 && s > 0.15) {
        int bin = min(HISTOGRAM_BINS - 1, int(h * float(HISTOGRAM_BINS)));
        
        // Use fixed-point for atomic operations (multiply by 10000)
        uint weightedVote = uint(weight * s * v * 10000.0);
        uint satFixed = uint(s * 10000.0);
        uint valFixed = uint(v * 10000.0);
        
        atomic_fetch_add_explicit(&histogram[bin], weightedVote, memory_order_relaxed);
        atomic_fetch_add_explicit(&binSatSum[bin], satFixed, memory_order_relaxed);
        atomic_fetch_add_explicit(&binValSum[bin], valFixed, memory_order_relaxed);
        atomic_fetch_add_explicit(&binCount[bin], 1, memory_order_relaxed);
    }
}

// Kernel: Analyze rows for dark row detection
kernel void analyzeRowDarkness(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint* darkRowCount [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid >= height) return;
    
    uint blackInRow = 0;
    uint threshold = (width * 8) / 10;
    
    for (uint x = 0; x < width; x++) {
        float4 pixel = inputTexture.read(uint2(x, gid));
        float3 hsv = rgbToHSV(pixel.rgb);
        if (hsv.z < 0.05) {
            blackInRow++;
        }
    }
    
    if (blackInRow > threshold) {
        atomic_fetch_add_explicit(darkRowCount, 1, memory_order_relaxed);
    }
}

// Kernel: Analyze columns for dark column detection
kernel void analyzeColumnDarkness(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint* darkColCount [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    if (gid >= width) return;
    
    uint blackInCol = 0;
    uint threshold = (height * 8) / 10;
    
    for (uint y = 0; y < height; y++) {
        float4 pixel = inputTexture.read(uint2(gid, y));
        float3 hsv = rgbToHSV(pixel.rgb);
        if (hsv.z < 0.05) {
            blackInCol++;
        }
    }
    
    if (blackInCol > threshold) {
        atomic_fetch_add_explicit(darkColCount, 1, memory_order_relaxed);
    }
}

// Downsampling kernel for large textures
kernel void downsampleTexture(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outWidth = outputTexture.get_width();
    uint outHeight = outputTexture.get_height();
    
    if (gid.x >= outWidth || gid.y >= outHeight) return;
    
    uint inWidth = inputTexture.get_width();
    uint inHeight = inputTexture.get_height();
    
    float scaleX = float(inWidth) / float(outWidth);
    float scaleY = float(inHeight) / float(outHeight);
    
    // Box filter: average a region of pixels
    float4 sum = float4(0);
    int count = 0;
    
    uint startX = uint(float(gid.x) * scaleX);
    uint endX = uint(float(gid.x + 1) * scaleX);
    uint startY = uint(float(gid.y) * scaleY);
    uint endY = uint(float(gid.y + 1) * scaleY);
    
    for (uint y = startY; y < endY && y < inHeight; y++) {
        for (uint x = startX; x < endX && x < inWidth; x++) {
            sum += inputTexture.read(uint2(x, y));
            count++;
        }
    }
    
    outputTexture.write(count > 0 ? sum / float(count) : float4(0), gid);
}
