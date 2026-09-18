#!/bin/bash
# LightStar DRM Capture Testing Script
# Run this on Mac with Netflix/Prime subscription

set -e

OUTPUT_DIR="${1:-./drm-test-results-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"

echo "=== LightStar DRM Capture Testing ==="
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "IMPORTANT: This test requires:"
echo "  - Netflix and/or Amazon Prime subscription"
echo "  - Chrome browser installed"
echo "  - Screen Recording permission granted to LightStar"
echo ""

# Environment collection first
./collect-environment.sh "$OUTPUT_DIR/environment"

echo ""
echo "=== Test Matrix ==="
echo ""
echo "We will test the following configurations:"
echo ""
echo "| # | Content | Browser | HW Accel | Expected |"
echo "|---|---------|---------|----------|----------|"
echo "| 1 | Desktop | N/A     | N/A      | Visible  |"
echo "| 2 | YouTube | Chrome  | ON       | Visible  |"
echo "| 3 | Netflix | Chrome  | ON       | BLACK    |"
echo "| 4 | Netflix | Chrome  | OFF      | Visible? |"
echo "| 5 | Netflix | Safari  | N/A      | BLACK    |"
echo "| 6 | Prime   | Chrome  | ON       | BLACK    |"
echo "| 7 | Prime   | Chrome  | OFF      | Visible? |"
echo ""

# Create results file
cat > "$OUTPUT_DIR/test-results.md" << 'TEMPLATE'
# DRM Capture Test Results

**Date**: 
**Tester**: 
**macOS Version**: 
**Chrome Version**: 
**Safari Version**: 

## Test 1: Desktop Capture (Baseline)

**Content**: Solid color desktop wallpaper
**Configuration**: Normal desktop
**Expected**: Colors captured correctly

**Procedure**:
1. Set desktop wallpaper to solid RED
2. Start LightStar screen sync
3. Check captured color

**Result**: [ ] PASS  [ ] FAIL

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Notes**: 


---

## Test 2: YouTube (Chrome HW Accel ON)

**Content**: Any colorful YouTube video
**Browser**: Chrome with hardware acceleration ON (default)
**Expected**: Video colors captured

**Procedure**:
1. Open YouTube in Chrome
2. Play a colorful video (e.g., music video)
3. Check LightStar captures video colors

**Result**: [ ] PASS  [ ] FAIL

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Notes**: 


---

## Test 3: Netflix (Chrome HW Accel ON)

**Content**: Netflix video (any title)
**Browser**: Chrome with hardware acceleration ON (default)
**Expected**: BLACK (DRM protected)

**Procedure**:
1. Open Netflix in Chrome
2. Play any title
3. Check LightStar - should show black/no color

**Result**: [ ] PASS (black as expected)  [ ] UNEXPECTED (colors visible)

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Protected Content Detected**: [ ] Yes  [ ] No
**Notes**: 


---

## Test 4: Netflix (Chrome HW Accel OFF)

**Content**: Netflix video (same title as Test 3)
**Browser**: Chrome with hardware acceleration DISABLED
**Expected**: VISIBLE (Widevine L3 software decoding)

**Procedure**:
1. Open Chrome Settings > System
2. DISABLE "Use graphics acceleration when available"
3. RESTART Chrome completely
4. Open Netflix, play the same title
5. Check LightStar captures video colors

**Result**: [ ] PASS (colors visible)  [ ] FAIL (still black)

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Video Quality Available**: [ ] 4K  [ ] 1080p  [ ] 720p  [ ] Lower
**Notes**: 


---

## Test 5: Netflix (Safari)

**Content**: Netflix video
**Browser**: Safari
**Expected**: BLACK (FairPlay, no workaround)

**Procedure**:
1. Open Netflix in Safari
2. Play any title
3. Check LightStar - should show black

**Result**: [ ] PASS (black as expected)  [ ] UNEXPECTED (colors visible)

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Notes**: 


---

## Test 6: Amazon Prime Video (Chrome HW Accel ON)

**Content**: Prime Video (any title)
**Browser**: Chrome with hardware acceleration ON
**Expected**: BLACK (DRM protected)

**Procedure**:
1. Re-enable Chrome hardware acceleration if disabled
2. RESTART Chrome
3. Open Prime Video, play any title
4. Check LightStar

**Result**: [ ] PASS (black as expected)  [ ] UNEXPECTED (colors visible)

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Notes**: 


---

## Test 7: Amazon Prime Video (Chrome HW Accel OFF)

**Content**: Prime Video (same title as Test 6)
**Browser**: Chrome with hardware acceleration DISABLED
**Expected**: VISIBLE (if Widevine L3 fallback works)

**Procedure**:
1. Disable Chrome hardware acceleration
2. RESTART Chrome
3. Open Prime Video, play the same title
4. Check LightStar

**Result**: [ ] PASS (colors visible)  [ ] FAIL (still black)

**Captured Color**: H=___ S=___ V=___
**Black Percentage**: ___%
**Video Quality Available**: [ ] 4K  [ ] 1080p  [ ] 720p  [ ] Lower
**Notes**: 


---

## Summary

| Test | Content | Browser | HW Accel | Expected | Actual | Status |
|------|---------|---------|----------|----------|--------|--------|
| 1 | Desktop | N/A | N/A | Visible | | |
| 2 | YouTube | Chrome | ON | Visible | | |
| 3 | Netflix | Chrome | ON | Black | | |
| 4 | Netflix | Chrome | OFF | Visible | | |
| 5 | Netflix | Safari | N/A | Black | | |
| 6 | Prime | Chrome | ON | Black | | |
| 7 | Prime | Chrome | OFF | Visible | | |

## Additional Observations




## Conclusion

**Chrome HW-OFF workaround verified for Netflix**: [ ] YES  [ ] NO  [ ] PARTIAL
**Chrome HW-OFF workaround verified for Prime**: [ ] YES  [ ] NO  [ ] PARTIAL
**Safari confirmed always black**: [ ] YES  [ ] NO

TEMPLATE

echo ""
echo "Test template created at: $OUTPUT_DIR/test-results.md"
echo ""
echo "Please:"
echo "1. Open the template file"
echo "2. Run LightStar"
echo "3. Complete each test"
echo "4. Fill in the results"
echo "5. Save screenshots where helpful"
echo ""
echo "After completion, share the $OUTPUT_DIR directory for analysis."
