# Product Understanding

Date: 2026-09-21  
HEAD: `a7de2c9` (`main`)

## Product architecture

LightStar is a native Swift 6 controller for a reverse-engineered **BC/55** BLE RGB LED bar.

```
Mac menu-bar app (LightStar)
  AppDelegate
    LightBLEManager ──CoreBluetooth──► BC/55 (FFF0/FFF3, advertised 0x2022)
    ScheduleStore / PresetStore
    RemoteControlCoordinator
      RemoteControlServer  (_lightstar._tcp :19384, JSON length-prefix + 0xB1 pointer frames)
      MacPointerInjector   (Network queue, Accessibility)

iPhone app (LightStariOS)
  RemoteControlClient ──LAN TCP──► Mac server
  Trackpad / keyboard / gyro ──► pointer frames
  LightBLEManager iOS facade ──► Mac BLE (optional Connect Strip)
```

`LightStarCore` is the shared package. Widgets read App Group `WidgetState` JSON. App Intents reach BLE through `LightStarRuntime`.

## Critical workflows

1. Mac: scan → connect → power / hue / brightness / effects.
2. Mac: screen, system-audio, mic, or combined sync (ScreenCaptureKit + Metal, AVAudioEngine).
3. Mac: schedules (software timer + optional BC0D firmware slots).
4. iPhone: Bonjour discover Mac → TCP → trackpad / keyboard / gyro / lights.
5. Sleep/wake reconnect, permission retry, multi-light extras.

## Core modules

| Module | Responsibility |
|--------|----------------|
| `LightBLEManager` | BLE session, sync state machine, writes via `BLEWriteCoalescer` |
| `RemoteControlServer/Client` | LAN remote protocol |
| `MacPointerInjector` | HID pointer off MainActor |
| `ScheduleStore` | Due times, pending-actions file, firmware timer table |
| `ScreenCaptureKitProvider` / audio samplers | Capture with generation-stamped start/stop |

## Important dependencies

CoreBluetooth, Network.framework, ScreenCaptureKit, AVAudioEngine, Metal, ServiceManagement, WidgetKit. No backend. No TLS (PD-001).

## High-risk areas

- Shared flags with two meanings (`peripheral` leftover vs connected, `lastSyncMode`, TCP callback generation, sampler generation).
- LAN remote is trusted after TCP hello while pairing is off (PD-001).
- Sync capture start/stop races vs UI `syncMode`.
- Pointer injection (Accessibility).
- 20–30 Hz `syncColor` observation fanning into icon, widget debounce, and LAN broadcasts.

## Existing engineering constraints

- PD-001: pairing off by default, no TLS, no Mac pairing UI.
- PD-002: 6-character alphanumeric pairing codes.
- Linux cloud agent cannot run Swift/Xcode; GitHub Actions macOS 15 is the compile/test gate.
- Hardware (real BC/55, iPhone, Accessibility) is not available here.
- Do not split `LightBLEManager` without a new reproduced failure; recent bugs were fixed with policy helpers and generation counters.

## Areas requiring deeper investigation (this pass)

Verified in source (not assumed from prior docs):

- Unauthenticated pointer frames fall through to `injector.handle` (auth bypass if pairing is enabled).
- Gyro `emit` hops MainActor before `PointerChannel.addMouseDelta`.
- Sampler `start()` returns without throwing when a concurrent `stop()` wins.
- Client `.failed` does not run `cleanupConnection()` (Bonjour browser leak).
- `syncColor` is in the same Observation tracking as widget writes and remote broadcasts.
