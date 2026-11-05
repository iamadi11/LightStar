# Protocol Confirmed — Custom BC/55 Frame (Miracles Star / GATT--DEMO)

**Confirmed:** 2026-08-23 via two PacketLogger captures of Miracles Star app traffic

---

## Device Identity

| Field | Value |
|-------|-------|
| BLE name | `GATT--DEMO` |
| Advertised service | `0x2022` |
| Primary service | `0000FFF0-0000-1000-8000-00805f9b34fb` |
| Write characteristic | `0000FFF3-0000-1000-8000-00805f9b34fb` (Write + Write Without Response) |
| Notify characteristic | `0000FFF4-0000-1000-8000-00805f9b34fb` |
| GATT write handle | `0x0003` |
| Write type | Write Command (withoutResponse) |

**NOT** ELK-BLEDOM, Triones, MagicBlue, or any other known family.

---

## Frame Format

```
BC [command] [data_len] [data × data_len bytes] 55
```

- Start marker: `BC`
- End marker: `55`
- All multi-byte values: **big-endian 16-bit**
- Color model: **HSV** (Hue + Saturation via BC04, brightness via BC05)

---

## Command Reference (Confirmed)

### BC01 — Power ON/OFF
```
BC 01 01 [state] 55
```
| state | Meaning |
|-------|---------|
| `01` | Power ON |
| `00` | Power OFF |

On connect: send `BC 01 01 00 55` (OFF) then `BC 01 01 01 55` (ON) as a power-cycle reset.

### BC04 — Set Hue + Saturation
```
BC 04 06 [H_hi] [H_lo] [S_hi] [S_lo] 00 00 55
```
- H = hue in degrees 0–360, big-endian 16-bit
- S = saturation 0–1000 (1000 = 100%), big-endian 16-bit
- Trailing `00 00` always

| Color | H | S | Bytes |
|-------|---|---|-------|
| Red | 0 | 1000 | `BC 04 06 00 00 03 E8 00 00 55` |
| Green | 120 | 1000 | `BC 04 06 00 78 03 E8 00 00 55` |
| Blue | 240 | 1000 | `BC 04 06 00 F0 03 E8 00 00 55` |
| White | 0 | 0 | `BC 04 06 00 00 00 00 00 00 55` |

### BC05 — Set Brightness
```
BC 05 06 [B_hi] [B_lo] 00 00 00 00 55
```
- B = brightness 100–1000 (100 = ~10%, 1000 = 100%), big-endian 16-bit
- Minimum observed: 100 (0x0064). Below 100 not captured.
- Trailing `00 00 00 00` always

| Level | Bytes |
|-------|-------|
| Max (1000) | `BC 05 06 03 E8 00 00 00 00 55` |
| Min (100) | `BC 05 06 00 64 00 00 00 00 55` |

### BC06 — Select Effect
```
BC 06 02 00 [effect_id] 55
```
- effect_id: 1-byte integer (seen: 0x01, 0x03, 0x35=53)
- Effect IDs not yet mapped to names — needs more captures with known UI state

### BC08 — Effect Speed
```
BC 08 01 [speed] 55
```
- speed: 0–100 decimal (0x00 = slowest, 0x64 = fastest)
- Independent of effect selection

### BC0B — RTC Sync
```
BC 0B 07 [Y_hi] [Y_lo] [M] [D] [h] [m] [s] 55
```

### BC0C — Schedule Confirm
```
BC 0C 01 01 55
```
Sent after BC0B. Likely commits the schedule write.

### BC0F — Strip Mic On/Off
```
BC 0F 01 01 55   ← strip's own mic on (OEM "External MIC")
BC 0F 01 00 55   ← off (OEM switches to phone mic)
```
Camera-verified 2026-11-05: with BC0F on, LEDs stay dark in a quiet room and light in changing colours with real music or claps near the controller box. A synthetic 70 Hz beat from a speaker across the desk did not trigger it, even at BC12 = 0xFF.

### BC11 — Mic Visualization Pattern
```
BC 11 01 [pattern] 55
```
Selects how amplitude maps to light behaviour. Use after BC0F enable. Sent **without** BC0F on, it runs a colour animation by itself (camera: purple → green, moving).

| pattern | Effect (camera-confirmed) |
|---------|--------------------------|
| `0x01`  | Pattern 1 |
| `0x02`  | Pattern 2 (seen in capture) |
| `0x03`  | Pattern 3 (seen in capture, brightness-dominant) |
| `0x06`  | Pattern 4 |

### BC12 — Mic Amplitude Level
```
BC 12 01 [level] 55
```
level 0–100. Send at ~10 Hz while BC0F enabled to stream live amplitude.

### BC13 — White-Tone Wheel
```
BC 13 02 [angle_hi] [angle_lo] 55
```
Angle 0–360 on the OEM white-tone wheel (Android `CustomColorPicker2`). Camera-verified 2026-11-05: 0 = cool bluish white, 90 = neutral white, 180 = warm amber.
The 1-byte form `BC 13 01 [id] 55` (EffectGridView) is never sent by either OEM app. It gives **static** colours (0x10 white-ish, 0x80 purple; no motion over 4 s), which is what the earlier camera probe saw as "253 animations".

### BC09 — Secondary Color / Zone Color
```
BC 09 06 [V_hi] [V_lo] 03 E8 00 00 55
```
V varies 0–1000. S always 1000. Camera-confirmed changes at 00/01/64.

---

## Partially Cracked (needs more investigation)

| Cmd | Finding | Status |
|-----|---------|--------|
| BC07 | 2 valid values: 0x00 (dims+hue shift) and 0x02 (brightens). Likely zone/segment selector or LED count. | Needs visual test — which part of strip changes? |
| BC10 | iOS app sends `BC 10 01 [v] 55` from a "Sensitivity" slider. Camera 2026-11-05: v=00 → green, v=01 → magenta, v=80/FF → no change; 2-byte `BC 10 02 00 [x] 55` → pale white. Changes colour but not as a plain hue. | Unresolved |
| BC03 | 0/256 payloads respond at 1-byte. Needs different frame structure or active mode. | Shelved |

---

## Sweep of unused command bytes (2026-11-05)

BC00, BC0A, BC0E, BC14–BC20 and BC50, each with payloads `00`, `01 00`, `01 01`, `01 FF`, `02 00 01`, sent from solid red. The user watched the whole strip: **no change of any kind**, including no partially dark or partially coloured sections. With both OEM apps decompiled, this controller has no per-LED or per-segment command over BLE.

## Unknown Commands (Captured, Purpose Unknown)

| Bytes | Context |
|-------|---------|
| `BC 09 06 [V_hi] [V_lo] 03 E8 00 00 55` | Sent during color-wheel drag. V varies 0–1000; second value always 1000. Possibly warm-white or hue-only wheel. |
| `BC 0F 01 01 55` / `BC 0F 00 01 55` | Sent in pairs during color wheel drag. Possibly live-color enable/disable. |
| `BC 0C 01 01 55` | Sent with BC0B. Possibly preset write. |
| `BC 0B 07 07 EA 08 17 10 21 2D 55` | Sent with BC0C. Possibly schedule/timer. 7 data bytes, partially match time-of-day values. |

---

## Color Workflow (Solid Color)

1. On connect: power-cycle reset — `BC 01 01 00 55` (OFF) then `BC 01 01 01 55` (ON)
2. Set hue + saturation: `BC 04 06 ...`
3. Set brightness: `BC 05 06 ...`

## Effect Workflow

1. Select effect: `BC 06 02 00 [id] 55`
2. Set speed: `BC 08 01 [speed] 55`
3. To return to solid color: just send BC04 + BC05 (no special mode command needed)
