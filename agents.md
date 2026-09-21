# LightStar — AI Development Knowledge Base

> Update this file when architecture, protocols, or conventions change.
> AI agents should read this before editing any file.

---

## Project Overview

macOS menu-bar app (LSUIElement, no Dock icon) plus a sideloaded iOS remote, controlling a BC/55 BLE RGB LED bar. Replaces the "Miracles Star" OEM app.

- **Platforms**: macOS 14.0+, iOS 17+, Swift 6, strict concurrency
- **Shared core**: `LightStarCore` Swift package (protocol, LUT, coalescer, BLE manager, presets, schedules)
- **macOS extras**: ScreenCaptureKit ambilight, system-audio FFT, Carbon hotkeys, menu bar, control window
- **iOS extras**: remote control, mic/strip-mic sync, AppIntents, widget, BC0D firmware timers
- **Build**: `xcodegen generate` then `xcodebuild -scheme LightStar`
- **Do not rewrite in Tauri.** TCC, AppIntents, WidgetKit and ScreenCaptureKit are Apple-framework problems.

---

## BLE Protocol (BC/55)

Frame format: `BC [cmd] [data_len] [data × data_len] 55`. Invariant: `bytes[2] == bytes.count - 4`.

| Cmd | Function |
|-----|----------|
| `0x01` | Power on/off |
| `0x02` | Channel order 1=RGB…6=BGR |
| `0x03` | Pixel count 16-bit BE, 8–300 |
| `0x04` | Static colour (hue LUT + sat 0–1000) |
| `0x05` | Brightness 16-bit BE **100–1000** |
| `0x06` | Effect select (58 IDs) |
| `0x07` | Effect direction |
| `0x08` | Effect speed (1 byte; range unconfirmed vs hardware) |
| `0x09` | Streaming colour |
| `0x0B` | Time sync (auto on connect) |
| `0x0D` | Weekly firmware timer |
| `0x0F` | Strip onboard mic |
| `0x11` | Mic style 1–4 |
| `0x12` | Mic sensitivity 0–255 |
| `0x13` | Animation scene |

GATT: advertised `0x2022`, service `FFF0`, write `FFF3` (Write + Write Without Response; OEM uses ATT Write Command / `withoutResponse`). Notify `FFF4` (never fires).

All BLE writes go through `BLEWriteCoalescer.enqueue()`. Dedup key is `bytes[1]`. Insertion-ordered, replace-in-place.

Hue LUT lives in `ColorMath.hueLUT` — do not regenerate casually.

---

## Architecture

```
LightStarCore/          Swift package, macOS + iOS
  ColorMath.swift       hue LUT, kelvinToHS, circadian
  BLEProtocol.swift     Cmd builders + effects table
  BLEWriteCoalescer.swift
  LightBLEManager*.swift
  Preset / Schedule stores
  WidgetState.swift     App Group JSON
  CaptureStubs.swift    iOS stand-ins for SCStream types
  
  # Screen capture provider architecture
  ScreenFrameProvider.swift     Provider protocol + analysis types
  ScreenCaptureKitProvider.swift  SCK implementation with protected content detection
  ScreenColorSampler.swift      Wrapper with legacy HSV callback API
  
  # iPhone <-> Mac remote control
  RemoteProtocol.swift          Versioned binary protocol (JSON payloads)
  RemoteControlServer.swift     TCP server with Bonjour (macOS only)
  RemoteControlClient.swift     Bonjour discovery + pointer channel (no MainActor hop)
  MacPointerInjector.swift      CGEvent pointer path, Network-queue safe
  GyroPointerMath.swift         Air-pointer pose → mouse deltas (shared)
  MacInputController.swift      Keyboard/media CGEvent + pointerInjector (macOS only)
  LightBLEManager+Remote.swift  State snapshot + command handling

LightStar/              macOS app (menu bar + control window)
LightStariOS/           iOS remote (sideload)
LightStarWidget/        WidgetKit source shared by both widget extensions
```

Views get state via `@Environment(LightBLEManager.self)`. AppIntents use `LightStarRuntime`.

---

## iPhone <-> Mac Remote Control

The iOS app never talks to the strip over Bluetooth. It finds the Mac on the local network; the Mac owns the BLE link.

```
┌─────────────────────────────────────────────┐
│                  iPhone                     │
│  RemoteControlClient (Bonjour discovery)    │
│  LightBLEManager (remote transport)         │
│  RemoteControlView / TrackpadView / etc.    │
└──────────────────┬──────────────────────────┘
                   │ TCP + JSON (port 19384)
                   ▼
┌─────────────────────────────────────────────┐
│                   Mac                       │
│  RemoteControlServer (NWListener Bonjour)   │
│  RemoteControlCoordinator                   │
│  MacInputController (CGEvent)               │
│  LightBLEManager → LED Strip (laptop BLE)   │
└─────────────────────────────────────────────┘
```

### Protocol

Service type: `_lightstar._tcp`, port `19384`.

Both Info.plists must declare `NSLocalNetworkUsageDescription` and `NSBonjourServices = _lightstar._tcp`. Missing those produces `NWError -65555 NoAuth` on iOS 14+.

Messages are length-prefixed (4-byte big-endian) JSON:

| Type | Direction | Purpose |
|------|-----------|---------|
| `hello` | iPhone → Mac | Protocol version, device name |
| `helloAck` | Mac → iPhone | Accept/reject, pairing required |
| `stateUpdate` | Mac → iPhone | Full light state snapshot |
| `setPower`, `setBrightness`, etc. | iPhone → Mac | Light commands |
| `connectStrip`, `disconnectStrip`, `writeFrame` | iPhone → Mac | Use the Mac's BLE radio |
| `mouseMove`, `keyDown`, `macAction` | iPhone → Mac | Trackpad, typing, and Mac system actions |

Two-finger scroll sends raw UIKit finger deltas. `MacInputController` maps them with `RemoteScrollMapping`: Natural scrolling ON (Mac default) posts the same polarity as the physical trackpad; Natural OFF inverts once. Do not invert again on iOS.

Air pointer (iPhone gyro) reuses `mouseMove` deltas. Math lives in `GyroPointerMath.swift`. Add `NSMotionUsageDescription` on iOS.

### Permissions

Mac requires:
- **Accessibility** for CGEvent input control
- **Screen Recording** for display capture (existing)
- **Local Network** for Bonjour (`NSLocalNetworkUsageDescription` + `NSBonjourServices`)

iPhone requires:
- **Local Network** for Bonjour (prompted on first discovery)
- **Motion** usage string (`NSMotionUsageDescription`) for Air pointer; CoreMotion IMU does not prompt

### Usage

1. Mac app starts `RemoteControlServer` on launch (default enabled)
2. iPhone `connect()` discovers the Mac and asks it to connect the strip
3. Optional pairing code if `requirePairing` is set
4. State syncs automatically; BLE writes relay through Mac to the LED strip

### Key invariants

- New fields on `Preset` or `LightSchedule` must be `Optional`.
- No `try?` around `Task.sleep` in fade/power-cycle loops.
- Corrupt stores are quarantined in later hardening; current stores decode-fail closed.
- `lastFiredAt` is stamped `.now` at schedule creation so catch-up cannot fire for a time that passed before the schedule existed.
- Do not auto-off Music or Combined on silence. Quiet passages and delayed play are normal; the user turns sync off.
- `connectionError` is cleared when `connectionState` becomes `.connected`.
- `.connecting` has a 10s timeout so wake-from-sleep can self-heal.
- User disconnect is `userInitiatedDisconnect`, not `reconnectAttempts == max`.
- Pointer path stays off MainActor: iOS `PointerChannel` on the NW queue, Mac `MacPointerInjector` on the listener queue. TCP uses `noDelay` + `serviceClass = .signaling`. Pointer move/scroll uses 13-byte binary frames (`0xB1`) with `.idempotent` send; JSON stays for clicks and everything else.
- Combined mixer: Screen owns hue; Music Pulse (default) owns brightness. Both uses a **video-only** screen SCStream plus the same **audio-only** `SystemAudioSampler` as Music — tapping audio on the screen stream was silent, which made Both look like Screen on a static window. Slider is the brightness ceiling; quiet drops to `pulseFloor` (3%, same as Music Pulse); bass drives brightness continuously (beats only punch saturation). Never Music rainbow. Switching modes always teardowns every sampler, nils callbacks, cancels fade, and sends `Cmd.stripMic(false)`.
- Combined always uses Mac system audio (`AudioInputSyncPolicy.effectiveSource`). Leftover `.mic` / `.stripMic` from the audio-only picker must not skip `setupAudioCallback` or re-enable firmware mic. Leaving `.stripMic` always sends `Cmd.stripMic(false)` even if `didSet` already changed the source.
- Live strip output (color, brightness, presets, sync, effects) requires connected **and** on (`StripCommandPolicy`). Power needs connected only. Schedules, Settings, and the iPhone Mac remote stay independent of strip power.
- Power-off must be the only pending BLE frame. Hue (`0x04`), brightness (`0x05`) and streaming (`0x09`) after `Cmd.powerOff` wake the BC/55. `setPower(on: false)` `flush()`es the coalescer and `sendNow`s powerOff (no 20ms wait), then repeats once after 200ms. FFF3 writes use `withoutResponse` when the characteristic supports it — `withResponse` stalls because firmware never sends an ATT Write Response, which is why disconnect/reconnect used to be the only way to turn the strip off. `write()` also refuses non-`0x01` commands while `isOn` is false.
- Hardened runtime (sandbox off) needs `com.apple.security.device.audio-input` for the macOS mic TCC prompt. `device.microphone` alone is the sandbox key and does not register LightStar in System Settings → Microphone.
- `MicAudioSampler` tap must use a handler created in non-isolated `TapCore.init`. A closure literal in `@MainActor start()` inherits MainActor even if it only captures Sendable state — `AVAudioNodeTapBlock` is not `@Sendable`, so the realtime queue SIGTRAPs (`_dispatch_assert_queue_fail`).
- Trackpad double-tap: first tap `clickCount` 1, second tap one down+up with `clickCount` 2 (`kCGMouseEventClickState`). Never emit extra singles for the second tap — YouTube/Safari ignore clickCount 1 storms.

---

## Signing / distribution

- `project.yml` is the source of truth. `LightStar.xcodeproj` is generated and gitignored.
- Release tags are `vX.Y.Z`. CI (`release.yml`) archives only on those tags, using the tag name (not `build-N-sha`).
- Prefer **one** Developer ID identity for local and CI so TCC grants survive updates.
- `scripts/notarize.sh` archives, codesign-verifies, notarizes, staples, *then* `spctl`. Never `spctl` a not-yet-notarized app.
- `.github/install-lightstar.command` must not `tccutil reset` and must not delete `/Applications/LightStar.app` before the new copy verifies.

---

## Screen Capture Provider Architecture

Screen capture is abstracted through `ScreenFrameProvider` protocol:

```swift
protocol ScreenFrameProvider {
    var onFrame: ((FrameAnalysis) -> Void)? { get set }
    var selectedDisplayID: CGDirectDisplayID? { get set }
    var isRunning: Bool { get }
    func start() async throws
    func stop() async
}
```

`FrameAnalysis` includes:
- `dominantHue`, `dominantSaturation`, `dominantBrightness` — HSV in 0-1 range
- `blackPixelPercentage` — for protected content detection
- `suspectedProtectedContent` — true if persistent black region detected

### DRM-Protected Content

See `docs/display-capture-research.md` for full research. Summary:

| Content | Browser | HW Accel | Capturable |
|---------|---------|----------|------------|
| Normal desktop | N/A | N/A | ✅ Yes |
| YouTube | Any | Any | ✅ Yes |
| Netflix | Chrome | ON | ❌ Black |
| Netflix | Chrome | OFF | ✅ Yes (1080p max) |
| Netflix | Safari | N/A | ❌ Always black |

**Recommended approach**: Detect black regions, show user-friendly diagnostic suggesting Chrome hardware acceleration off.

---

## Conventions

- Comments explain non-obvious **why**. No multi-line docstrings.
- A new `Cmd` builder must be added to `allFrames` in `LightStarCore/Tests`.
- Recalibration procedure for the hue LUT: sweep 10° steps, fixed WB/exposure, keep `obs` strictly increasing.
