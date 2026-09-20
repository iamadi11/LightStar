# Engineering Improvement Tracker

Last updated: 2026-09-20
Branch: `cursor/engineering-excellence-sdlc-6022`
Base: `origin/main` @ `db5c5d6`

## Status

| Phase | State |
|-------|--------|
| 0 Discovery | In progress |
| 1 Baseline | In progress — CI currently failing on `main` |
| 2 QA investigation | Pending independent agents |
| 3 Triage | In progress (CI + pairing mismatch confirmed) |
| 4 Product decision | Pairing UX documented, no silent default change |
| 5 Bug fixes | In progress |
| 6–8 Engineering excellence | Not started |
| 9 Automated validation | Blocked locally (Linux, no Swift). CI is the validation gate. |
| 10 Manual cloud | Not available (no macOS/iOS runtime, no hardware) |
| 11 Installation | Not available in this environment |
| 12 Independent verification | Pending after CI green |
| 18 Merge to main | Not ready |

## Confirmed bugs

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| ENG-001 | Swift 6 `deinit` isolation compile errors break CI | Critical | Fixing |
| ENG-002 | iOS pairing field expects 4 numeric digits; server generates 6 alphanumeric | High | Fixing (align client with already-merged server) |

## Product decisions

| ID | Question | Decision |
|----|----------|----------|
| PD-001 | Enable pairing by default? | **No** — would change LAN connect UX. Mac Settings has no pairing-code display. Keep `requirePairing = false` until a Mac UI exists. |
| PD-002 | Pairing code format | **Keep 6-char alphanumeric** already merged on `main`. Update iOS entry field to match. Do not revert to 4-digit. |

## Remaining risks

- No Swift/Xcode on this Linux cloud agent — cannot run `swift test` or `xcodebuild` locally.
- No BLE strip, Mac, or iPhone — hardware journeys unverified here.
- Pairing remains unused in production until Mac exposes a pairing UI (`PD-001`).
- Remote control has no TLS (LAN-only trust). Changing that is a product/architecture decision.

## Active tasks

1. Unblock CI (ENG-001).
2. Align iOS pairing input with server (ENG-002).
3. Record baseline from GitHub Actions.
4. Independent QA on remaining code.
5. Only implement further changes with evidence.
