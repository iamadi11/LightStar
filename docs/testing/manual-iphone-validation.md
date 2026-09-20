# LightStar iPhone Manual Validation Checklist

> Status: CHECKLIST_READY
> Requires: iPhone running iOS 17+, Mac with LightStar running

---

## Prerequisites

Before running manual validation:

1. **Install App on iPhone**
   ```bash
   cd /workspace
   xcodegen generate
   # Open LightStar.xcodeproj in Xcode
   # Select LightStariOS scheme
   # Select your iPhone device
   # Run (⌘R)
   ```

2. **Ensure Mac is Ready**
   - LightStar running on Mac
   - Same WiFi network as iPhone
   - BLE LED strip connected (optional)

---

## Section 1: App Launch

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I1.1 | App Launch | Tap app icon | Discovery screen shown | ☐ |
| I1.2 | Permission - Network | First launch | Local Network permission prompt | ☐ |
| I1.3 | Network Denied | Deny permission | Error explaining requirement | ☐ |
| I1.4 | Network Granted | Grant permission | Discovery starts | ☐ |
| I1.5 | Cold Start | Force quit, relaunch | State restored | ☐ |

---

## Section 2: Mac Discovery

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I2.1 | Auto-Discovery | Mac running, same network | Mac appears in list | ☐ |
| I2.2 | Multiple Macs | Multiple Macs running | All listed | ☐ |
| I2.3 | Mac Disappears | Quit Mac app | Mac removed from list | ☐ |
| I2.4 | Network Switch | Change WiFi networks | Discovery adapts | ☐ |
| I2.5 | Refresh | Pull to refresh | List updates | ☐ |

---

## Section 3: Pairing Flow

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I3.1 | Initiate Pairing | Tap discovered Mac | Pairing code prompt | ☐ |
| I3.2 | Mac Shows Code | Pairing initiated | Code visible on Mac | ☐ |
| I3.3 | Correct Code | Enter displayed code | Pairing succeeds | ☐ |
| I3.4 | Wrong Code | Enter wrong code | Error shown, retry allowed | ☐ |
| I3.5 | Repeated Wrong | 3+ wrong codes | Rate limit message | ☐ |
| I3.6 | Code Timeout | Wait >2 min, try old code | Expired error | ☐ |
| I3.7 | Cancel Pairing | Tap Cancel | Returns to discovery | ☐ |

---

## Section 4: Connected State

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I4.1 | Connected UI | After pairing | Control UI shown | ☐ |
| I4.2 | State Sync | Mac has existing state | iPhone shows same state | ☐ |
| I4.3 | BLE Status | Mac connected to strip | "Connected" indicator | ☐ |
| I4.4 | BLE Disconnected | Strip off | "Not Connected" indicator | ☐ |
| I4.5 | Disconnect Button | Tap disconnect | Returns to discovery | ☐ |

---

## Section 5: Lighting Controls

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I5.1 | Power Toggle | Tap power button | Strip turns on/off | ☐ |
| I5.2 | Power Feedback | Toggle power | Button state updates | ☐ |
| I5.3 | Brightness Slider | Drag brightness | Strip brightness changes | ☐ |
| I5.4 | Brightness Instant | Quick drag | Smooth, responsive | ☐ |
| I5.5 | Color Picker | Select color | Strip color changes | ☐ |
| I5.6 | Color Wheel | Rotate wheel | Hue changes | ☐ |
| I5.7 | Saturation | Adjust saturation | Color intensity changes | ☐ |
| I5.8 | Presets | Tap preset | Color/brightness applied | ☐ |

---

## Section 6: Effect Controls

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I6.1 | Effect List | Open effects | All effects listed | ☐ |
| I6.2 | Select Effect | Tap effect | Animation starts | ☐ |
| I6.3 | Effect Speed | Adjust speed slider | Animation speed changes | ☐ |
| I6.4 | Effect Direction | Toggle direction | Animation reverses | ☐ |
| I6.5 | Static Color | Exit effect mode | Returns to static color | ☐ |

---

## Section 7: Sync Mode Controls

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I7.1 | Sync Mode Picker | Open sync options | Modes listed | ☐ |
| I7.2 | Video Sync | Select Video | Mac starts capture | ☐ |
| I7.3 | Audio Sync | Select Audio | Mac starts audio analysis | ☐ |
| I7.4 | Combined Sync | Select Both | Both active | ☐ |
| I7.5 | Sync Off | Select Off | Sync stops | ☐ |
| I7.6 | Display Picker | Multiple displays | Can select display | ☐ |

---

## Section 8: Remote Trackpad

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I8.1 | Open Trackpad | Tap trackpad icon | Trackpad view shown | ☐ |
| I8.2 | Move Cursor | Swipe on trackpad | Mac cursor moves | ☐ |
| I8.3 | Move Sensitivity | Different swipe speeds | Proportional movement | ☐ |
| I8.4 | Left Click | Tap trackpad | Left click on Mac | ☐ |
| I8.5 | Double Click | Double-tap | Double-click on Mac | ☐ |
| I8.6 | Right Click | Two-finger tap | Context menu on Mac | ☐ |
| I8.7 | Drag | Long press + move | Drag operation on Mac | ☐ |
| I8.8 | Scroll | Two-finger swipe | Page scrolls on Mac | ☐ |
| I8.9 | Scroll Direction | Scroll down | Page scrolls down | ☐ |
| I8.10 | Zoom | Pinch gesture | Zoom (if supported) | ☐ |

---

## Section 9: Remote Keyboard

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I9.1 | Open Keyboard | Tap keyboard icon | Keyboard appears | ☐ |
| I9.2 | Type Letter | Press 'A' | 'A' appears in Mac text field | ☐ |
| I9.3 | Type Numbers | Press numbers | Numbers appear | ☐ |
| I9.4 | Shift | Shift + letter | Uppercase letter | ☐ |
| I9.5 | Caps Lock | Double-tap shift | Caps lock mode | ☐ |
| I9.6 | Backspace | Press delete | Character deleted | ☐ |
| I9.7 | Return | Press return | New line/submit | ☐ |
| I9.8 | Special Chars | Type @#$% | Special chars appear | ☐ |
| I9.9 | Cmd Modifier | Cmd + C | Copy on Mac | ☐ |
| I9.10 | Cmd + V | Cmd + V | Paste on Mac | ☐ |
| I9.11 | Cmd + Z | Cmd + Z | Undo on Mac | ☐ |
| I9.12 | Emoji | Emoji keyboard | Emoji appears | ☐ |

---

## Section 10: Media Keys

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I10.1 | Play/Pause | Press play | Mac media toggles | ☐ |
| I10.2 | Next Track | Press next | Mac skips track | ☐ |
| I10.3 | Previous Track | Press previous | Mac goes back | ☐ |
| I10.4 | Volume Up | Press vol up | Mac volume increases | ☐ |
| I10.5 | Volume Down | Press vol down | Mac volume decreases | ☐ |
| I10.6 | Mute | Press mute | Mac mutes | ☐ |

---

## Section 11: Connection Resilience

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I11.1 | WiFi Loss | Disable WiFi briefly | Disconnected state | ☐ |
| I11.2 | WiFi Restore | Re-enable WiFi | Can reconnect | ☐ |
| I11.3 | Mac Quit | Quit Mac app | Disconnected state | ☐ |
| I11.4 | Mac Restart | Restart Mac app | Can reconnect | ☐ |
| I11.5 | App Background | Background iPhone app | Connection maintained | ☐ |
| I11.6 | App Foreground | Return to app | State current | ☐ |
| I11.7 | Lock Screen | Lock iPhone | Connection state TBD | ☐ |

---

## Section 12: Error States

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I12.1 | No Network | Disable WiFi | Error UI shown | ☐ |
| I12.2 | Mac Unreachable | Mac on different network | Timeout + error | ☐ |
| I12.3 | Session Expired | Wait for session timeout | Re-pair required | ☐ |
| I12.4 | BLE Disconnected | Mac loses strip | UI shows BLE status | ☐ |

---

## Section 13: Widget (iOS)

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I13.1 | Widget Available | Widget gallery | LightStar widget available | ☐ |
| I13.2 | Widget Display | Add to home screen | Shows current state | ☐ |
| I13.3 | Widget Control | Tap widget | Toggles power (if connected) | ☐ |

---

## Test Results Summary

| Section | Total | Passed | Failed | Blocked |
|---------|-------|--------|--------|---------|
| App Launch | 5 | ☐ | ☐ | ☐ |
| Discovery | 5 | ☐ | ☐ | ☐ |
| Pairing | 7 | ☐ | ☐ | ☐ |
| Connected State | 5 | ☐ | ☐ | ☐ |
| Lighting | 8 | ☐ | ☐ | ☐ |
| Effects | 5 | ☐ | ☐ | ☐ |
| Sync Mode | 6 | ☐ | ☐ | ☐ |
| Trackpad | 10 | ☐ | ☐ | ☐ |
| Keyboard | 12 | ☐ | ☐ | ☐ |
| Media Keys | 6 | ☐ | ☐ | ☐ |
| Resilience | 7 | ☐ | ☐ | ☐ |
| Error States | 4 | ☐ | ☐ | ☐ |
| Widget | 3 | ☐ | ☐ | ☐ |
| **TOTAL** | **83** | ☐ | ☐ | ☐ |

---

## Notes

- [ ] Tester name: ________________
- [ ] Date: ________________
- [ ] iPhone model: ________________
- [ ] iOS version: ________________
- [ ] Mac model: ________________
- [ ] LightStar Mac version: ________________
- [ ] LightStar iOS version: ________________
- [ ] Issues found: ________________

---

## Section 14: New Features (Bug Fixes Validation)

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I14.1 | Wake Mac Button | Mac locked, tap Wake Mac | Mac display wakes | ☐ |
| I14.2 | Wake Mac Sleep | Mac sleeping, tap Wake Mac | Mac wakes (if app running) | ☐ |
| I14.3 | Connect Strip | Strip disconnected, tap Connect | BLE connection initiated | ☐ |
| I14.4 | Reconnect Strip | Strip connected, tap Reconnect | Force reconnection works | ☐ |
| I14.5 | Volume HUD Reset | Disconnect/reconnect | Volume HUD starts at 50% | ☐ |
| I14.6 | Brightness HUD Reset | Disconnect/reconnect | Brightness HUD starts at 50% | ☐ |
| I14.7 | Pairing Cancel Clear | Cancel pairing, retry | Code field is empty | ☐ |
| I14.8 | Error Message Visible | Connection rejected | Error message shown (not "Disconnected") | ☐ |
| I14.9 | Gyro Pointer Smooth | Use Air pointer | No jitter, smooth movement | ☐ |
| I14.10 | Hint Messages | Disconnected state | Helpful hint text visible | ☐ |

---

## Section 15: Security Validation

| # | Test | Steps | Expected | Status |
|---|------|-------|----------|--------|
| I15.1 | Pairing Code Display | Initiate pairing | 4-digit code shown on Mac | ☐ |
| I15.2 | Correct Code Required | Enter displayed code | Pairing succeeds | ☐ |
| I15.3 | Wrong Code Rejected | Enter wrong code | "Invalid pairing code" error | ☐ |
| I15.4 | Code Expires | Wait >60s, enter old code | Code expired/invalid | ☐ |
| I15.5 | Brute Force Protected | Try random codes | Cannot guess code easily | ☐ |
