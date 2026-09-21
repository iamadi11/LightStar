# Engineering Findings

Triage date: 2026-09-21
Base: `adda24d` (ENG-001–021 already on main)
Sources: repository inspection of current production paths. Independent QA reports were re-checked in source; items that could not be reproduced were not treated as confirmed.

## Product decisions (unchanged)

| ID | Decision |
|----|----------|
| PD-001 | Pairing stays **off by default**. No Mac pairing-code UI. No TLS. |
| PD-002 | Pairing codes stay 6-character alphanumeric (`kLightStarPairingCodeAlphabet`). |

No silent product-behavior changes.

## Previously fixed (ENG-001–021)

See prior pass. Not re-opened.

## Confirmed bugs (this pass)

### ENG-022 — Multi-light extras path swallows primary rediscovery

- **Severity:** High
- **Classification:** Bug fix
- **Feature:** BLE multi-light scan
- **Evidence:** `didDiscover` used `multiLightEnabled && peripheral != nil`. Disconnect does not nil `peripheral` (needed for reconnect). After a drop, advertisements including the primary hit the extras branch (`guard discoveredPeripheral !== self.peripheral else { return }`) and the primary is never reconnected.
- **Expected:** Extra lights only while the primary is actually `.connected`.
- **Fix:** `BLEDiscoveryPolicy.shouldTreatAdvertisementAsExtraLight` requires `.connected`. Non-primary ads are ignored only while connecting/connected; a leftover peripheral while disconnected/scanning can become primary again.
- **Regression risk:** Extra-light attach while primary is still connecting is delayed until `.connected`.

### ENG-023 — Disabling multi-light leaves extras scan running

- **Severity:** Medium
- **Classification:** Reliability improvement
- **Evidence:** `multiLightEnabled` didSet only called `disconnectExtraLights()`. With ENG-013 the scan keeps running after primary connect.
- **Fix:** Stop scan when disabling multi-light while connected; start extra scan when enabling while already connected.

### ENG-024 — Connect restore zeros `lastSyncMode` before async sync starts

- **Severity:** High
- **Classification:** Bug fix
- **Evidence:** `startConnectSequence` copied `lastSyncMode`, set it to `.off`, then called `setSyncMode` (async). `onConnect` then saw `syncMode == .off` and `lastSyncMode == .off` and applied the default preset (ENG-009 race still open). `setSyncMode(.off)` also did not persist `lastSyncMode` (only `stopSyncInline` did).
- **Fix:** Do not clear `lastSyncMode` before restore. Persist it when `setSyncMode(.off)`. `ConnectAppearancePolicy` skips the default preset when `hasSyncToRestore`.

### ENG-025 — Silence auto-off task not cancelled on sync stop

- **Severity:** Medium
- **Classification:** Reliability improvement
- **Evidence:** `silenceTask` cancelled in `disconnect()` but not in `setSyncMode` / `stopSyncInline`. A 2s audio-silence task could turn sync off after the user had already started another mode.
- **Fix:** Cancel and nil `silenceTask` in both paths.

### ENG-026 — Stale NWConnection callbacks tear down a new remote session

- **Severity:** High
- **Classification:** Reliability improvement
- **Evidence:** `RemoteControlClient.connect(to:)` cancels the old `NWConnection` then starts a new one. Receive / state handlers had no generation, so a late `handleTransportClose()` or `.failed` from the old socket could drop the new session.
- **Fix:** `connectionGeneration` + `RemoteClientSessionPolicy.shouldHandleCallback`.

### ENG-027 — iOS snapshot marks the strip connected without Connect Strip

- **Severity:** Medium
- **Classification:** Bug fix
- **Evidence:** `applyRemoteSnapshot` set `connectionState = .connected` whenever `state.isConnected`, even if `wantsMacStripConnection` was false (trackpad-only Mac session).
- **Fix:** `RemoteStripSnapshotPolicy` requires `wantsMacStripConnection`. Light color fields still update (display of Mac state).

### ENG-028 — Wake-from-sleep reconnects after an explicit disconnect

- **Severity:** Medium
- **Classification:** Bug fix
- **Evidence:** `NSWorkspace.didWakeNotification` called `ble.connect()` whenever auto-connect was on and state was `.disconnected`, ignoring `userInitiatedDisconnect`. `connect()` also clears that flag, so a later BT-off/on could not distinguish intent either — the wake path is the one that must honor it.
- **Fix:** `WakeReconnectPolicy` requires `!userInitiatedDisconnect`.

### ENG-029 — Sampler `stop()` is a no-op while start is in flight

- **Severity:** Medium
- **Classification:** Reliability improvement
- **Evidence:** `SystemAudioSampler` / `ScreenCaptureKitProvider` only bumped `generation` if `isRunning`. `MicAudioSampler` had no generation. `stop()` during `startCapture()` / mic permission therefore did not invalidate the in-flight start.
- **Fix:** Always bump generation in `stop()`. Mic sampler matches the screen/system-audio pattern.

### ENG-030 — Server stop leaves pairing code and expiry task alive

- **Severity:** Low (pairing off by default, PD-001)
- **Classification:** Reliability improvement
- **Evidence:** `closeListenerAndClients()` did not cancel `pairingCodeExpireTask` or clear `activePairingCode`.
- **Fix:** Clear both in `closeListenerAndClients()` (covers `stop()` and listener failure).

### ENG-031 — Pointer cleanup only released the left button

- **Severity:** Medium
- **Classification:** Reliability improvement
- **Evidence:** `MacPointerInjector.cleanup()` posted left-up only. Right/middle could stay down after disconnect.
- **Fix:** Track right/other down; `PointerButtonCleanup` releases all held buttons.

### ENG-032 — Pairing text field kept after disconnect

- **Severity:** Low (pairing off by default)
- **Classification:** Reliability improvement
- **Evidence:** `RemoteControlView` `@State pairingCode` survived `.disconnected` / `.error`.
- **Fix:** Clear when `RemotePairingFieldPolicy.shouldClearLocalCode`.

### ENG-033 — Launch at Login toggle stays on if `SMAppService.register` fails

- **Severity:** Low
- **Classification:** Bug fix
- **Evidence:** `try? register()` then left `@AppStorage("launchAtLogin")` as the requested value.
- **Fix:** `LaunchAtLoginSync.displayedEnabled` follows the actual service status.

### ENG-034 — Scheduled action lost if pending queue is only in memory

- **Severity:** Medium
- **Classification:** Reliability improvement
- **Evidence:** `fireDue` stamped `lastFiredAt` and persisted schedules after enqueueing `pendingActions`, which lived only in RAM. App restart before connect dropped the action and catch-up would not re-fire.
- **Fix:** Persist pending to `pending-actions.json`. Stamp `lastFiredAt` only when applied or the pending file write succeeded.

## Test coverage (not product bugs)

Mock Security/UserJourney suites still do not hit `RemoteControlServer` production auth. Not rewritten (PD-001).

## Remaining risks

- Local Swift/Xcode unavailable on this Linux agent; GitHub Actions is the compile/test gate.
- Hardware journeys (real BC/55, iPhone, Accessibility) unverified here.
- LAN remote control has no TLS (PD-001).
- BC/55 weekly timer slot count is a conservative cap of 8.
- Pending-actions file is best-effort (`try?` write); if disk write fails, lastFiredAt is not stamped so catch-up can retry.
