# Engineering Improvement Tracker

Last updated: 2026-09-21
Branch: `cursor/ee003-capture-cancel-6022`
Base: `origin/main` @ `04527b6`

## Status

| Phase | State |
|-------|--------|
| 0 Product understanding | Complete |
| 1 Baseline | PR #12 CI success (150 tests); local Swift unavailable |
| 2–4 Audit + quality gate | EE-001–006 selected; Metal/schedules/TLS rejected or deferred |
| 6 Implementation | In progress |
| 9 CI | After push |
| 18 Merge | After CI green |

## Selected tasks

| ID | Status |
|----|--------|
| EE-001 Pointer auth gate | Implemented |
| EE-002 Gyro skip MainActor hop | Implemented |
| EE-003 Sampler start throws if superseded | Implemented |
| EE-004 Client failed connection cleanup | Implemented |
| EE-005 syncColor observation fan-out | Implemented |
| EE-006 Mic Sendable captures | Implemented |
| EE-007 Sync restore only if active at drop | Implemented |
| EE-008 Do not adopt extras as primary | Implemented |
| EE-009 Combined/resume CancellationError | Implemented |

## Product decisions

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays off by default; no TLS |
| PD-002 | Keep 6-char alphanumeric pairing codes |
