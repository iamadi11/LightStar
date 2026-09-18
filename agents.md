# LightStar — AI Development Knowledge Base

> Update this file when architecture, protocols, or conventions change.
> AI agents should read this before editing any file.

---

## Project Overview

Tauri v2 + Next.js (static export) desktop app controlling a BC/55 BLE RGB LED bar.
Replaces the OEM “Miracles Star” app. The previous native Swift app lives in `legacy/`
and is not the product.

- **UI**: Next.js App Router, `output: 'export'` — no SSR, no API routes
- **Host**: Rust / Tauri 2 (`src-tauri`), tray icon, global shortcuts ⌘⇧L / ⌘⇧S
- **Protocol**: `crates/lightstar-core` (LUT, BC/55 frames, coalescer, schedules)
- **BLE**: `btleplug` write-with-response to FFF3
- **Sync**: screen via `xcap` (~20 fps HSV); audio via `cpal` microphone or strip BC0F
- **iOS**: same Rust/JS codebase; `npm run tauri ios init` on a Mac (personal sideload)
- **Build**: `npm run tauri:dev` / `npm run tauri:build` → macOS `.app` + `.dmg`

Siri, Shortcuts, Focus Filters, and WidgetKit are Swift-only and are not part of this
app. System-audio capture (ScreenCaptureKit) is also not available; use Microphone or
the strip's onboard mic.

---

## BLE Protocol (BC/55)

Frame format: `BC [cmd] [data_len] [data × data_len] 55`. Invariant: `bytes[2] == bytes.len() - 4`.

| Cmd | Function |
|-----|----------|
| `0x01` | Power on/off |
| `0x02` | Channel order 1=RGB…6=BGR |
| `0x03` | Pixel count 16-bit BE, 8–300 |
| `0x04` | Static colour (hue LUT + sat 0–1000) |
| `0x05` | Brightness 16-bit BE **100–1000** |
| `0x06` | Effect select (58 IDs) |
| `0x07` | Effect direction |
| `0x08` | Effect speed (1 byte) |
| `0x09` | Streaming colour |
| `0x0B` | Time sync (auto on connect) |
| `0x0D` | Weekly firmware timer |
| `0x0F` | Strip onboard mic |
| `0x11` | Mic style 1–4 |
| `0x12` | Mic sensitivity 0–255 |
| `0x13` | Animation scene |

GATT: advertised `0x2022`, service `FFF0`, write `FFF3` (with response), notify `FFF4` (never fires).

All BLE writes go through `WriteCoalescer`. Dedup key is `bytes[1]`. Insertion-ordered, replace-in-place. Drain one frame per 20 ms.

Hue LUT lives in `crates/lightstar-core/src/color.rs` — do not regenerate casually.

---

## Architecture

```
crates/lightstar-core/   protocol, LUT, coalescer, schedules (no BLE)
src-tauri/               Tauri host, btleplug, xcap, cpal
app/ + src/              Next.js UI
legacy/                  previous Swift / Xcode project
```

Frontend talks to Rust only via `invoke` + the `state` event. Snapshot fields are camelCase.

### Key invariants

- New fields on `Preset` or `Schedule` must be `Option` / `#[serde(default)]`.
- `last_fired_at` is stamped now at schedule creation so catch-up cannot fire for a time that passed before the schedule existed.
- Silence auto-off applies to audio sync only — never combined.
- `connection_error` is cleared when `connection_state` becomes `connected`.
- Connecting / scan have a 10s timeout.
- User disconnect is an explicit flag, not reconnect exhaustion.
- TCC is per-bundle (`com.adityaraj.LightStar`) and signing identity — not per language.

---

## Conventions

- Comments explain non-obvious **why**. No multi-line docstrings.
- A new `Cmd` builder must be covered by `all_frames` in `lightstar-core` tests.
- Recalibration procedure for the hue LUT: sweep 10° steps, fixed WB/exposure, keep `obs` strictly increasing.
- Run `cargo test -p lightstar-core` after protocol changes.
