# Engineering Baseline

Recorded: 2026-09-20 (updated)
HEAD at last baseline: `c37f751` on `cursor/sdlc-quality-pass-6022` (this pass continues from there)

## Latest CI evidence

| Commit | Run | Result |
|--------|-----|--------|
| `26f9cd6` main push | 35534071590 | **cancelled** after 2s — tests not run |
| `c37f751` PR #11 | 35534500417 | **failure** — compile succeeded; 125 tests, 2 assertions in `testExtremeMouseDeltas` (`3276.8` > `3276.7`) |
| Prior PR jobs | 35534454058 / 35534373197 / 35534249176 | cancelled or failed |

Local `swift test` / `xcodebuild`: **not executed** (no Swift on this Linux agent).

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

## Existing test inventory (code present, not run here)

`LightStarCore/Tests/LightStarCoreTests/`

- `CoreTests.swift` — protocol frames, color math, schedules, coalescer, remote messages, connect/firmware policies
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

- Remote control (LAN, no TLS, pairing off by default)
- BLE connection state machine and scan timeouts
- ScreenCaptureKit + Metal fallback
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- Schedule timer arming, pending drain vs default preset, BC0D firmware timers

## Known limitation of this baseline

A passing or failing CI run is the only automated evidence available from this environment. Claims about runtime behavior on Mac/iPhone are **unverified** here.
