# LightStar — AI Development Knowledge Base

> Update this file when architecture, protocols, or conventions change.
> AI agents should read this before editing any file.

---

## Project Overview

macOS menu-bar app (LSUIElement, no Dock icon) controlling a BC/55 BLE RGB LED bar.
Replaces the "Miracles Star" OEM app with a clean native controller + Ambilight sync.

- **Platform**: macOS 14.0+, Swift 6, strict concurrency
- **BLE**: CoreBluetooth on main actor
- **UI**: SwiftUI, @Observable, @MainActor
- **Build**: `xcodebuild -scheme LightStar -configuration Debug`
- **Project regen**: `xcodegen generate` (all `.swift` files auto-included via glob)

---

## BLE Protocol (BC/55, confirmed via PacketLogger 2026-08-23)

Frame format: `BC [cmd] [data_len] [data × data_len] 55`

| Cmd byte | Function | Key bytes |
|----------|----------|-----------|
| `0x01`   | Power on/off | `0x01` = on, `0x00` = off |
| `0x04`   | Hue + saturation | 16-bit big-endian H (0–360°), 16-bit big-endian S (0–1000) |
| `0x05`   | Brightness | 16-bit big-endian (100–1000; min 100 observed) |
| `0x06`   | Effect select | 2-byte: `0x00 id` |
| `0x08`   | Effect speed | 1-byte 0–100 |
| `0x13`   | BC13 animation | firmware-side scenes 0x00–0xFF |

BLE service UUID: `FFF0`. Write characteristic: `FFF3`. Advertised UUID: `2022`.

### Hue LUT
Strip's RGB → hue mapping is non-linear. A piecewise linear LUT in `BLEProtocol.swift`
corrects for this. Key calibration region: 305–360° (purple/magenta) was recalibrated
from Phase 1 sweep residuals (5–13° undershoot).

---

## Architecture

```
LightStar/
├── BLE/
│   ├── BLEProtocol.swift       — Cmd builders + HueLUT + Color.hsvComponents
│   ├── BLEWriteCoalescer.swift — 20ms drain timer, per-command-byte dedup (key = bytes[1])
│   ├── LightBLEManager.swift   — @MainActor @Observable coordinator (~900 lines)
│   ├── MicSyncManager.swift    — Mic FFT → FrequencyBands (uses AVAudioEngine)
│   └── CameraChangeDetector.swift — AVCaptureSession camera color sampling
├── Models/
│   ├── FrequencyBands.swift    — Shared audio analysis struct (Sendable)
│   ├── LightState.swift        — LightState + Preset structs (Codable)
│   └── PresetStore.swift       — @Observable UserDefaults preset persistence
├── ScreenSync/
│   ├── ScreenColorSampler.swift  — SCStream @ 16×9px → dominantHSV → onColor callback
│   └── SystemAudioSampler.swift  — SCStream audio → FFT → onBands callback
└── Views/
    ├── MenuBarView.swift         — 288-line shell (tab bar + sections)
    ├── SyncModePickerView.swift  — Mode picker + display selector
    ├── ColorControlsView.swift   — Inline hue/sat GradientSlider
    ├── EffectGridView.swift      — EffectsView + AnimationsView
    ├── PresetsView.swift         — Preset grid
    ├── ConnectionStatusView.swift — Disconnected/connecting states
    └── DebugView.swift           — BLE probe + camera debug
```

### Key Invariants

- **`write()` key**: `writeQueue[bytes[1]]` — `bytes[1]` is the command sub-byte (0x04, 0x05…). `bytes[0]` is always `0xBC` (header) — never use as key.
- **All BLE writes** go through `BLEWriteCoalescer.enqueue()` — never `peripheral.writeValue` directly.
- **SyncMode state machine**: `setSyncMode` → cancel `transitionTask` → `teardownSync` → `buildSync`. Always cancel `fadeTask` in teardown first.
- **fadeToSteadyState**: uses `do { try await Task.sleep(...) } catch { return }` — NOT `try?` (which swallows CancellationError and skips `restoreSteadyState`).
- **Screen capture**: `ScreenColorSampler` uses `SCStream` at 16×9 with IOSurface fast path. `SCDisplay` has no `localizedName` — use `NSScreen` matching by `displayID`.
- **Audio capture**: `SystemAudioSampler` uses `SCStream` for system audio (requires Screen Recording permission). Callbacks fire on `queue`, dispatch to main via `DispatchQueue.main.async`.

---

## SyncMode State Machine

```
.off ←──────────────────────────────────────────┐
 │ setSyncMode(.video/.audio/.combined)          │
 ▼                                               │
teardownSync()                              setSyncMode(.off)
 - fadeTask?.cancel()                            │
 - nil all callbacks                             │
 - await stop() on active samplers               │
 ▼                                               │
buildSync(mode, previousMode:)                   │
 - start samplers                                │
 - set callbacks                                 │
 - on .off: fadeToSteadyState(from: prev) ───────┘
```

---

## Common Bugs to Avoid

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `_dispatch_assert_queue_fail` | CGDisplayStream callback crossing queue boundary | Use `DispatchQueue.main` as delivery queue, or `SCStream` (current) |
| `writeQueue` drops color or brightness | Keying by `bytes[0]` (always 0xBC) | Key by `bytes[1]` (command sub-byte) |
| Strip stuck on wrong color after mode exit | `try? await Task.sleep` swallows cancel | Use `do/catch` so restoreSteadyState always runs |
| `NSScreen.screens` crash off main thread | NSScreen is MainActor-only | Mark callers `@MainActor` |
| `SCDisplay.localizedName` compile error | SCDisplay has no such property | Match CGDirectDisplayID via NSScreen.screens |

---

## Multi-Agent Parallelism Rules

When spawning parallel agents:
1. **One agent per file group** — never two agents writing the same file
2. **New files**: safe to create in parallel if no other agent reads them to import
3. **`project.yml` glob**: new `.swift` files are auto-included — run `xcodegen generate` after copying worktree files to main
4. **Always build to verify** before committing: `xcodebuild build -scheme LightStar 2>&1 | grep -E "error:|BUILD"`
5. **Worktrees fail mid-work** on API limits — copy files to main project, run xcodegen, fix errors manually
6. **Merge strategy**: `git merge worktree-agent-XXXX --no-edit` for clean builds; copy+xcodegen for partial builds

---

## Calibration History

| Date | Change |
|------|--------|
| 2026-08-23 | Initial LUT from PacketLogger capture |
| 2026-08-23 | Blue/purple underperformance photographed (IMG_8890.HEIC) |
| 2026-08-24 | Phase 1 recalibration: 305–360° range corrected (5–13° undershoot) |

---

## Conventions

- No `try?` inside `Task { @MainActor }` fade loops — use `do/catch`
- No `DispatchQueue.main.async` from inside `@MainActor` context — already on main
- `write()` is a 1-liner: `coalescer.enqueue(bytes)` — all coalescing in BLEWriteCoalescer
- New view components: `@Environment(LightBLEManager.self) private var ble` — no prop drilling
- `FrequencyBands` lives in `Models/` — import from there, not BLE layer
- Comments only for non-obvious WHY (not what). No multi-line docstrings.
