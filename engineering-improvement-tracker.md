# Engineering Improvement Tracker

Last updated: 2026-09-20
Branch: `cursor/sdlc-quality-pass-6022`
Base: `origin/main` @ `26f9cd6`

## Status

| Phase | State |
|-------|--------|
| 0 Discovery | Complete (this pass) |
| 1 Baseline | CI on `26f9cd6` **cancelled**; prior PR CI **failed** on NSLock-in-async |
| 2 QA | Agents running; ENG-004 confirmed from CI logs |
| 3–5 | ENG-004/005 being fixed |
| 6–8 | No speculative refactors |
| 9 | GitHub Actions on this PR |
| 10–11 | Not available (Linux, no devices) |
| 18 | Merge after CI green |

## Confirmed bugs

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| ENG-001 | Swift 6 deinit isolation | Critical | Fixed on main `26f9cd6` |
| ENG-002 | iOS pairing 4 vs 6 chars | High | Fixed on main `26f9cd6` |
| ENG-003 | Mock actor isolation | High (CI) | Incomplete — NSLock in async still failed |
| ENG-004 | NSLock.lock() in async `send` | High (CI) | Fixing |
| ENG-005 | Server protocol error does not cancel NWConnection | Medium | Fixing |

## Product decisions

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays off by default |
| PD-002 | Keep 6-char alphanumeric pairing codes |

## Remaining risks

- Local Swift/Xcode unavailable
- Hardware journeys unverified
- `main` CI for `26f9cd6` was cancelled — compile/test of that merge is unproven
- LAN remote control has no TLS
