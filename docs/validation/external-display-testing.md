# LightStar External Display Testing

> Generated: September 2026
> Environment: Cloud Agent (test preparation only)
> Status: NOT_TESTED — Requires Mac with external display

---

## Purpose

Validate screen capture behavior with external displays:
- Resolution handling
- Refresh rate handling
- Multi-display selection
- Display arrangement
- Color accuracy
- Latency

---

## Test Hardware Requirements

| Item | Required | Notes |
|------|----------|-------|
| Mac | Yes | Apple Silicon or Intel |
| External monitor | Yes | HDMI or DisplayPort/USB-C |
| Adapter (if needed) | Maybe | USB-C to HDMI/DP |
| Different resolution monitor | Recommended | To test resolution handling |

---

## Pre-Test Data Collection

### Script: Collect Display Information

```bash
#!/bin/bash
# scripts/mac-validation/collect-display-info.sh

echo "=== LightStar Display Information Collection ==="
echo "Date: $(date)"
echo ""

echo "=== macOS Version ==="
sw_vers

echo ""
echo "=== Hardware Model ==="
system_profiler SPHardwareDataType | grep -E "(Model Name|Chip|Memory)"

echo ""
echo "=== Display Configuration ==="
system_profiler SPDisplaysDataType

echo ""
echo "=== Active Displays (CGDisplayID) ==="
# This requires a small Swift script
swift -e '
import CoreGraphics
import Foundation
for id in CGGetActiveDisplayList(maxDisplays: 32) ?? [] {
    let bounds = CGDisplayBounds(id)
    let mode = CGDisplayCopyDisplayMode(id)
    print("Display \(id):")
    print("  Bounds: \(bounds)")
    print("  Resolution: \(mode?.width ?? 0)x\(mode?.height ?? 0)")
    print("  Refresh: \(mode?.refreshRate ?? 0) Hz")
    print("  Main: \(CGDisplayIsMain(id))")
    print("  Built-in: \(CGDisplayIsBuiltin(id))")
    print("")
}

func CGGetActiveDisplayList(maxDisplays: UInt32) -> [CGDirectDisplayID]? {
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(maxDisplays, &displays, &count) == .success else { return nil }
    return Array(displays[0..<Int(count)])
}
'
```

---

## Test Cases

### T1: Built-in Display Capture

**Preconditions**:
- Mac with built-in display
- Screen Recording permission granted

**Steps**:
1. Start LightStar
2. Enable screen sync mode
3. Display solid color test patterns (red, green, blue, white)
4. Record captured colors

**Expected**:
- Colors match test patterns
- No significant latency

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T2: External Display Selection

**Preconditions**:
- External display connected
- Both displays active

**Steps**:
1. Start LightStar
2. Open display selection UI
3. Verify both displays listed
4. Select external display
5. Move test content to external display
6. Verify capture follows selected display

**Expected**:
- Both displays enumerated with correct names
- Selection switches capture target

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T3: External Display at Different Resolution

**Preconditions**:
- External display with different resolution than built-in

**Steps**:
1. Note built-in display resolution
2. Note external display resolution
3. Capture from each, verify both work
4. Check if resolution affects capture quality or performance

**Expected**:
- Both resolutions captured correctly
- Internal downsampling handles resolution differences

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T4: External Display at Different Refresh Rate

**Preconditions**:
- External display with different refresh rate (e.g., 60Hz vs 120Hz built-in)

**Steps**:
1. Capture from 60Hz display
2. Note frame rate
3. Capture from 120Hz display
4. Note frame rate

**Expected**:
- Frame rate adapts to display
- No tearing or artifacts

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T5: Display Disconnect During Capture

**Preconditions**:
- Capturing from external display

**Steps**:
1. Start capture from external display
2. Disconnect external display
3. Observe behavior

**Expected**:
- Graceful error handling
- No crash
- Fallback to primary display or stopped state

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T6: Display Connect During Capture

**Preconditions**:
- Capturing from built-in display

**Steps**:
1. Start capture from built-in
2. Connect external display
3. Check display list updates

**Expected**:
- New display appears in list
- Current capture continues
- User can switch to new display

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T7: Mirrored Displays

**Preconditions**:
- Display mirroring enabled

**Steps**:
1. Enable display mirroring
2. Start capture
3. Verify capture works
4. Note if captured resolution changes

**Expected**:
- Single display appears (mirrored)
- Capture works at mirrored resolution

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T8: Extended Desktop Arrangement

**Preconditions**:
- Extended desktop with specific arrangement

**Steps**:
1. Arrange displays (e.g., external above built-in)
2. Capture from each
3. Verify content corresponds to correct physical display

**Expected**:
- Each display ID maps to correct physical display

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

## DRM Tests with External Display

### T9: Netflix on External Display (Chrome HW ON)

**Steps**:
1. Move Chrome window to external display
2. Play Netflix content
3. Capture from external display

**Expected**:
- Black video region (protected)

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

### T10: Netflix on External Display (Chrome HW OFF)

**Steps**:
1. Disable Chrome hardware acceleration
2. Restart Chrome
3. Move Chrome window to external display
4. Play Netflix content
5. Capture from external display

**Expected**:
- Video content visible (if HW-off workaround works)

**Actual**: [Record on Mac]

**Status**: NOT_TESTED

---

## Data Collection Template

For each test, record:

```
Test ID: Txx
Date: YYYY-MM-DD
macOS Version: x.x.x
Hardware: MacBook Pro M2 / Mac Studio M1 Max / etc.

Built-in Display:
  Resolution: ____x____
  Refresh: ____ Hz

External Display:
  Model: ____
  Connection: HDMI / USB-C / Thunderbolt
  Resolution: ____x____
  Refresh: ____ Hz

Test Result:
  Status: PASS / FAIL / BLOCKED
  Notes: ____
  Evidence: screenshot / video / log file
```

---

## HDMI vs HDCP Clarification

**Important**: This test suite does NOT attempt to capture the HDMI/DisplayPort electrical signal. It captures the macOS desktop which happens to be displayed on an external monitor.

| What This Tests | What This Does NOT Test |
|-----------------|------------------------|
| ScreenCaptureKit with external display | Raw HDMI signal capture |
| Display enumeration API | HDCP interception |
| Resolution/refresh handling | Display controller output |
| Protected content behavior | DRM bypass |

The expectation is that protected content will STILL be black when captured from an external display, because the protection occurs at the WindowServer level, not at the display output level.

---

## Known Limitations

1. **Cannot test HDCP**: No API to access HDMI signal
2. **Cannot verify display controller output**: Only see what ScreenCaptureKit provides
3. **External display behavior may vary**: Some monitors have different color profiles

---

## Test Script

```bash
#!/bin/bash
# scripts/mac-validation/test-external-display.sh

echo "=== LightStar External Display Tests ==="
echo "This script guides manual testing."
echo ""

# Collect info first
./collect-display-info.sh > external-display-info-$(date +%Y%m%d).txt

echo ""
echo "=== Test T1: Built-in Display ==="
echo "1. Open System Preferences > Displays"
echo "2. Display solid red on built-in display"
echo "3. Check LightStar captured color"
echo "Press Enter when complete..."
read

echo "Result (PASS/FAIL/SKIP): "
read T1_RESULT

echo ""
echo "=== Test T2: External Display Selection ==="
echo "1. Open LightStar settings"
echo "2. Find display selection"
echo "3. Verify external display listed"
echo "Press Enter when complete..."
read

echo "Result (PASS/FAIL/SKIP): "
read T2_RESULT

# ... continue for other tests ...

echo ""
echo "=== Results Summary ==="
echo "T1 Built-in Display: $T1_RESULT"
echo "T2 External Display Selection: $T2_RESULT"
# ... other results ...
```
