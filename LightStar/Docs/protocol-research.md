# BLE LED Protocol Research

**Status:** Phase 1 complete — candidate protocols ranked. Phase 2 required to confirm against real device.

---

## Device Under Test

- **App:** Miracles Star (com.weifeng.lightbar)
- **Publisher:** Shantou Huahui Information Technology / Shenzhen Tingting Technology
- **Device type:** RGB LED light bar, BLE-only (no WiFi/cloud)
- **Protocol status:** No public reverse-engineering found for this specific app. Must discover via packet capture (Phase 2).

---

## Candidate Protocols (ranked by likelihood)

### 1. ELK-BLEDOM / FFF0 family ★★★★★ — Most likely

Dominant protocol for Chinese OEM RGB light bars sold on Amazon/AliExpress 2020+. Hundreds of unbranded devices (ELK-BLEDOM, MELK-BLEDOM, LEDBLE, XROCKER) use this firmware.

| Field | Value |
|-------|-------|
| Service UUID | `0000FFF0-0000-1000-8000-00805f9b34fb` |
| Write Characteristic | `0000FFF3-0000-1000-8000-00805f9b34fb` |
| Read Characteristic | `0000FFF4-0000-1000-8000-00805f9b34fb` |
| Frame format | 9 bytes, starts `7E`, ends `EF` |

Commands:

```
Set RGB:        7E 00 05 03 RR GG BB 00 EF
Power ON:       7E 00 04 F0 00 01 FF 00 EF
Power OFF:      7E 00 04 00 00 00 FF 00 EF
Set brightness: 7E 00 01 ZZ 00 00 00 00 EF  (ZZ = 0x00–0x64)
Set effect:     7E 00 03 MM 03 00 00 00 EF  (MM = mode index)
```

**Variant:** Some newer firmware uses `7E 07 05 03 RR GG BB 10 EF` (byte 1 = `07` instead of `00`).

Sources:
- https://github.com/FergusInLondon/ELK-BLEDOM
- https://github.com/dave-code-ruiz/elkbledom
- https://joshspicer.com/bluetooth-low-energy-home-assistant/

---

### 2. JACKYLED / L7161 variant ★★★★☆ — FFF0 with R/G/B byte swap

Same service/characteristic UUIDs as ELK-BLEDOM but blue and green channels are swapped in the color command.

| Field | Value |
|-------|-------|
| Service UUID | `0000FFF0-0000-1000-8000-00805f9b34fb` |
| Write Characteristic | `0000FFF3-0000-1000-8000-00805f9b34fb` |

Commands:

```
Set RGB:   7E 07 05 03 RR BB GG 10 EF   ← note BB and GG swapped vs. ELK-BLEDOM
Power ON:  7E 04 04 F0 00 01 FF 00 EF
Power OFF: 7E 04 04 00 00 00 FF 00 EF
```

Sources:
- https://github.com/kquinsland/JACKYLED-BLE-RGB-LED-Strip-controller
- https://github.com/jukkas/L7161-rgb-led-strip-ble-controller

---

### 3. Triones / HappyLighting / FFD5 family ★★★☆☆ — More common for bulbs

Used by apps like HappyLighting (com.xiaoyu.hlight), LEDBlue, QHM, BRGlight. More common for RGBW bulbs than light bars, but some bars use it.

| Field | Value |
|-------|-------|
| Service UUID | `0000FFD5-0000-1000-8000-00805f9b34fb` |
| Write Characteristic | `0000FFD9-0000-1000-8000-00805f9b34fb` |
| Notify Characteristic | `0000FFD4-0000-1000-8000-00805f9b34fb` |

Commands:

```
Power ON:    CC 23 33
Power OFF:   CC 24 33
Set RGB:     56 RR GG BB 00 F0 AA
Set white:   56 00 00 00 WW 0F AA   (WW = intensity)
Set effect:  BB MM SS 44             (MM = mode 0x25–0x38, SS = speed 0x01–0x1F)
Status query: EF 01 77
```

Sources:
- https://github.com/madhead/saberlight/blob/master/protocols/Triones/protocol.md
- https://github.com/Aritzherrero4/python-trionesControl
- https://github.com/sysofwan/ha-triones

---

### 4. Magic Blue / FFE5 family ★★☆☆☆ — Same payload as Triones, different UUID

```
Service UUID: 0000FFE5-0000-1000-8000-00805f9b34fb
Write Char:   0000FFE9-0000-1000-8000-00805f9b34fb
```
Identical command payloads to Triones (CC/56/AA framing).

Source: https://urish.medium.com/reverse-engineering-a-bluetooth-lightbulb-56580fcb7546

---

### 5. ZJ-MBL-RGBW / FFB0 family ★☆☆☆☆ — Uncommon, 4-byte reversed RGB

```
Service UUID: 0000FFB0-0000-1000-8000-00805f9b34fb
Write Char:   0000FFB2-0000-1000-8000-00805f9b34fb
Command:      BB GG RR WW   (4 bytes, reversed channel order)
```

Source: https://github.com/madhead/saberlight/blob/master/protocols/ZJ-MBL-RGBW%20(v3)/protocol.md

---

## How to Identify Protocol in Phase 2

1. **Advertised service UUID** — scan with nRF Connect. UUID immediately narrows to FFF0 vs FFD5 vs FFE5 vs FFB0 family.
2. **First byte of write command** — `7E` → FFF0 family. `56`/`CC` → Triones/Magic Blue family.
3. **B/G swap test** — send `7E 00 05 03 FF 00 00 00 EF`. If light turns red → ELK-BLEDOM. If wrong color → try JACKYLED variant.

---

## Next Step

Proceed to Phase 2: connect with nRF Connect, enable HCI snoop logging, operate Miracles Star app while capturing, share service UUIDs and packet log.
