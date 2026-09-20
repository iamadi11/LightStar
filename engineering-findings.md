# Engineering Findings

Triage date: 2026-09-20
Sources: GitHub Actions logs, repository inspection. Independent QA agents still running.

## Confirmed bugs

### ENG-001 — Swift 6 deinit isolation breaks the build

- **Severity:** Critical
- **Feature:** Entire product (CI `swift test` / compile)
- **Environment:** GitHub Actions `macos-15`, Swift 6 complete concurrency
- **Reproduction:** Push to `main`; workflow `CI / Generate, test, build` fails at `swift test --package-path LightStarCore`
- **Expected:** Package compiles and tests run
- **Actual:** Compile errors, tests never start
- **Evidence:** Run `35533715892` log: `PresetStore.swift:95`, `CaptureDiagnostics.swift:160`, `BLEWriteCoalescer.swift:24`, `LightBLEManager.swift:262`
- **Root cause:** `@MainActor` types accessing isolated `Timer` / observer properties from nonisolated `deinit`
- **Proposed fix:** Mark those stored properties `nonisolated(unsafe)` (same pattern as FFT state in audio samplers); hop iCloud observer callback onto MainActor before reading `iCloudEnabled`
- **Regression risk:** Resource cleanup still happens in `deinit`; no user-facing behavior change
- **Testing:** CI compile + existing coalescer tests
- **Status:** Implemented on this branch

### ENG-002 — iOS pairing UI out of sync with server code format

- **Severity:** High (only if pairing is enabled)
- **Feature:** iPhone ↔ Mac pairing
- **Reproduction (code):** Server `generatePairingCode()` returns 6 alphanumeric chars. iOS `RemoteControlView` uses number pad and requires `pairingCode.count == 4`
- **Expected:** User can type the code the Mac generated
- **Actual:** Pair button stays disabled; number pad cannot enter letters
- **Evidence:** `RemoteControlServer.swift` vs `LightStariOS/RemoteControlView.swift`
- **Root cause:** Reliability audit on `main` changed code format without updating iOS
- **Proposed fix:** Shared `kLightStarPairingCodeLength`, iOS field accepts 6 alphanumeric characters
- **Product note:** Pairing is still **off by default** and Mac has no UI to show the code (`PD-001`). This fix only restores consistency if pairing is turned on.
- **Status:** Implemented on this branch

### ENG-003 — Test mock actor cannot conform to MessageTransport

- **Severity:** High (CI only; production code compiled)
- **Feature:** LightStarCore tests
- **Evidence:** PR CI run `35533949524` — `MockMessageTransport.swift:6` `#ConformanceIsolation`
- **Root cause:** `actor MockMessageTransport` isolated `isConnected` while `MessageTransport` requires a nonisolated `Sendable` getter
- **Fix:** Same pattern as other mocks — `final class` + `NSLock` + `@unchecked Sendable`
- **Status:** Implemented on this branch

### ENG-004 — NSLock used from async test mock (CI still red)

- **Severity:** High (CI)
- **Evidence:** PR run `35534072435` — `MockMessageTransport.swift:36` `lock is unavailable from asynchronous contexts`
- **Root cause:** ENG-003 converted actor to class with NSLock; Swift 6 forbids NSLock in `async` functions
- **Fix:** Drop the lock (mock is unused by tests, single-threaded helper)
- **Status:** Implementing

### ENG-005 — Server leaves TCP connection open after protocol/buffer failure

- **Severity:** Medium
- **Evidence:** `RemoteControlServer.swift` `startReceiving` overflow and `processBuffer` catch call `onDisconnect` but do not `connection.cancel()`, then continue `startReceiving()` when the receive is incomplete
- **Fix:** `failConnection()` cancels NWConnection and stops the receive loop
- **Product behavior:** Valid clients unchanged
- **Status:** Implementing

### ENG-006 — Pointer encode could crash on huge finite deltas

- **Severity:** High (trackpad/gyro path)
- **Evidence:** [QA tests](bc-dea6386a-879b-53da-a2a9-2da63341edfa) — `encodePointerFrame` does `Int((delta * 10).rounded())` which traps when the scaled Double is infinite
- **Fix:** Saturate to Int16 without going through unbounded `Int(...)`
- **Tests:** S011 rewritten; no longer uses values that trap
- **Status:** Implementing

## Test coverage (not product bugs)

Mock Security/UserJourney suites do not exercise `RemoteControlServer` / `LightBLEManager`. Documented; not rewritten. Added production tests for schedule `isDue` edges, BC05 brightness bytes, weekly timer payload, zero-length frames, pairing charset.

| Item | Classification | Reason |
|------|----------------|--------|
| Pairing off by default / no TLS | Product decision / remaining risk | Changing it alters LAN connect UX |
| Stale `docs/validation/security-review.md` (says any 4-digit accepted) | Documentation drift | Server now verifies `activePairingCode` |
| Hardware journeys | Unverified | No Mac/iPhone/BLE in this environment |

## Potential issues (need independent QA)

Pending agent reports. Will not implement speculative refactors.
