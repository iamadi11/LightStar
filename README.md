# LightStar

Native Swift controller for a reverse-engineered **BC/55** BLE RGB LED bar (the hardware behind the OEM “Miracles Star” app).

- **macOS 14+** menu-bar app (no Dock icon) with ScreenCaptureKit ambilight and system-audio sync
- **iOS 17+** sideload remote (same `LightStarCore` package)
- App Intents / Shortcuts, widgets, Focus Filter
- Optional **Alexa Echo** control via a local Hue-bridge emulator (Mac stays the BLE brain)
- Optional **autonomous company** loop for repo engineering: `./scripts/autonomous-company` or Cursor `/autonomous-company`

## Develop

Needs Xcode 16+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme LightStar -configuration Debug
swift test --package-path LightStarCore
```

Open `LightStar.xcodeproj` after generating it (`LightStar.xcodeproj` is gitignored).

Grant **Bluetooth** on first connect, **Screen Recording** for video sync, **Microphone** for mic sync. TCC follows bundle id `com.adityaraj.LightStar` and the signing identity.

## Autonomous company

```bash
./scripts/autonomous-company          # discover → prioritize → durable state
./scripts/autonomous-company status
./scripts/autonomous-company self-test
```

Design, safety policy, and audit: `company/adr/0001-autonomous-company-architecture.md`, `company/reports/FOUNDATION_AUDIT.md`.

## Layout

| Path | Role |
|------|------|
| `LightStarCore/` | Shared Swift package: BC/55 frames, hue LUT, coalescer, BLE, presets, schedules |
| `LightStar/` | macOS app (menu bar + control window) |
| `LightStariOS/` | iOS remote |
| `LightStarWidget/` | WidgetKit source for macOS and iOS extensions |
| `company/` | Autonomous company state, agents, memory, reports |
| `project.yml` | XcodeGen source of truth |

## Protocol

Frame: `BC [cmd] [data_len] [data × data_len] 55`. GATT advertised `0x2022`, service `FFF0`, write `FFF3`. See `agents.md` and `LightStar/Docs/`.
