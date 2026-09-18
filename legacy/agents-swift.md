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

GATT: advertised `0x2022`, service `FFF0`, write `FFF3` (with response), notify `FFF4` (never fires).

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

LightStar/              macOS app (menu bar + control window)
LightStariOS/           iOS remote (sideload)
LightStarWidget/        WidgetKit source shared by both widget extensions
```

Views get state via `@Environment(LightBLEManager.self)`. AppIntents use `LightStarRuntime`.

### Key invariants

- New fields on `Preset` or `LightSchedule` must be `Optional`.
- No `try?` around `Task.sleep` in fade/power-cycle loops.
- Corrupt stores are quarantined in later hardening; current stores decode-fail closed.
- `lastFiredAt` is stamped `.now` at schedule creation so catch-up cannot fire for a time that passed before the schedule existed.
- Silence auto-off applies to `.audio` only — never `.combined`.
- `connectionError` is cleared when `connectionState` becomes `.connected`.
- `.connecting` has a 10s timeout so wake-from-sleep can self-heal.
- User disconnect is `userInitiatedDisconnect`, not `reconnectAttempts == max`.

---

## Signing / distribution

- `project.yml` is the source of truth. `LightStar.xcodeproj` is generated and gitignored.
- Release tags are `vX.Y.Z`. CI (`release.yml`) archives only on those tags, using the tag name (not `build-N-sha`).
- Prefer **one** Developer ID identity for local and CI so TCC grants survive updates.
- `scripts/notarize.sh` archives, codesign-verifies, notarizes, staples, *then* `spctl`. Never `spctl` a not-yet-notarized app.
- `.github/install-lightstar.command` must not `tccutil reset` and must not delete `/Applications/LightStar.app` before the new copy verifies.

---

## Conventions

- Comments explain non-obvious **why**. No multi-line docstrings.
- A new `Cmd` builder must be added to `allFrames` in `LightStarCore/Tests`.
- Recalibration procedure for the hue LUT: sweep 10° steps, fixed WB/exposure, keep `obs` strictly increasing.
