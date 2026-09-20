# Engineering Findings

Triage date: 2026-09-20
Sources: GitHub Actions logs, repository inspection, independent adversarial QA against current source.

## Product decisions (unchanged)

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays **off by default**. No Mac pairing-code UI. No TLS. |
| PD-002 | Pairing codes stay 6-character alphanumeric (`kLightStarPairingCodeAlphabet`). |

No silent product-behavior changes. Connect restore now matches the comments already in `LightStarApp` / `setPower`.

## Confirmed bugs

### ENG-001 — Swift 6 deinit isolation breaks the build

- **Severity:** Critical
- **Status:** Fixed on main `26f9cd6`

### ENG-002 — iOS pairing UI out of sync with server code format

- **Severity:** High (only if pairing is enabled)
- **Status:** Fixed on main `26f9cd6`

### ENG-003 / ENG-004 — Test mock isolation / NSLock in async

- **Severity:** High (CI)
- **Status:** Fixed on this branch (`MockMessageTransport` is a lock-free class)

### ENG-005 — Server leaves TCP connection open after protocol/buffer failure

- **Severity:** Medium
- **Status:** Fixed on this branch (`failConnection()`)

### ENG-006 — Pointer encode could crash on huge finite deltas

- **Severity:** High
- **Status:** Fixed on this branch (`pointerDeltaToInt16` saturation)
- **CI follow-up:** `testExtremeMouseDeltas` compared against `Int16.max/10` (3276.7). Negative saturation uses `Int16.min` (`-32768` → 3276.8). Test now uses the wider wire range.

### ENG-007 — Connect init writes color after power-off and wakes the strip

- **Severity:** High
- **Feature:** BLE connect sequence
- **Evidence:** `LightBLEManager` connect task always wrote `Cmd.hue` / `Cmd.brightness` after `Cmd.powerOff`. `setPower` already documents that those writes wake BC/55.
- **Fix:** Restore appearance and sync only when `targetOn == true`.
- **Status:** Implemented on this branch

### ENG-008 — Every extra GATT service restarts the connect sequence

- **Severity:** High
- **Evidence:** `discoverServices(nil)` then `didDiscoverCharacteristicsFor` started a new `connectSequenceTask` whenever `writeChar != nil`, without cancelling the previous task. `onConnect` could fire repeatedly.
- **Fix:** Start the sequence only when the write characteristic transitions from nil to set.
- **Status:** Implemented on this branch

### ENG-009 — Scheduled actions overwritten by the default preset

- **Severity:** High
- **Evidence:** `LightStarApp.onConnect` drained pending schedules then still applied the default preset (`setColor`/`setBrightness`), which wakes a strip that a bedtime schedule just turned off.
- **Fix:** `ConnectAppearancePolicy` skips the default preset when pending actions existed, the strip is off, or sync is running. Firmware timers are also pushed on connect.
- **Status:** Implemented on this branch

### ENG-010 — Firmware weekly timers not synced on connect; unused slots not cleared

- **Severity:** High
- **Evidence:** `pushFirmwareTimers()` ran only from `save()`, never on reconnect, and never sent `enabled: false` for leftover BC0D slots.
- **Fix:** `FirmwareTimerSync.frames` always emits `Cmd.weeklyTimerSlotCount` (8) slots; unused slots are disabled. Called from `save()` and from `onConnect`.
- **Status:** Implemented on this branch

### ENG-011 — `stopSyncInline()` never disables the strip mic

- **Severity:** Medium
- **Evidence:** `teardownSync()` writes `Cmd.stripMic(false)`; the inline stop path did not, so leaving strip-mic sync via color/power left the onboard mic running.
- **Fix:** Same strip-mic disable in `stopSyncInline()`.
- **Status:** Implemented on this branch

### ENG-012 — Extra-light connect failure reconnects the primary

- **Severity:** Medium
- **Fix:** Drop the extra peripheral; `BLEDiscoveryPolicy` reconnects only when the failed device is the primary.
- **Status:** Implemented on this branch

### ENG-013 — Multi-light scan stops on the first advertisement

- **Severity:** Medium
- **Evidence:** Extra-light branch required `peripheral != nil`, so the first hit always `stopScan()`’d.
- **Fix:** Keep scanning when `multiLightEnabled`.
- **Status:** Implemented on this branch

### ENG-014 — Listener failure overwritten to `.stopped`; pointer injector not cleaned up

- **Severity:** Medium
- **Fix:** Failed listener sets `.error` without calling `stop()`. `stop()` still goes to `.stopped`. `start()` may retry from `.error`. `closeListenerAndClients()` releases the mouse button via `pointerInjector.cleanup()`.
- **Status:** Implemented on this branch

### ENG-015 — Pairing path handshake timer and error clobber

- **Severity:** Medium
- **Evidence:** 10s timer started at `connect()` was not reset when entering pairing; a later TCP close called `disconnect()` and replaced `.error` with `.disconnected`.
- **Fix:** `armHandshakeTimeout()` on TCP hello and on pairing challenge. `RemoteClientSessionPolicy` keeps `.error` across transport close. Failed `pairAck` uses `fail()`.
- **Status:** Implemented on this branch

## Test coverage (not product bugs)

Mock Security/UserJourney suites still do not exercise live `RemoteControlServer` / `LightBLEManager` CoreBluetooth. Documented; not rewritten. Production policy helpers above are unit-tested.

## Remaining risks

- Local Swift/Xcode unavailable on this Linux agent; GitHub Actions is the compile/test gate.
- Hardware journeys (real BC/55, iPhone, Accessibility) unverified here.
- LAN remote control has no TLS (PD-001).
- BC/55 weekly timer slot count is a conservative cap of 8 (OEM capture showed slot `0x01` only). Extra disabled writes are expected to be ignored if the firmware has fewer slots.
