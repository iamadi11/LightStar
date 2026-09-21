# Engineering Baseline

Recorded: 2026-09-21
HEAD at last baseline: `adda24d` on `main` / `cursor/sdlc-reliability-pass-6022`

## Latest CI evidence

| Commit | Run | Result |
|--------|-----|--------|
| `adda24d` main | 35536096195 | **success** — LightStarCore tests, unsigned macOS build, widget embed, unsigned iOS build |
| Prior quality-pass PR | 35536096195 | Same commit after ENG-001–021 |

Local `swift test` / `xcodebuild`: **not executed** (no Swift on this Linux agent). GitHub Actions on macOS 15 is the compile/test gate.

## Product

Native Swift controller for a reverse-engineered BC/55 BLE RGB LED bar.

| Path | Role |
|------|------|
| `LightStarCore/` | Shared Swift 6 package |
| `LightStar/` | macOS 14+ menu-bar app |
| `LightStariOS/` | iOS 17+ remote |
| `LightStarWidget/` | WidgetKit (macOS + iOS) |

Validation commands from README / CI:

```bash
swift test --package-path LightStarCore
xcodegen generate
xcodebuild -scheme LightStar -configuration Debug
```

## Local execution

| Check | Result | Evidence |
|-------|--------|----------|
| `which swift` | Not found | Shell |
| `which xcodebuild` | Not found | Shell |
| `which xcodegen` | Not found | Shell |
| Local unit tests | **Not executed** | No Swift runtime |
| Local macOS/iOS build | **Not executed** | No Xcode |
| Hardware / BLE | **Not executed** | Linux VM |
| Manual device install | **Not executed** | No devices |

## Existing test inventory (code present)

`LightStarCore/Tests/LightStarCoreTests/`

- `CoreTests.swift` — protocol frames, color math, schedules, coalescer, remote messages, connect/firmware/discovery policies
- `Integration/SecurityTests.swift` — mock authenticator + pointer encode clamp
- `Integration/ProtocolIntegrationTests.swift` — encode/decode
- `Integration/FrameAnalysisTests.swift` — mock frames (wait on `framesDelivered`)
- `Integration/UserJourneyTests.swift` — mock journeys
- Mocks for transport, lighting, input, screen, authenticator

App targets (`LightStar`, `LightStariOS`) have **no** Xcode test targets (`project.yml` `test.targets: []`).

## Critical user journeys (from product code)

1. Mac: launch menu bar → BLE scan/connect → power/color/brightness/effects
2. Mac: screen / audio / combined sync
3. Mac: schedules and presets
4. iPhone: Bonjour discover Mac → TCP connect → lights + trackpad + keyboard
5. Widgets / App Intents / Focus Filter

## High-risk areas

- Remote control (LAN, no TLS, pairing off by default — PD-001)
- BLE connection state machine, leftover `peripheral` after disconnect, multi-light extras
- ScreenCaptureKit + Metal fallback; sampler start/stop races
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- Schedule timer arming, pending drain vs default preset, BC0D firmware timers
- lastSyncMode restore racing default preset on connect

## Known limitation of this baseline

A passing or failing CI run is the only automated evidence available from this environment. Claims about runtime behavior on Mac/iPhone are **unverified** here.
