# Engineering Findings (Excellence Audit)

Triage date: 2026-09-21  
Base: `a7de2c9` (ENG-001–034 already on main)

## Product decisions (unchanged)

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays **off by default**. No Mac pairing-code UI. No TLS. |
| PD-002 | Pairing codes stay 6-character alphanumeric. |

## Selected improvements (this pass)

### EE-001 — Unauthenticated pointer JSON fallback

- **Category:** Security / Reliability
- **Classification:** Must Fix
- **Evidence:** `onPointer` returned `false` when unauthenticated; `processBuffer` then built a JSON mouse/scroll message and `onMessage` called `injector.handle` with no auth check.
- **Product impact:** None while pairing is off (hello authenticates). Correct if pairing is ever enabled.
- **Complexity:** Low

### EE-002 — Gyro MainActor hop before PointerChannel

- **Category:** Performance
- **Classification:** High-Value Improvement
- **Evidence:** `MotionPump.emit` used `DispatchQueue.main.async` then `addMouseDelta`, which is already `nonisolated`.
- **Measurement:** Code-path removal of one hop. No profiler in this environment.
- **Complexity:** Low

### EE-003 — Sampler start silent abort

- **Category:** Reliability
- **Classification:** Must Fix
- **Evidence:** `guard generation == gen else { return }` after `syncMode` already set to video/audio/combined.
- **Fix:** Throw `CancellationError`; `buildSync` does not surface it as a permission error.
- **Complexity:** Low

### EE-004 — Client `.failed` skipped `cleanupConnection`

- **Category:** Reliability
- **Classification:** High-Value Improvement
- **Evidence:** Failed TCP did not `stopBrowser()` or bump generation.
- **Complexity:** Low

### EE-005 — `syncColor` fan-out

- **Category:** Performance / Resource Efficiency
- **Classification:** High-Value Improvement
- **Evidence:** 20–30 Hz `syncColor` re-armed Observation that also wrote widget JSON and broadcast full LAN snapshots.
- **Fix:** Widget observation excludes `syncColor`. Remote broadcasts throttle sync-only changes to 10 Hz; power/mode/connection still immediate. Menu-bar live icon unchanged.
- **Measurement:** Policy tests for throttle interval. No Hz counter in CI.
- **Complexity:** Low

### EE-006 — Mic sampler Sendable captures

- **Category:** Maintainability
- **Classification:** High-Value Improvement
- **Evidence:** CI warnings: `isRunning` in Sendable observer; captured `var mono`.
- **Complexity:** Low

## Independent verification (a7de2c9)

[Independent reliability diff review](bc-34f40492-3724-5e40-bfd1-45e4c4f94228) of the prior pass. Two production issues confirmed in source and fixed on this branch:

### EE-007 — Connect restored sync after the user turned it off

- **Classification:** Bug fix (product-behavior regression from ENG-024)
- **Evidence:** `setSyncMode(.off)` persisted `lastSyncMode` for toggle, and `startConnectSequence` restored whenever `lastSyncMode != .off`. After picker-off, an unexpected drop still resumed capture.
- **Fix:** `restoreSyncOnReconnect` is cleared when the user turns sync off and set when `stopSyncInline` interrupts a running mode. Connect restore and the default-preset skip use that flag. Toggle still uses `lastSyncMode`.

### EE-008 — Scan could adopt an extra light as primary

- **Classification:** Bug fix (incomplete ENG-022)
- **Evidence:** After a primary drop, extras stay in `extraLights`. `didDiscover` assigned an extra as `self.peripheral`; GATT discovery then hit `extraLightIndex` and never started the connect sequence.
- **Fix:** `shouldAdoptAdvertisementAsPrimary(isAlreadyExtra:)` rejects extras on the primary path.


See `engineering-roadmap.md`. Metal GPU blocking, schedule persist off-main, TLS, and LightBLEManager splits were not implemented.
