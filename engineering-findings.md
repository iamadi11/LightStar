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

## Independent verification (f18a67e / 04527b6)

[Independent excellence diff review](bc-a8560d8f-42d1-5ab1-967b-8fc607773ce5) of EE-001–006. EE-001/002/004/005 hold. EE-003 wiring was wrong after merge:

### EE-009 — Combined/resume `CancellationError` must not kill or stall sync

- **Classification:** Bug fix (EE-003 incomplete)
- **Evidence:** Combined screen `CancellationError` returned immediately with `.combined` on, audio never started, and no sibling `stop()`. `resumeScreenSync` called `setSyncError` + `stopSyncInline()` on any throw, so a pause/start race on wake killed the session.
- **Fix:** `CaptureSessionPolicy.disposition` continues combined (and keeps `.combined` when screen start was superseded) unless the transition task is cancelled. Resume ignores `CancellationError`. Samplers call `isSuperseded`.

### EE-010 — Sleep/wake pause/resume race leaves capture dead

- **Classification:** Bug fix (Screen + Both)
- **Evidence:** `pauseScreenSync` fire-and-forget `Task { await stop() }` while `resumeScreenSync` calls `start()` which no-ops when `isRunning` — wake can show sync on with no frames.
- **Fix:** `sleepWakeTask` serializes pause→resume; resume always drains `stop()` before `start()` (`SleepWakeCapturePolicy`).

### EE-011 — Screen capture analyzed at 60 Hz for 20 Hz BLE writes

- **Classification:** Perf (Screen + Both)
- **Evidence:** `minimumFrameInterval` timescale 60 vs hue write throttle `1/20` in `LightBLEManager+Sync`.
- **Fix:** SCStream interval timescale 20.

### EE-012 — Legacy system-audio FFT prepared after capture start

- **Classification:** Bug fix (Music/Both on macOS &lt; 14.2 display-stream path)
- **Evidence:** `engine.prepare()` ran after `startCapture()`; early buffers hit nil FFT setup → zero bands.
- **Fix:** Prepare before `startCapture()`.

See `engineering-roadmap.md`. Metal GPU blocking (EE-014), mic/system RMS unify (EE-013), and Combined sat punch (EE-016) remain follow-up/deferred.
