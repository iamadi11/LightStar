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

## Not treated as confirmed product bugs

| Item | Classification | Reason |
|------|----------------|--------|
| Pairing off by default / no TLS | Product decision / remaining risk | Changing it alters LAN connect UX |
| Stale `docs/validation/security-review.md` (says any 4-digit accepted) | Documentation drift | Server now verifies `activePairingCode` |
| Hardware journeys | Unverified | No Mac/iPhone/BLE in this environment |

## Potential issues (need independent QA)

Pending agent reports. Will not implement speculative refactors.
