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
| `0x03` | Pixel count 16-bit BE, 8–300. Lowering it darkens everything past LED N (a length trim); too slow and maybe flash-backed, so never stream it |
| `0x04` | Static colour (hue LUT + sat 0–1000) |
| `0x05` | Brightness 16-bit BE **100–1000** |
| `0x06` | Effect select (58 IDs) |
| `0x07` | Effect direction |
| `0x08` | Effect speed (1 byte; range unconfirmed vs hardware) |
| `0x09` | Streaming colour |
| `0x0B` | Time sync (auto on connect): 16-bit year, weekday 1=Mon…7=Sun **after** the `0x55` trailer |
| `0x0D` | Firmware timer: one power-on + one power-off (byte 3 always `01`, byte 4 picks on/off) |
| `0x0F` | Strip onboard mic |
| `0x11` | Mic style 1–4 |
| `0x12` | Mic sensitivity 0–255 |
| `0x13` | White-tone wheel `BC 13 02 [hi] [lo] 55`, angle 0–360: 0 cool blue-white, 90 neutral, 180 warm amber (camera-verified). The 1-byte form LightStar's scene grid sends gives static colours, not animations |

GATT: advertised `0x2022`, service `FFF0`, write `FFF3` (Write + Write Without Response; OEM uses ATT Write Command / `withoutResponse`). Notify `FFF4` never fired on this strip, even for a `BC0C` timer query (camera test 2026-11-05), although the OEM Android app has parsers for `BC0D` timer, `05` brightness, `08` speed and `10` sensitivity replies. LightStar logs any reply as `RX` (subsystem `com.adityaraj.LightStar`, category `ble`).

All BLE writes go through `BLEWriteCoalescer.enqueue()`. Dedup key is `bytes[1]` (plus `bytes[4]` for `0x0D`, so the on- and off-timer both survive). Insertion-ordered, replace-in-place. One frame per 20 ms tick, except a colour (`0x04`/`0x09`) and the brightness (`0x05`) next to it go in the same tick when `canSendWriteWithoutResponse` says there's room.

The OEM apps (MR Star 1.0.0 Android, Symphony Light 1.1.1 iOS, decompiled 2026-11-05) have no per-pixel or per-segment command, and a sweep of every unused command byte (0x00, 0x0A, 0x0E, 0x14–0x20, 0x50) changed nothing on the strip. Screen-matched colour around the monitor needs a different controller (e.g. WLED). Phone-mic mode is `0x09` one colour every 200 ms; strip-mic patterns are drawn by the firmware.

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
  ProtectedContentPolicy.swift  DRM hold-last-color + guide-after-N tracker
  ScreenCaptureKitProvider.swift  SCK implementation (video frames only)
  ScreenColorSampler.swift      HSV callback; holds last color on protected frames
  CaptureDiagnostics.swift      Browser + HW-accel-off copy (timer only while capturing)
  
  # iPhone <-> Mac remote control
  RemoteProtocol.swift          Versioned binary protocol (JSON payloads)
  RemoteControlServer.swift     TCP server with Bonjour (macOS only)
  RemoteControlClient.swift     Bonjour discovery + pointer channel (no MainActor hop)
  MacPointerInjector.swift      CGEvent pointer path, Network-queue safe
  GyroPointerMath.swift         Air-pointer pose → mouse deltas (shared)
  MacInputController.swift      Keyboard/media CGEvent + pointerInjector (macOS only)
  LightBLEManager+Remote.swift  State snapshot + command handling

  # Alexa (Echo) via Hue emulation — macOS only
  AlexaHueBridge.swift          SSDP + Hue HTTP API; Mac remains BLE brain
  HueColorMapping.swift         Hue bri/hue/sat/ct ↔ LightStar 0…1 values

  # WiZ lightbar (Philips Gradient Floor Lamp) — see "WiZ Lightbar" below
  WizProtocol.swift             Pure: setPilot/elm encoding, RGB→RGBW split, flush, discovery, link health
  WizLampController.swift       macOS: multi-light UDP engine (one link per light), heartbeat, discovery
  LampGradient.swift            Pure: screen bands → zones, placement/trims, VU meter, spectrum, colour count
  LampEffect.swift              Pure: animated effects as frame(time:) functions; strip-effect mapping
  LightBLEManager+Lamp.swift    Effect runner (25 fps) and strip-effect follow

LightStar/              macOS app (menu bar + control window)
LightStariOS/           iOS remote (sideload)
LightStarWidget/        WidgetKit source shared by both widget extensions
```

Views get state via `@Environment(LightBLEManager.self)`. AppIntents use `LightStarRuntime`.

## Autonomous company

Single command: `./scripts/autonomous-company` (Cursor skill `/autonomous-company`).

This is a **Company Operating System** (work pool + workers + clock), not a one-task runner.
Architecture: `company/adr/0002-company-operating-system.md` (safety locks still in ADR 0001).
Durable state: `company/state/{company,work_pool,workers,memory,cadence}.json`.
Do not invent Swift validation on Linux agents; use CI.

If the company idles without shipping product work, see skill  
`.cursor/skills/autonomous-company-product-gap/` — Selected rows in `engineering-roadmap.md` must enter the work pool.

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

Both Info.plists must declare `NSLocalNetworkUsageDescription` and `NSBonjourServices = _lightstar._tcp`. The Mac plist also lists `_hap._tcp` so the bedside lamp can be found. Missing those produces `NWError -65555 NoAuth` on iOS 14+.

Messages are length-prefixed (4-byte big-endian) JSON:

| Type | Direction | Purpose |
|------|-----------|---------|
| `hello` | iPhone → Mac | Protocol version, device name |
| `helloAck` | Mac → iPhone | Accept/reject, pairing required |
| `stateUpdate` | Mac → iPhone | Full light state snapshot |
| `setPower`, `setBrightness`, etc. | iPhone → Mac | Light commands |
| `connectStrip`, `disconnectStrip`, `writeFrame` | iPhone → Mac | Use the Mac's BLE radio |
| `setOutputTarget`, `setLampCode` | iPhone → Mac | Choose LED strip, Mi lamp, or both, and pass the lamp code |
| `mouseMove`, `keyDown`, `macAction` | iPhone → Mac | Trackpad, typing, and Mac system actions |

The phone Lights tab shows that choice. Power for the strip waits until the strip is connected. Power for the lamp or both does not. One switch drives every selected light.

State to the phone is always `stateForClients()` (snapshot + system levels + lamp + lightbar): observation broadcasts and command replies alike. The bare `createStateSnapshot()` has no lamp/lightbar fields and hid those rows on every colour change. Broadcasts are throttled to 100 ms with a trailing send, so the last value of a drag always lands. The phone's sliders ignore incoming state while being dragged (`dragging`), or a late echo yanks the thumb back.

Two-finger scroll sends raw UIKit finger deltas. `MacInputController` maps them with `RemoteScrollMapping`: Natural scrolling ON (Mac default) posts the same polarity as the physical trackpad; Natural OFF inverts once. Do not invert again on iOS.

A three-finger slide switches Spaces (sideways) or opens Mission Control / App Exposé (up / down), once per gesture. The trackpad view turns off the system text-editing swipe so iOS does not cancel it. Control+arrow for that switch is posted with staggered event timestamps so Mission Control sees a real chord.

The on-screen wheel sits beside the trackpad, not on top of it. It sends a continuous pixel stream (`ScrollWheelTracking`: a slow drag stays precise, a flick raises the gain, then a short coast). Ridges spin with that speed. Camera Control cannot drive it: iOS only delivers those events to an app that is actively using the camera, and LightStar does not start a camera session to read the button.

Air pointer (iPhone gyro) reuses `mouseMove` deltas. Math lives in `GyroPointerMath.swift`. Add `NSMotionUsageDescription` on iOS.

### Alexa Echo (Hue bridge emulation)

macOS can expose a local Philips Hue API (`AlexaHueBridge`) so an Echo Dot discovers **LightStar** and sends on/off, brightness, HS colour, and CCT. LightStar stays the only BLE writer to the strip.

```
Echo Dot ──SSDP + Hue HTTP──► LightStar (port 9123)
                                   │
                                   ▼
                            LightBLEManager ──BLE──► BC/55 strip
```

Enable in Settings → **Echo Hue bridge**. UserDefaults key: `alexaHueBridgeEnabled`. Alexa app: Add Device → Philips Hue → Discover. Requires Local Network permission. Does not add PS5 HDMI sync; screen sync remains Mac ScreenCaptureKit.

### Mi Bedside Lamp 2 (Yeelight LAN)

Settings → **Follow the light bar**. The Mac copies each accepted strip colour, brightness, and power change to the lamp. The copy uses the app’s hue, not the strip hue LUT, and it never writes BLE. Connect-sequence power cycles are not copied, so pairing the bar does not blink the lamp. Mi Bedside Lamp 2 (`MJCTD02YL`) no longer has Yeelight LAN Control; it is paired once with the 8-digit HomeKit code on the lamp base (`HomeKitLampController`). The menu-bar picker `LightOutputTarget` (`lightOutputTarget`) chooses the LED strip, the Mi lamp, the lightbar, or all (`.both` keeps its raw value and reads "All"). "All" drives only the lights ticked under it (`allOutputLights`, `ble.allLights`; never empty, default all three); with 2+ WiZ lights each one is ticked there too (`wizEnabledLights`). The iPhone doesn't know the Mac's choice yet and treats All as every light. Only the chosen lights run and follow (`AppDelegate.mirrorToLamps`, `applyLampFollow`). HomeKit colour flushes about every 60 ms. A saved code (`homekitLampSetupCode`) is used as soon as the lamp is found. Other Yeelight bulbs that still answer SSDP use `YeelightLampController`. `yeelightMirrorEnabled` follows the picker. Pairing record: `homekitLampPairing`.

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
- `syncColor` is UI-only and throttled (`showLiveColor`: ≤5 Hz, only when the hue moves >1% or saturation >3%, trailing update so the last colour lands). Only small `LiveAccent` views read it; windows tint with `controlAccent` (the chosen colour). Reading the live colour in a window's body redrew the whole menu-bar popover — even closed — at 20–30 Hz, ~50–98% CPU during sync. Per-frame sync state (`flashLevel`, `beatHue`, `lastScreenH/S`, `audioPulseH`) is `@ObservationIgnored`.
- Recent colours record a colour only after it has stayed 0.6 s (`historyDebounce` in `setHue`): drags from the Mac sliders, the phone, or Alexa used to fill all 12 swatches with in-between hues.
- The focus/profile timer runs only while screen sync runs (started in `setupScreenCallback`, stopped at teardown).
- Frame analysis runs on the CPU (`useMetalAnalysis = false`): ~37 µs a frame at 48×27 vs ~409 µs for the Metal round trip.
- Combined mixer: Screen owns hue and writes streaming colour (`0x09`), not static `0x04`, so the bar does not fade each frame. Music Pulse (default) owns brightness. Both uses a **video-only** screen SCStream plus the same `SystemAudioSampler` as Music. Music Pulse on macOS 14.2+ is a **Core Audio process tap**, not a display `SCStream` — capturing the display for “audio-only” still puts Chrome in the capture set and Widevine blacks Netflix/Prime on the real screen. Tapping audio on the screen stream was silent, which made Both look like Screen on a static window. Slider is the brightness ceiling; quiet drops to `pulseFloor` (3%, same as Music Pulse); bass drives brightness continuously and beats add a brightness flash. Saturation is the screen's own; there is no saturation punch (EE-016: the unused helpers were deleted rather than wired, since punching saturation would mean extra colour writes per beat). The lightbar pulses with the same level between screen frames. Never Music rainbow. Switching modes always teardowns every sampler, nils callbacks, cancels fade, and sends `Cmd.stripMic(false)`.
- Combined always uses Mac system audio (`AudioInputSyncPolicy.effectiveSource`). Leftover `.mic` / `.stripMic` from the audio-only picker must not skip `setupAudioCallback` or re-enable firmware mic. Leaving `.stripMic` always sends `Cmd.stripMic(false)` even if `didSet` already changed the source.
- Live strip output (color, brightness, presets, sync, effects) requires connected **and** on (`StripCommandPolicy`). Power needs connected only. Schedules, Settings, and the iPhone Mac remote stay independent of strip power.
- Power-off must be the only pending BLE frame. Hue (`0x04`), brightness (`0x05`) and streaming (`0x09`) after `Cmd.powerOff` wake the BC/55. `setPower(on: false)` `flush()`es the coalescer and `sendNow`s powerOff (no 20ms wait), then repeats once after 200ms. FFF3 writes use `withoutResponse` when the characteristic supports it — `withResponse` stalls because firmware never sends an ATT Write Response, which is why disconnect/reconnect used to be the only way to turn the strip off. `write()` also refuses non-`0x01` commands while `isOn` is false.
- Hardened runtime (sandbox off) needs `com.apple.security.device.audio-input` for the macOS mic TCC prompt. `device.microphone` alone is the sandbox key and does not register LightStar in System Settings → Microphone.
- `MicAudioSampler` tap must use a handler created in non-isolated `TapCore.init`. A closure literal in `@MainActor start()` inherits MainActor even if it only captures Sendable state — `AVAudioNodeTapBlock` is not `@Sendable`, so the realtime queue SIGTRAPs (`_dispatch_assert_queue_fail`).
- Trackpad double-tap: first tap `clickCount` 1, second tap one down+up with `clickCount` 2 (`kCGMouseEventClickState`). Never emit extra singles for the second tap — YouTube/Safari ignore clickCount 1 storms.

---

## WiZ Lightbar (Philips Gradient Floor Lamp)

Philips sells it as "LightTheatre Wi-Fi Gradient Floor Lamp"; it is a WiZ gradient light (`ESP25_MHORGB_01`, fw 1.38.0). Local UDP on **38899**, compact JSON, no pairing. Local control must be allowed in the WiZ app.

### Protocol facts (verified on the device)

| Fact | Detail |
|------|--------|
| Discovery | Broadcast `getSystemConfig` → reply with `mac`, `moduleName`. |
| Shape | `getModelConfig` → `swHead: 18` addressable segments (`headTotal: 36` LEDs), `hasGradient: 1`. Philips' "7 colour segments" is marketing. Plain bulbs report `hasGradient: 0`. |
| Segments | `setPilot` with `sceneId` 256–265 (empty custom slot, default **258**) + `elm {modifier:100, support:17, steps}`. Step = `[0, R, G, B, warm, cool, 0, dimming, 0,0,0,0, width]`. |
| Step cap | **12 steps max**; 13+ returns `-32602 Invalid params` for any `support`. So ≤12 colours per frame. |
| White | Step index 4 = warm-white LEDs, 5 = cool; `w` / `c` in plain `setPilot`. |
| Dimming | 10…100. Power-off is `{"state": false}` only. |
| Readback | Never echoes `elm`; `success: true` means "parsed", not "shown". Verify by eye. |
| Rate | 30+ fps with no loss on a normal LAN. |

### Pipeline

- **Mirror:** strip colour/brightness/power → `onLampMirror` → `WizLampController.submit` (only when the lightbar is chosen). App hue, never the strip LUT.
- **Sync / effects:** `onLampZones(zones, placement?)` → `stream`. While streaming, mirrored colour/brightness are held back (power still follows); `stream(nil)` hands the light back. Effects and sync stop each other; a plain colour, scene, or segment colours stop an effect.
- **Off the main thread:** lit screen frames go from the capture queue through `LampZonePipe` (smoother, boost, profile, brightness; lock-guarded) to `WizLampController.streamFrame` without touching the main thread. The main thread only keeps the pipe's `Settings` current (observation on power, brightness, mode, responsiveness, lights) and pushes repaints and black frames the DRM guard lets through. `update { active = false }` must come before `onLampZones(nil)`: the pipe sends under its lock, so no in-flight frame lands after the lightbar is handed back. Frame gates are 1/45 s, not 1/30: at exactly the capture gap, jitter dropped or delayed every other frame.
- **Screen sync:** `ScreenCaptureKitProvider` keeps the latest 48×27 frame (`LampFrameStore`) and computes zones per frame: dominant hue per band (strip's histogram, mean hue of the winning bin), brightest pixels of that colour, black bands (<10% mean) off, greys neutral. Orientation, flip, and per-end trims (`Placement`) apply here. `Edge` limits reading to the screen edge beside the bar (left/right for vertical, top/bottom for horizontal, `edgeDepth` 10–50%). Black bars (`blackBars`: matching dark rows/columns, ≤45%, never an all-black frame) are skipped once `BarsTracker` sees them 10 frames running. Capture runs at 30 Hz for the lightbar; the strip's writes stay gated at 20 Hz; `colourCount` = 12, minus one per dark end, never more than lit segments. Any `UserDefaults` change repaints from the cached frame (ScreenCaptureKit sends no frames on a still screen).
- **Encoding:** `WizMode.gradient(colors, placement)` → per light: widths for its own segment count, zero-width steps **dropped before** the 12-step check, `WizChannels` puts `min(R,G,B)` on the white LEDs (only when it's ≥¼ of the peak — strong colours stay pure) and brightness in `dimming`.
- **Music:** level meter (`VUMeter`) or spectrum (bass at base → treble at top), with `BeatFlash` (a white flash running up from the base on each beat, `lightbarBeatFlash`, default on). Combined pulses the cached screen zones at `combinedBrightness`.
- **Colour boost:** `LampGradient.boosted` (`lightbarColourBoost`, 0 = off) raises saturation on screen zones and bulb sides, keeping hue and peak; greys/whites (<10% saturation) are untouched.
- **App profiles (`LightbarProfile`):** while screen sync runs, the focus timer reads the front app (bundle ID + `LSApplicationCategoryType`) and writes `lightbarActiveProfile`: video players → video (black bars always skipped), games category → game (whole screen, no easing). Browsers stay normal. **Every profile keeps the screen gradient** (user requirement): a "work light" profile that swapped sync for one white was removed after it made the bar single-colour whenever Claude (developer-tools category) was in front. Per-app overrides in Settings (`lightbarAppProfileOverrides`, recent apps in `lightbarRecentApps`); master switch `lightbarAppProfiles` (default on). `LampGradient.edge`/`ignoreBars` read the active profile, so a switch repaints from the cached frame.
- **Bulb sides:** a plain WiZ bulb can stand left/right/above/below the screen (`wizLightSides`, `[mac: side]`); in screen sync it shows that edge (`LampGradient.sideColours`, `onLampSides` → `WizLampController.streamSides`) instead of the lightbar's average.
- **Day-cycle white:** `lightbarDayWhite` (default off) replaces mirrored strip colour on WiZ lights with `LampGradient.dayWhite` (2700–6500 K via `circadianCCTValue`), refreshed every minute unless a scene or effect is on.
- **Away:** `lightbarOffWhenAway` (default on) turns every WiZ light off while screens sleep, the Mac sleeps, the screen is locked, or the screensaver runs (`AppDelegate.setAway`, a set of reasons so one ending doesn't wake them early), then resends power and colour.
- **Effects:** `LampEffect` motions flow / chase / fade / openClose / sparkle / fire; picking a strip effect runs `LampEffect.matching` (group → motion, name → colours). Shared speed and direction with the strip; custom palette in Settings.

### Engine (`WizEngine`)

One link per enabled light: its own `sent`, segment count, heartbeat. Only the lightbar already in use (`wizLampMAC`) is driven until the user switches others on (`wizEnabledLights`). Plain bulbs get one colour (`WizMode.flattened`). Heartbeat (`WizLink`): resend unanswered after 0.5 s, ping after 3 s quiet, drop after 8 s silence; re-discovery every 30 s.

### Gotchas (each cost a debugging round)

- **Launch:** macOS refuses the app's first UDP packets with `errno 65 No route to host` for ~300 ms while the Local Network check settles. Discovery probes 6× over 2 s; all-refused → `.blocked` (Local Network off), not "not found".
- **Zero-width steps:** 12 colours + 2 empty dark ends = 14 entries → refused → nothing sent. Filter before validating.
- **Testing against the device:** quit LightStar first. A running app keeps streaming and overwrites whatever a test sends, which looks exactly like a firmware bug.
- **Rounding:** a half-lit bar meant the segment count was wrong — read `swHead`, never assume.

### Settings keys

`lightbarOrientation`, `lightbarFlipped`, `lightbarEdge`, `lightbarColourBoost`, `lightbarBeatFlash`, `lightbarDayWhite`, `lightbarOffWhenAway`, `lightbarAppProfiles`, `lightbarAppProfileOverrides`, `lightbarActiveProfile`, `lightbarRecentApps`, `wizLightSides`, `allOutputLights`, `lightbarEdgeDepth`, `lightbarIgnoreBars`, `lightbarTrimStart`, `lightbarTrimEnd`, `lampGradientSync`, `lightbarMusicStyle`, `lightbarWhiteTone`, `lightbarEffectCustomColours`, `lightbarEffectPalette`, `wizSegmentCount`, `wizSegmentWidths`, `wizSegmentSlot`, `wizLampMAC`, `wizLampHost`, `wizLightHosts`, `wizEnabledLights`. Presets store `LightbarLook` (effect + optional palette, scene, or segments) — Optional, like every new `Preset` field.

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

### Follow the active screen

With 2+ displays, screen sync follows the screen in use by default (`FocusedDisplay.followDefaultsKey`, switch in the sync section); each switch logs to category `focus`. `LightBLEManager.startFollowingFocus` ticks at 2 Hz: it takes the frontmost app's front layer-0 window from `CGWindowListCopyWindowInfo` (LightStar's own popover ignored), picks the display with the largest overlap (`FocusedDisplay.display`), and `FocusDebouncer` switches `selectedDisplayID` only after 1.5 s on the same display. Window focus, not the mouse pointer: the pointer drifts while a film plays.

### DRM-Protected Content

See `docs/display-capture-research.md` for full research. Summary:

| Content | Browser | HW Accel | Capturable |
|---------|---------|----------|------------|
| Normal desktop | N/A | N/A | ✅ Yes |
| YouTube | Any | Any | ✅ Yes |
| Netflix | Chrome | ON | ❌ Black |
| Netflix | Chrome | OFF | ✅ Yes (1080p max) |
| Netflix | Safari | N/A | ❌ Always black |

**Product path** (do not attempt WindowServer/IOSurface/private APIs, virtual displays, or HDCP bypass):

1. Persistent rectangular black frames (`ProtectedContentPolicy`) **hold last good HSV + brightness**. They must not write near-black to the strip. Combined still pulses brightness from the Music audio sampler. The **lightbar** is the exception: a held frame with anything visible (a logo on black, the Netflix intro) is still painted, black zones off; only an all-black frame is held (`LampGradient.shouldPaint`). Don't loosen the strip's rule — Netflix's red scrubber would recolour it during DRM playback.
2. After `confirmationFrameCount` consecutive protected frames, the Mac popover shows the hardware-acceleration-off guide (Chrome/Edge/Brave). Safari / native apps / HW-on Chrome stay black — say so. Dark IDE chrome (VS Code) is not a DRM rectangle and must not trip the guide.
3. One tracker: `ProtectedContentTracker` in `ScreenColorSampler`. `CaptureDiagnostics` only supplies browser + copy. Do not start its 2s frontmost-app Timer unless Screen/Both is running. No `print()`.
4. **Chromium Local State toggle** (user-requested): when the strip is on, Screen/Both is running, protected frames are detected, **and** the Chromium tab or window is Netflix or Prime Video, LightStar **Apple-Event quits** Chrome/Edge/Brave (never `forceTerminate` — that drops tabs), waits for session files, patches only `hardware_acceleration_mode.enabled` in `Local State` (do not JSON-round-trip the whole file), then relaunches with `--restore-last-session`. Other DRM and ordinary black frames do not restart the browser. Restore the previous value when leaving Screen/Both, powering off, or quitting LightStar. Do this once per Screen session (no relaunch loop). Safari is not touched. Skip all process control under XCTest.
5. **Music Pulse must not capture a display.** System audio goes through a HAL process tap (`SystemAudioProcessTap`). A dummy 2×2 `SCStream` on the display still counts as screen sharing to Widevine.

**DRM-impossible (do not loop on this):** Widevine L1 / FairPlay with hardware acceleration on never puts movie pixels in ScreenCaptureKit. Software-rendered L3 (HW accel off) is the only capturable Chromium path; Safari has none. LightStar automates the Chromium pref + relaunch; it does not patch Widevine or bypass `preventsCapture`.

A GPU/HDMI/DisplayPort **driver** also cannot see those pixels (DCP + WindowServer + HDCP). Background scripts still need Screen Recording. Do not wire `Experimental/DirectCapture/` into the app (`ENABLED=0`, not in `project.yml`).

---

## Conventions

- Comments explain non-obvious **why**. No multi-line docstrings.
- A new `Cmd` builder must be added to `allFrames` in `LightStarCore/Tests`.
- Lightbar changes: pure logic goes in `WizProtocol` / `LampGradient` / `LampEffect` with a unit test; then check on the device by eye (`success` replies prove nothing). `FrameAnalysisParityTests` only runs under `xcodebuild test` (SwiftPM's CLI doesn't build the Metal shader).
- Recalibration procedure for the hue LUT: sweep 10° steps, fixed WB/exposure, keep `obs` strictly increasing.
