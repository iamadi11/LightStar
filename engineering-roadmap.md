# Engineering Roadmap

Date: 2026-09-21  
Quality gate: Principal + Architect + Reliability + Security + Performance (this session)

## Selected (implement this pass)

Ordered by impact × evidence × small blast radius. Product behavior preserved (PD-001 / PD-002 stand).

| ID | Title | Why this over others |
|----|-------|----------------------|
| EE-001 | Gate pointer injection on authentication | Confirmed auth bypass if pairing is enabled. One-line policy + call-site checks. No UX change while pairing stays off (hello already authenticates). |
| EE-002 | Gyro deltas go straight to `PointerChannel` | Code shows a MainActor hop on a ~200 Hz path that is already `@Sendable` / `nonisolated`. Matches the existing injector design. |
| EE-003 | Sampler `start()` throws when superseded | Silent return leaves `syncMode` on with no capture. Failure path already exists in `buildSync`. |
| EE-004 | Client `.failed` uses `cleanupConnection()` | Orphan `NWBrowser` after a failed connect from discovery. |
| EE-005 | Do not fan `syncColor` into widget writes; throttle remote broadcasts | 20–30 Hz Observation currently resets widget debounce and broadcasts full JSON snapshots. Menu-bar live icon remains. |
| EE-006 | Mic sampler Sendable captures | Strict concurrency warnings on the audio tap / engine observer; tiny, local, CI-relevant. |

## Follow-up (this pass)

| ID | Title | Why |
|----|-------|-----|
| EE-009 | Combined/resume `CancellationError` wiring | Independent review of EE-003: combined screen cancel skipped audio; wake resume called `stopSyncInline()`. |

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
