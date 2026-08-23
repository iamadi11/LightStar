# Protocol Confirmed — ELK-BLEDOM / FFF0 Family

**Confirmed:** 2026-08-23 via nRF Connect scan of physical device ("GATT--DEMO")

---

## Device Identity

| Field | Value |
|-------|-------|
| BLE name | `GATT--DEMO` |
| Advertised service | `0x2022` |
| Primary service | `0000FFF0-0000-1000-8000-00805f9b34fb` |
| Write characteristic | `0000FFF3-0000-1000-8000-00805f9b34fb` (Write + Write Without Response) |
| Notify characteristic | `0000FFF4-0000-1000-8000-00805f9b34fb` |

---

## Command Reference (9-byte frames)

All commands: `7E [cmd] [len] [data 4 bytes] EF`

| Command | Bytes (hex) |
|---------|-------------|
| Power ON | `7E 00 04 F0 00 01 FF 00 EF` |
| Power OFF | `7E 00 04 00 00 00 FF 00 EF` |
| Set RGB | `7E 00 05 03 RR GG BB 00 EF` |
| Set brightness (0–100) | `7E 00 01 ZZ 00 00 00 00 EF` |
| Set effect | `7E 00 03 MM SS 00 00 00 EF` (MM=mode, SS=speed) |

### Known effect modes (MM byte)
| MM | Effect |
|----|--------|
| 0x25 | Jump RGB |
| 0x26 | Jump RGBYCMW |
| 0x27 | Fade RGB |
| 0x28 | Fade 7 colors |
| 0x29 | Flash RGB |
| 0x2A | Flash 7 colors |
| 0x2B | Single color flash |
| 0x2C | Strobe |

Speed range: `0x01` (fast) – `0x1F` (slow)

### Variant
Some firmware uses `7E 07` instead of `7E 00` as header. If `7E 00` commands are ignored, retry with `7E 07 05 03 RR GG BB 10 EF` for color.

---

## Scan Strategy

Scan for advertised service UUID `0x2022`. On discovery connect and discover service `FFF0`, then characteristic `FFF3`. Use **Write Without Response** for all commands (faster, no ACK needed).
