# Engineering Roadmap

Date: 2026-09-21  
Quality gate: Principal + Architect + Reliability + Security + Performance (this session)  
Last company reconcile: 2026-09-21 — EE-001–009 verified Implemented in tree + tracker

## Selected (implement this pass)

_None._ All prior Selected items are **Implemented** (see below). Do not rediscover without a regression signal.

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

## Follow-up (this pass)

_None outstanding._ EE-009 completed with EE-003 wiring.

## Deferred

| Item | Reason |
|------|--------|
| Default Metal off / async GPU analyze at 48×27 | Structural suspicion only; no fps/CPU measurement. |
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
| Faster BLE writes | Coalescer + 20/30 Hz caps are by design; no device traces. |

## Validation strategy

- Unit tests for new policy helpers (pointer auth, capture superseded, broadcast throttle).
- GitHub Actions: `swift test --package-path LightStarCore`, unsigned macOS + iOS builds.
- Manual Mac/iPhone: **not available** on this agent.
- Linux agents: never claim local `xcodebuild` success; cite CI when available.
