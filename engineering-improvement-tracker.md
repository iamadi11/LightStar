# Engineering Improvement Tracker

Last updated: 2026-09-21
Branch: `cursor/sdlc-reliability-pass-6022`
Base: `origin/main` @ `adda24d`

## Status

| Phase | State |
|-------|--------|
| 0 Discovery | Complete — architecture unchanged from quality pass |
| 1 Baseline | `adda24d` CI **success** (35536096195) |
| 2 QA | Remaining production paths inspected in source |
| 3–4 | ENG-022–034 triaged; PD-001/PD-002 stand |
| 5 | ENG-022–034 implemented with policy tests |
| 6–8 | Policy helpers only; no speculative rewrites |
| 9 | GitHub Actions on this PR after push |
| 10–11 | Not available (Linux, no devices) |
| 18 | Merge after CI green |

## Confirmed bugs

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| ENG-001–021 | Prior quality pass | — | Fixed on main `adda24d` |
| ENG-022 | Extras path swallows primary rediscovery | High | Fixed this branch |
| ENG-023 | Multi-light off leaves extras scan running | Medium | Fixed this branch |
| ENG-024 | lastSyncMode wiped before async restore | High | Fixed this branch |
| ENG-025 | silenceTask not cancelled on sync stop | Medium | Fixed this branch |
| ENG-026 | Stale TCP callbacks drop new session | High | Fixed this branch |
| ENG-027 | iOS snapshot connects strip without intent | Medium | Fixed this branch |
| ENG-028 | Wake reconnects after user disconnect | Medium | Fixed this branch |
| ENG-029 | Sampler stop no-op during in-flight start | Medium | Fixed this branch |
| ENG-030 | Server stop leaves pairing code | Low | Fixed this branch |
| ENG-031 | Pointer cleanup left-button only | Medium | Fixed this branch |
| ENG-032 | Pairing field survives disconnect | Low | Fixed this branch |
| ENG-033 | Launch at Login UI ignores register failure | Low | Fixed this branch |
| ENG-034 | Pending schedule not durable | Medium | Fixed this branch |

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
