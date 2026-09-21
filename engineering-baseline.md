# Engineering Baseline

Recorded: 2026-09-21  
HEAD: `a7de2c9` on `cursor/engineering-excellence-audit-6022` (same as `origin/main` at branch creation)

## Classification of evidence

| Item | Kind | Evidence |
|------|------|----------|
| LightStarCore tests on PR #12 | **Measured** | GitHub Actions `35558416621`: **150 tests, 0 failures** |
| Unsigned macOS build | **Measured** | Same run: **BUILD SUCCEEDED**, widget embedded |
| Unsigned iOS build | **Measured** | Same run: **BUILD SUCCEEDED** |
| Main push CI `35558720764` | **Unknown at baseline start** | In progress after merge of #12 |
| Local `swift test` / `xcodebuild` | **Unknown** | No Swift/Xcode on this Linux agent |
| Hardware BLE / iPhone / Accessibility | **Unknown** | No devices |
| Startup time, CPU, memory | **Unknown** | No profiler in this environment |
| Gyro MainActor hop | **Observed** (code) | `GyroPointerController.emit` → `DispatchQueue.main.async` then `addMouseDelta` |
| Pointer auth bypass | **Observed** (code) | `onPointer` false → JSON `onMessage` → `injector.handle` with no auth |
| Sampler silent start abort | **Observed** (code) | `guard generation == gen else { return }` (no throw) after `syncMode` already set |
| Client `.failed` skip cleanup | **Observed** (code) | Duplicated teardown, no `stopBrowser()` |
| Production LAN threat with pairing off | **Inferred** | PD-001; hello sets `authenticated = true` |

## Product

Native Swift controller for a reverse-engineered BC/55 BLE RGB LED bar. See `engineering-product-understanding.md`.

## Local execution

| Check | Result |
|-------|--------|
| `swift` / `xcodebuild` / `xcodegen` | Not present |
| Unit/integration/E2E on this VM | **Not executed** |
| Packaging / install | **Not executed** |
| Security scanners / dependency CVE DB | **Not executed** |

## Critical workflows

Unchanged from product understanding: Mac BLE control, sync, schedules, iPhone remote, wake reconnect.

## Existing risks (not in this baseline as open product bugs)

ENG-001–034 are on `main`. This pass is engineering quality, not a second bug-hunt of the same items.

## Evidence gaps

- No runtime traces of gyro latency or remote broadcast Hz.
- No crash reports or production logs.
- Mock Security/UserJourney tests still do not exercise `RemoteControlServer` production auth (documented; not rewritten).
