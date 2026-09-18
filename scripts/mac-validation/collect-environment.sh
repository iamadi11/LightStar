#!/bin/bash
# LightStar Environment Information Collection
# Run this on Mac before testing

set -e

OUTPUT_DIR="${1:-./lightstar-validation-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"

echo "=== LightStar Validation Environment Collection ==="
echo "Output directory: $OUTPUT_DIR"
echo ""

# macOS Version
echo "Collecting macOS version..."
sw_vers > "$OUTPUT_DIR/macos-version.txt"

# Hardware
echo "Collecting hardware info..."
system_profiler SPHardwareDataType > "$OUTPUT_DIR/hardware.txt"

# GPU
echo "Collecting GPU info..."
system_profiler SPDisplaysDataType > "$OUTPUT_DIR/displays-and-gpu.txt"

# Displays (detailed)
echo "Collecting display configuration..."
swift << 'EOF' > "$OUTPUT_DIR/display-details.txt"
import CoreGraphics

func getActiveDisplays() -> [CGDirectDisplayID] {
    var displays = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    CGGetActiveDisplayList(32, &displays, &count)
    return Array(displays[0..<Int(count)])
}

for id in getActiveDisplays() {
    print("Display ID: \(id)")
    print("  Main: \(CGDisplayIsMain(id))")
    print("  Built-in: \(CGDisplayIsBuiltin(id))")
    print("  Online: \(CGDisplayIsOnline(id))")
    print("  Bounds: \(CGDisplayBounds(id))")
    if let mode = CGDisplayCopyDisplayMode(id) {
        print("  Resolution: \(mode.width)x\(mode.height)")
        print("  Refresh: \(mode.refreshRate) Hz")
        print("  Pixel Width: \(mode.pixelWidth)x\(mode.pixelHeight)")
    }
    print("")
}
EOF

# Browser versions
echo "Collecting browser versions..."
{
    echo "Chrome:"
    /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --version 2>/dev/null || echo "Not installed"
    echo ""
    echo "Safari:"
    defaults read /Applications/Safari.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "Unknown"
    echo ""
    echo "Firefox:"
    /Applications/Firefox.app/Contents/MacOS/firefox --version 2>/dev/null || echo "Not installed"
    echo ""
    echo "Edge:"
    /Applications/Microsoft\ Edge.app/Contents/MacOS/Microsoft\ Edge --version 2>/dev/null || echo "Not installed"
} > "$OUTPUT_DIR/browser-versions.txt"

# TCC permissions (Screen Recording)
echo "Checking Screen Recording permission..."
{
    echo "Screen Recording TCC check:"
    # This will prompt if not granted
    sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
        "SELECT client, auth_value FROM access WHERE service='kTCCServiceScreenCapture'" 2>/dev/null || echo "Cannot read TCC database (expected)"
} > "$OUTPUT_DIR/permissions.txt"

# Accessibility permission
echo "Checking Accessibility permission..."
{
    echo "Accessibility TCC check:"
    # This requires code to check properly
    echo "(Run LightStar to check AXIsProcessTrusted)"
} >> "$OUTPUT_DIR/permissions.txt"

# Metal support
echo "Checking Metal support..."
swift << 'EOF' > "$OUTPUT_DIR/metal-info.txt"
import Metal

if let device = MTLCreateSystemDefaultDevice() {
    print("Metal Device: \(device.name)")
    print("Max Threads Per Threadgroup: \(device.maxThreadsPerThreadgroup)")
    print("Max Buffer Length: \(device.maxBufferLength)")
    print("Has Unified Memory: \(device.hasUnifiedMemory)")
    print("Supports Family: apple7 = \(device.supportsFamily(.apple7))")
} else {
    print("No Metal device available")
}
EOF

# Network interfaces
echo "Collecting network info..."
ifconfig | grep -E "^[a-z]|inet " > "$OUTPUT_DIR/network.txt"

# Summary
echo ""
echo "=== Collection Complete ==="
echo "Files created in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"
echo ""
echo "Please include this directory with test results."
