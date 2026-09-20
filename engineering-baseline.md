# Engineering Baseline

Recorded: 2026-09-20 (updated)
HEAD: `26f9cd6` on `origin/main`

## Latest CI evidence

| Commit | Run | Result |
|--------|-----|--------|
| `26f9cd6` main push | 35534071590 | **cancelled** after 2s — tests not run |
| PR `0754826` / later mock-lock commit | 35534072435 | **failure** — NSLock in async mock `send` |
| Pre-merge `db5c5d6` | 35533715892 | **failure** — deinit isolation |

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

## GitHub Actions baseline (`origin/main`)

Latest run inspected: [35533715892](https://github.com/iamadi11/LightStar/actions/runs/35533715892)

| Job | Result |
|-----|--------|
| `CI / Generate, test, build` on `macos-15` | **failure** (exit 1) |

Compile errors that prevented tests from running:

1. `PresetStore.swift:95` — MainActor `iCloudObserver` accessed from `deinit`
2. `CaptureDiagnostics.swift:160` — MainActor `browserMonitorTimer` accessed from `deinit`
3. `BLEWriteCoalescer.swift:24` — MainActor `timer` accessed from `deinit`
4. `LightBLEManager.swift:262` — MainActor `circadianTimer` accessed from `deinit`

Tests were **not executed** in that run because compilation failed.

Recent CI history (all failed):

- Merge reliability audit phase 2
- Merge reliability audit
- Fix bug #36
- QA round 4 commits

## Existing test inventory (code present, not run here)

`LightStarCore/Tests/LightStarCoreTests/`

- `CoreTests.swift` — protocol frames, color math, schedules, coalescer, remote messages
- `Integration/SecurityTests.swift` — mock authenticator (not live `RemoteControlServer`)
- `Integration/ProtocolIntegrationTests.swift` — encode/decode
- `Integration/FrameAnalysisTests.swift` — mock frames
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
- Schedule timer arming and persistence

## Known limitation of this baseline

A passing or failing CI run is the only automated evidence available from this environment. Claims about runtime behavior on Mac/iPhone are **unverified** here.
