# LightStar Mac Manual Validation Checklist

> Status: CHECKLIST_READY
> Requires: macOS 14.0+, Xcode 15+, optional LED strip

---

## Prerequisites

Before running manual validation:

1. **Build the App**
   ```bash
   cd /workspace
   xcodegen generate
   xcodebuild -project LightStar.xcodeproj -scheme LightStar -configuration Debug build
   ```

2. **Run Unit Tests**
   ```bash
   cd /workspace/LightStarCore
   swift test
   ```

3. **Verify Permissions**
   - System Settings → Privacy & Security → Screen Recording → Add LightStar
   - System Settings → Privacy & Security → Accessibility → Add LightStar
   - System Settings → Privacy & Security → Bluetooth → Add LightStar

---

## Section 1: Application Startup

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M1.1 | App Launch | Open LightStar.app | Menu bar icon appears | ☐ |
| M1.2 | Control Window | Click menu bar icon | Control window opens | ☐ |
| M1.3 | Clean Exit | Quit app | Menu bar icon disappears | ☐ |
| M1.4 | Launch at Login | Enable in settings, reboot | App starts automatically | ☐ |

---

## Section 2: Remote Control Server

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M2.1 | Server Start | Launch app | Bonjour service registered | ☐ |
| M2.2 | Verify Bonjour | `dns-sd -B _lightstar._tcp local.` | Service appears | ☐ |
| M2.3 | Server Stop | Quit app | Service disappears | ☐ |
| M2.4 | Port Binding | `lsof -i :19384` | LightStar process listed | ☐ |

### Verification Commands

```bash
# Check Bonjour registration
dns-sd -B _lightstar._tcp local.

# Check port binding
lsof -i :19384

# Test TCP connection (should accept then close without pairing)
nc localhost 19384
```

---

## Section 3: Screen Capture

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M3.1 | Capture Permission | Enable video sync first time | Permission prompt appears | ☐ |
| M3.2 | Capture Denied | Deny permission | Error shown, fallback offered | ☐ |
| M3.3 | Capture Allowed | Grant permission | Capture starts | ☐ |
| M3.4 | Display Detection | Connect external display | New display in list | ☐ |
| M3.5 | Display Selection | Select external display | Capture switches | ☐ |

### DRM Content Tests

| # | Content Type | Expected Result | Status |
|---|--------------|-----------------|--------|
| M3.6 | Normal desktop | Colors match | ☐ |
| M3.7 | YouTube (Chrome) | Colors match | ☐ |
| M3.8 | Netflix (Chrome, HW) | Black frames detected | ☐ |
| M3.9 | Netflix (Chrome, SW) | May show colors (check warning) | ☐ |
| M3.10 | Safari streaming | Black frames likely | ☐ |
| M3.11 | Prime Video (Chrome) | Black frames detected | ☐ |

### Chrome Software Rendering Test

```bash
# Launch Chrome with hardware acceleration disabled
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --disable-gpu \
  --disable-gpu-compositing \
  --disable-software-rasterizer=false
```

---

## Section 4: BLE LED Strip Control

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M4.1 | BLE Scan | App startup with strip on | Strip discovered | ☐ |
| M4.2 | Auto-connect | Strip in range | Auto-connects | ☐ |
| M4.3 | Power On | Click power button | Strip turns on | ☐ |
| M4.4 | Power Off | Click power button | Strip turns off | ☐ |
| M4.5 | Brightness | Adjust slider | Strip brightness changes | ☐ |
| M4.6 | Color | Select color | Strip color changes | ☐ |
| M4.7 | Effect | Select effect | Strip animates | ☐ |
| M4.8 | Effect Speed | Adjust speed | Animation speed changes | ☐ |
| M4.9 | Disconnect | Turn off strip | Connection lost shown | ☐ |
| M4.10 | Reconnect | Turn on strip | Auto-reconnects | ☐ |

---

## Section 5: Remote Input (Accessibility)

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M5.1 | Permission Request | First input command | Permission prompt | ☐ |
| M5.2 | Permission Denied | Deny Accessibility | Error shown | ☐ |
| M5.3 | Permission Granted | Grant Accessibility | Input works | ☐ |
| M5.4 | Mouse Move | Send from iPhone | Cursor moves | ☐ |
| M5.5 | Left Click | Send from iPhone | Click occurs | ☐ |
| M5.6 | Right Click | Send from iPhone | Context menu | ☐ |
| M5.7 | Scroll | Send from iPhone | Page scrolls | ☐ |
| M5.8 | Key Press | Send from iPhone | Key registered | ☐ |
| M5.9 | Text Input | Send from iPhone | Text appears | ☐ |

---

## Section 6: Metal GPU Analysis

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M6.1 | Metal Available | Check `MTLCreateSystemDefaultDevice()` | Device created | ☐ |
| M6.2 | Shader Compile | Enable video sync | No shader errors | ☐ |
| M6.3 | Histogram | Check debug output | Histogram generated | ☐ |
| M6.4 | Performance | Monitor CPU | <10% during sync | ☐ |

### Metal Verification

```bash
# Check Metal support
system_profiler SPDisplaysDataType | grep Metal

# Check GPU usage during sync
sudo powermetrics --samplers gpu_power
```

---

## Section 7: Widget

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M7.1 | Widget Available | Notification Center → Edit | LightStar widget available | ☐ |
| M7.2 | Widget Display | Add widget | Shows current state | ☐ |
| M7.3 | Widget Control | Tap widget button | Controls work | ☐ |
| M7.4 | Widget Update | Change state in app | Widget updates | ☐ |

---

## Section 8: Error Handling

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| M8.1 | BLE Unavailable | Disable Bluetooth | Error shown | ☐ |
| M8.2 | Strip Timeout | Move strip out of range | Timeout + error | ☐ |
| M8.3 | Capture Failure | Revoke Screen Recording | Error + fallback | ☐ |
| M8.4 | Network Error | Disable WiFi during session | Disconnect shown | ☐ |

---

## Section 9: Data Collection Script

Run this script to collect environment information before testing:

```bash
#!/bin/bash
echo "=== macOS Version ==="
sw_vers

echo "=== Hardware ==="
system_profiler SPHardwareDataType | grep -E "Model|Chip|Memory"

echo "=== GPU ==="
system_profiler SPDisplaysDataType | grep -E "Chipset|Metal|VRAM"

echo "=== Displays ==="
system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type"

echo "=== Permissions ==="
tccutil -v

echo "=== LightStar Build ==="
defaults read /Applications/LightStar.app/Contents/Info.plist CFBundleShortVersionString
```

---

## Test Results Summary

| Section | Total | Passed | Failed | Blocked |
|---------|-------|--------|--------|---------|
| Startup | 4 | ☐ | ☐ | ☐ |
| Remote Server | 4 | ☐ | ☐ | ☐ |
| Screen Capture | 11 | ☐ | ☐ | ☐ |
| BLE Control | 10 | ☐ | ☐ | ☐ |
| Remote Input | 9 | ☐ | ☐ | ☐ |
| Metal | 4 | ☐ | ☐ | ☐ |
| Widget | 4 | ☐ | ☐ | ☐ |
| Error Handling | 4 | ☐ | ☐ | ☐ |
| **TOTAL** | **50** | ☐ | ☐ | ☐ |

---

## Notes

- [ ] Tester name: ________________
- [ ] Date: ________________
- [ ] macOS version: ________________
- [ ] Xcode version: ________________
- [ ] LED strip model: ________________
- [ ] Issues found: ________________
