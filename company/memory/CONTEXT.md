# LightStar — Autonomous Company Domain Context

Last reviewed: 2026-09-21

## Mission

LightStar is a native Swift controller for a reverse-engineered **BC/55** BLE RGB LED bar (Miracles Star / GATT--DEMO). It replaces the OEM app with a Mac menu-bar controller, iPhone LAN remote, screen/audio sync, schedules, widgets, App Intents, and an optional Alexa Hue-bridge emulator.

## Ubiquitous language

| Term | Meaning |
|------|---------|
| BC/55 | Custom BLE frame protocol `BC [cmd] [len] [data…] 55` |
| Strip | The connected LED bar (not a generic WS2812 USB neon unless a driver exists) |
| Sync | ScreenCaptureKit / system-audio / mic colour streaming to the strip |
| Remote | iPhone → Mac `_lightstar._tcp` JSON control; Mac owns BLE |
| PD-001 | Pairing off by default; no TLS on LAN remote |
| PD-002 | 6-character alphanumeric pairing codes |
| Coalescer | `BLEWriteCoalescer` deduping BLE writes |
| Alexa bridge | Local Hue API emulator; Mac remains BLE brain |

## Locked product decisions

- **PD-001**, **PD-002** — do not reverse without ADR + Strategy approval.

## Environment honesty

- Linux Cloud Agents: **cannot** run `swift` / `xcodebuild`. Validation for Swift changes is **CI on macOS-15** or a Mac.
- Hardware BLE / Accessibility / real iPhone: often unavailable — label results accordingly.

## Non-goals for the autonomous company

- Inventing customer demand or revenue claims.
- Task farming to keep the loop busy.
- Replacing working BLE protocol code without device evidence.
