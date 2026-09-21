# Engineering Roadmap

Date: 2026-09-21  
Quality gate: Principal + Architect + Reliability + Security + Performance (this session)  
Last company reconcile: 2026-09-21 — sync audit (screen / audio / Both); EE-010–012 implemented

## Selected (implement this pass)

_None pending._ EE-010–012 shipped this pass (see Implemented).

Ordered by impact × evidence × small blast radius. Product behavior preserved (PD-001 / PD-002 stand).

| ID | Title | Why this over others |
|----|-------|----------------------|

## Implemented (this pass)

| ID | Title | Evidence |
|----|-------|----------|
| EE-001 | Gate pointer injection on authentication | `RemotePointerAuthPolicy` + `RemoteControlServer` call-sites; `CoreTests` pointer auth |
| EE-002 | Gyro deltas go straight to `PointerChannel` | `GyroPointerController.emit` → `RemoteControlClient.addMouseDelta` (nonisolated); no MainActor hop |
| EE-003 | Sampler `start()` throws when superseded | `CaptureSessionPolicy.isSuperseded` in mic/system/screen samplers |
| EE-004 | Client `.failed` uses `cleanupConnection()` | `RemoteControlClient.fail` → `cleanupConnection` / `stopBrowser` |
| EE-005 | Do not fan `syncColor` into widget writes; throttle remote broadcasts | `LightStarApp` widget observation; `RemoteStateBroadcastPolicy` |
| EE-006 | Mic sampler Sendable captures | `MicAudioSampler` MainActor observer + sample copy before queue |
| EE-007 | Sync restore only if active at drop | Tracker + sync path |
| EE-008 | Do not adopt extras as primary | Tracker + scan policy |
| EE-009 | Combined/resume `CancellationError` wiring | `CaptureSessionPolicy.disposition` |
| EE-010 | Serialize screen pause/resume (await stop before start) | `sleepWakeTask` chain + `SleepWakeCapturePolicy`; CoreTests |
| EE-011 | Match screen `minimumFrameInterval` to ≤20 Hz writes | `ScreenCaptureKitProvider` timescale 20 (was 60) |
| EE-012 | Prepare FFT before legacy display-stream audio start | `SystemAudioSampler.startDisplayStream` order fix |

## Follow-up (this pass)

| ID | Title | Why |
|----|-------|-----|
| EE-013 | Unify mic/system RMS normalization | Same loudness → different rms scales (mic ×20 vs system ×8); needs A/B on hardware |
| EE-015 | Metal CPU fallback edge-weight parity | Rare path; shader weights edges, CPU fallback does not |
| EE-016 | Resolve Combined saturation punch API | Doc/API drift vs unused mixer helpers — product call before wire/delete |

## Deferred

| Item | Reason |
|------|--------|
| Default Metal off / async GPU analyze at 48×27 (EE-014) | Structural suspicion only; no fps/CPU measurement at 48×27. |
| Schedule JSON persist off MainActor | Fires at most a few times per day; hitch is hypothetical. |
| Disconnect extras when primary drops | No hardware evidence of orphan extras misbehaving. |
| Split `LightBLEManager` | God-object explained recent bugs; policies already extracted. Rewrite would not pay. |
| Production auth integration tests against `NWListener` | High effort vs PD-001 default; policy tests cover the new gate. |

## Rejected

| Item | Reason |
|------|--------|
| TLS / pairing on by default | Product decision PD-001. |
| Rewrite mock SecurityTests as production | Documented non-goal; would not change shipping code. |
| File splits, DI frameworks, actor graph for sync | No responsibility mismatch that a new layer would fix. |
| Faster BLE writes / raise 20–30 Hz caps | Coalescer + caps by design; no device traces. |
| Re-open EE-003/005/006/007/009 | Already Implemented; no regression signal. |

## Validation strategy

- Unit tests for new policy helpers (pointer auth, capture superseded, broadcast throttle, sleep/wake drain).
- GitHub Actions: `swift test --package-path LightStarCore`, unsigned macOS + iOS builds.
- Manual Mac: display sleep/wake while Screen and Both sync; Activity Monitor CPU after EE-011.
- Manual Mac/iPhone: **not available** on this agent.
- Linux agents: never claim local `xcodebuild` success; cite CI when available.
