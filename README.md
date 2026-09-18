# LightStar

Tauri v2 + Next.js controller for a reverse-engineered **BC/55** BLE RGB LED bar (the hardware behind the OEM “Miracles Star” app).

macOS 14+ is the supported desktop target. The same codebase can be sideloaded to iOS with Tauri’s mobile tooling. The previous native Swift app is archived in [`legacy/`](legacy/).

## What it does

- Connects over Bluetooth LE (service `FFF0`, write `FFF3`)
- Power, hue (hand-calibrated LUT), brightness, 58 firmware effects, 253 animation scenes
- Screen ambilight (`xcap`) and microphone / strip-mic audio sync
- Scenes, weekly schedules, optional BC0D firmware timers (run while the Mac is asleep)
- Menu-bar tray, ⌘⇧L power, ⌘⇧S sync

System audio (what you hear from other apps) is **not** captured — use **Microphone** or **Strip mic**. Siri / Shortcuts / widgets are not part of this rewrite.

## Develop

Needs Node 20+, Rust (stable), and on macOS Xcode 16.

```bash
npm install
cargo test -p lightstar-core
npm run tauri:dev
```

Production `.app` + `.dmg`:

```bash
npm run tauri:build
```

iOS (Mac only, personal sideload):

```bash
npm run tauri ios init
npm run tauri ios dev
```

Grant **Bluetooth** on first connect, **Screen Recording** for video sync, **Microphone** for mic sync. TCC follows the bundle id `com.adityaraj.LightStar` and the signing identity — it is not avoided by using Tauri.

## Layout

| Path | Role |
|------|------|
| `crates/lightstar-core` | BC/55 frames, hue LUT, coalescer, schedules |
| `src-tauri` | BLE (`btleplug`), tray, screen/mic sync, persistence |
| `app`, `src` | Next.js static UI |
| `legacy` | Swift 6 / Xcode app this rewrite replaces |

State is stored in `~/Library/Application Support/LightStar/state.json`.
