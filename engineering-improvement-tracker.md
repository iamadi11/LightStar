# Engineering Improvement Tracker

Last updated: 2026-09-20
Branch: `cursor/sdlc-quality-pass-6022`
Base: `origin/main` @ `26f9cd6`

## Status

| Phase | State |
|-------|--------|
| 0 Discovery | Complete |
| 1 Baseline | CI on `26f9cd6` cancelled; PR tests compiled then failed S011 Int16 range |
| 2 QA | Independent adversarial QA confirmed BLE/connect/sync/client bugs |
| 3–5 | ENG-007…015 implemented; ENG-006 test range corrected |
| 6–8 | Policy helpers only; no speculative refactors |
| 9 | GitHub Actions on this PR after push |
| 10–11 | Not available (Linux, no devices) |
| 18 | Merge after CI green |

## Confirmed bugs

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| ENG-001 | Swift 6 deinit isolation | Critical | Fixed on main `26f9cd6` |
| ENG-002 | iOS pairing 4 vs 6 chars | High | Fixed on main `26f9cd6` |
| ENG-003 | Mock actor isolation | High (CI) | Fixed on this branch |
| ENG-004 | NSLock.lock() in async `send` | High (CI) | Fixed on this branch |
| ENG-005 | Server protocol error does not cancel NWConnection | Medium | Fixed on this branch |
| ENG-006 | Pointer encode Int trap + asymmetric Int16 test | High | Code fixed; test range corrected |
| ENG-007 | Connect init color after powerOff wakes strip | High | Fixed on this branch |
| ENG-008 | Extra GATT services restart connect sequence | High | Fixed on this branch |
| ENG-009 | Default preset overwrites scheduled connect actions | High | Fixed on this branch |
| ENG-010 | Firmware timers not pushed on connect / slots not cleared | High | Fixed on this branch |
| ENG-011 | stopSyncInline leaves strip mic enabled | Medium | Fixed on this branch |
| ENG-012 | Extra-light fail reconnects primary | Medium | Fixed on this branch |
| ENG-013 | Multi-light scan stops on first advertisement | Medium | Fixed on this branch |
| ENG-014 | Listener `.error` overwritten; pointer injector leak | Medium | Fixed on this branch |
| ENG-015 | Pairing timeout / error clobber | Medium | Fixed on this branch |

## Product decisions

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays off by default |
| PD-002 | Keep 6-char alphanumeric pairing codes |

## Remaining risks

- Local Swift/Xcode unavailable
- Hardware journeys unverified
- Firmware weekly timer slot count assumed 8
- LAN remote control has no TLS
